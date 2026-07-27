/*==============================================================================
 * A640 RTC Tool v1.0
 * DS3231 RTC support via A640 I2C bus
 *
 * Usage:
 *   RTC                              - show current RTC time
 *   RTC sync                         - sync AmigaOS clock from RTC
 *                                      (use this in startup-sequence)
 *   RTC set YYYY-MM-DD HH:MM:SS      - set RTC from command line
 *   RTC setsys                       - set RTC from current AmigaOS time
 *
 * Build with VBCC:
 *   vc -O1 -o RTC rtc.c
 *
 * Suggested startup-sequence entry:
 *   C:RTC sync >NIL:
 *
 * Hardware:
 *   DS3231 @ I2C addr 0x68 on A640 I2C bus
 *   Time stored in BCD format
 *============================================================================*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <exec/types.h>
#include <exec/io.h>
#include <devices/timer.h>
#include <dos/dos.h>
#include <dos/datetime.h>
#include <proto/exec.h>
#include <proto/dos.h>

/*------------------------------------------------------------------------------
 * A640 register map (same as A640Monitor)
 *----------------------------------------------------------------------------*/
#define RD_BASE     0x00E80000UL
#define WR_BASE     0x00BE0000UL

#define REG_STATUS  0x10
#define REG_LOCK1   0x0C
#define REG_LOCK2   0x00
#define REG_I2C_W   0x18

#define SDA_IN_BIT  15
#define SCL_BIT     13
#define SDA_BIT     12

/* DS3231 I2C address */
#define DS3231_W    0xD0      /* 1101 000 0 - write */
#define DS3231_R    0xD1      /* 1101 000 1 - read  */

/* DS3231 register addresses */
#define DS3231_SECONDS    0x00
#define DS3231_MINUTES    0x01
#define DS3231_HOURS      0x02
#define DS3231_DAY        0x03
#define DS3231_DATE       0x04
#define DS3231_MONTH      0x05
#define DS3231_YEAR       0x06

#define HW_RD(off)      (*(volatile UWORD *)(RD_BASE + (off)))
#define HW_WR(off,val)  (*(volatile UWORD *)(WR_BASE + (off)) = (val))

/*------------------------------------------------------------------------------
 * I2C bit-bang primitives (same as A640Monitor)
 *----------------------------------------------------------------------------*/
static void i2c_delay(void)
{
    volatile int i;
    for (i = 0; i < 20; i++) { }
}

static void write_unlock(void)
{
    HW_WR(REG_LOCK1, 0xC000);
    HW_WR(REG_LOCK2, 0x4000);
}

static void i2c_set(int scl, int sda)
{
    UWORD val = 0;
    if (scl) val |= (1 << SCL_BIT);
    if (sda) val |= (1 << SDA_BIT);
    write_unlock();
    HW_WR(REG_I2C_W, val);
    i2c_delay();
}

static int i2c_get_sda(void)
{
    return (HW_RD(REG_STATUS) & (1 << SDA_IN_BIT)) ? 1 : 0;
}

static void i2c_start(void)
{
    i2c_set(1, 1);
    i2c_set(1, 0);
    i2c_set(0, 0);
}

static void i2c_stop(void)
{
    i2c_set(0, 0);
    i2c_set(1, 0);
    i2c_set(1, 1);
}

static int i2c_write_byte(UBYTE byte)
{
    int i, ack;
    for (i = 7; i >= 0; i--) {
        int bit = (byte >> i) & 1;
        i2c_set(0, bit);
        i2c_set(1, bit);
        i2c_set(0, bit);
    }
    i2c_set(0, 1);
    i2c_set(1, 1);
    ack = i2c_get_sda();
    i2c_set(0, 1);
    return (ack == 0) ? 0 : -1;
}

static UBYTE i2c_read_byte(int send_nack)
{
    UBYTE result = 0;
    int i;
    for (i = 0; i < 8; i++) {
        i2c_set(0, 1);
        i2c_set(1, 1);
        result = (result << 1) | i2c_get_sda();
        i2c_set(0, 1);
    }
    if (send_nack) {
        i2c_set(0, 1);
        i2c_set(1, 1);
        i2c_set(0, 1);
    } else {
        i2c_set(0, 0);
        i2c_set(1, 0);
        i2c_set(0, 0);
    }
    return result;
}

/*------------------------------------------------------------------------------
 * Set AmigaOS system time using timer.device (TR_SETSYSTIME)
 * This works since Kickstart 1.0, no SetSystemTime() needed.
 *
 * Input: seconds since 1978-01-01 00:00:00
 * Returns: 1 OK, 0 error
 *----------------------------------------------------------------------------*/
static int set_system_time_secs(ULONG seconds_since_1978)
{
    struct MsgPort *port;
    struct timerequest *req;
    int ok = 0;

    port = CreateMsgPort();
    if (!port) return 0;

    req = (struct timerequest *)CreateIORequest(port, sizeof(struct timerequest));
    if (!req) {
        DeleteMsgPort(port);
        return 0;
    }

    if (OpenDevice("timer.device", UNIT_VBLANK,
                   (struct IORequest *)req, 0) == 0) {
        req->tr_node.io_Command = TR_SETSYSTIME;
        req->tr_time.tv_secs    = seconds_since_1978;
        req->tr_time.tv_micro   = 0;
        DoIO((struct IORequest *)req);
        ok = 1;
        CloseDevice((struct IORequest *)req);
    }

    DeleteIORequest((struct IORequest *)req);
    DeleteMsgPort(port);
    return ok;
}

/*------------------------------------------------------------------------------
 * BCD <-> binary conversion
 *----------------------------------------------------------------------------*/
static UBYTE bcd_to_bin(UBYTE bcd)
{
    return (UBYTE)((bcd >> 4) * 10 + (bcd & 0x0F));
}

static UBYTE bin_to_bcd(UBYTE bin)
{
    return (UBYTE)(((bin / 10) << 4) | (bin % 10));
}

/*------------------------------------------------------------------------------
 * DS3231 read time - reads 7 registers starting from 0x00
 *
 * Output struct fields (all binary, not BCD):
 *   second, minute, hour, day, date, month, year (year = 00-99 = 2000-2099)
 *
 * Returns 1 OK, 0 error
 *----------------------------------------------------------------------------*/
typedef struct {
    UBYTE second;
    UBYTE minute;
    UBYTE hour;
    UBYTE day;       /* day of week 1-7 */
    UBYTE date;      /* day of month 1-31 */
    UBYTE month;
    UBYTE year;      /* 00-99, add 2000 */
} RtcTime;

static int ds3231_read(RtcTime *t)
{
    UBYTE buf[7];
    int i;

    /* Phase 1: write register pointer */
    i2c_start();
    if (i2c_write_byte(DS3231_W) != 0) { i2c_stop(); return 0; }
    if (i2c_write_byte(DS3231_SECONDS) != 0) { i2c_stop(); return 0; }

    /* Phase 2: repeated start, read 7 bytes */
    i2c_start();
    if (i2c_write_byte(DS3231_R) != 0) { i2c_stop(); return 0; }

    for (i = 0; i < 6; i++) {
        buf[i] = i2c_read_byte(0);     /* ACK */
    }
    buf[6] = i2c_read_byte(1);          /* NACK on last */
    i2c_stop();

    /* Convert BCD -> binary */
    t->second = bcd_to_bin(buf[0] & 0x7F);
    t->minute = bcd_to_bin(buf[1] & 0x7F);
    t->hour   = bcd_to_bin(buf[2] & 0x3F);  /* 24h mode */
    t->day    = buf[3] & 0x07;
    t->date   = bcd_to_bin(buf[4] & 0x3F);
    t->month  = bcd_to_bin(buf[5] & 0x1F);  /* mask century bit */
    t->year   = bcd_to_bin(buf[6]);

    return 1;
}

/*------------------------------------------------------------------------------
 * DS3231 write time - writes 7 registers starting from 0x00
 *----------------------------------------------------------------------------*/
static int ds3231_write(const RtcTime *t)
{
    i2c_start();
    if (i2c_write_byte(DS3231_W) != 0) { i2c_stop(); return 0; }
    if (i2c_write_byte(DS3231_SECONDS) != 0) { i2c_stop(); return 0; }

    if (i2c_write_byte(bin_to_bcd(t->second)) != 0) { i2c_stop(); return 0; }
    if (i2c_write_byte(bin_to_bcd(t->minute)) != 0) { i2c_stop(); return 0; }
    if (i2c_write_byte(bin_to_bcd(t->hour))   != 0) { i2c_stop(); return 0; }
    if (i2c_write_byte(t->day & 0x07)         != 0) { i2c_stop(); return 0; }
    if (i2c_write_byte(bin_to_bcd(t->date))   != 0) { i2c_stop(); return 0; }
    if (i2c_write_byte(bin_to_bcd(t->month))  != 0) { i2c_stop(); return 0; }
    if (i2c_write_byte(bin_to_bcd(t->year))   != 0) { i2c_stop(); return 0; }

    i2c_stop();
    return 1;
}

/*------------------------------------------------------------------------------
 * Convert RtcTime -> AmigaOS DateStamp
 *
 * AmigaOS DateStamp counts days since 1978-01-01.
 * ds_Tick = 1/50 second since midnight (Days = ds_Days, Min since midnight)
 *
 * AmigaOS dos.library has Date2Amiga() but not all versions - we compute manually.
 *----------------------------------------------------------------------------*/

/* Days in each month (non-leap year) */
static const UWORD days_in_month[12] = {
    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
};

static int is_leap_year(int y)
{
    return ((y % 4) == 0 && (y % 100) != 0) || ((y % 400) == 0);
}

static void rtc_to_datestamp(const RtcTime *t, struct DateStamp *ds)
{
    int y, m;
    LONG days = 0;
    int year_full = 2000 + t->year;

    /* Days from 1978-01-01 to start of year_full */
    for (y = 1978; y < year_full; y++) {
        days += is_leap_year(y) ? 366 : 365;
    }

    /* Days from start of year to start of current month */
    for (m = 0; m < (int)(t->month - 1); m++) {
        days += days_in_month[m];
        if (m == 1 && is_leap_year(year_full)) days += 1;
    }

    /* Days within current month */
    days += (t->date - 1);

    ds->ds_Days   = days;
    ds->ds_Minute = (LONG)t->hour * 60 + t->minute;
    ds->ds_Tick   = (LONG)t->second * TICKS_PER_SECOND;
}

/*------------------------------------------------------------------------------
 * Convert RtcTime -> seconds since 1978-01-01 (for timer.device)
 *----------------------------------------------------------------------------*/
static ULONG rtc_to_seconds(const RtcTime *t)
{
    struct DateStamp ds;
    rtc_to_datestamp(t, &ds);
    /* DateStamp -> total seconds since 1978-01-01 */
    return (ULONG)ds.ds_Days * 86400UL +
           (ULONG)ds.ds_Minute * 60UL +
           (ULONG)(ds.ds_Tick / TICKS_PER_SECOND);
}

/*------------------------------------------------------------------------------
 * Convert AmigaOS DateStamp -> RtcTime (for setsys command)
 *----------------------------------------------------------------------------*/
static void datestamp_to_rtc(const struct DateStamp *ds, RtcTime *t)
{
    LONG days = ds->ds_Days;
    int year = 1978;
    int month = 0;
    int dim;

    /* Walk forward year by year */
    for (;;) {
        int yd = is_leap_year(year) ? 366 : 365;
        if (days < yd) break;
        days -= yd;
        year++;
    }

    /* Walk forward month by month within year */
    while (month < 12) {
        dim = days_in_month[month];
        if (month == 1 && is_leap_year(year)) dim = 29;
        if (days < dim) break;
        days -= dim;
        month++;
    }

    t->year   = (UBYTE)(year - 2000);
    t->month  = (UBYTE)(month + 1);
    t->date   = (UBYTE)(days + 1);
    t->hour   = (UBYTE)(ds->ds_Minute / 60);
    t->minute = (UBYTE)(ds->ds_Minute % 60);
    t->second = (UBYTE)(ds->ds_Tick / TICKS_PER_SECOND);
    t->day    = 1;  /* not critical, DS3231 day-of-week not used by AmigaOS */
}

/*------------------------------------------------------------------------------
 * Print time in ISO format
 *----------------------------------------------------------------------------*/
static void print_time(const RtcTime *t)
{
    printf("%04d-%02d-%02d %02d:%02d:%02d\n",
           (int)(2000 + t->year), (int)t->month, (int)t->date,
           (int)t->hour, (int)t->minute, (int)t->second);
}

/*------------------------------------------------------------------------------
 * Parse "YYYY-MM-DD HH:MM:SS" into RtcTime
 * Returns 1 OK, 0 parse error
 *----------------------------------------------------------------------------*/
static int parse_time_arg(const char *s, RtcTime *t)
{
    int Y, M, D, h, m, sec;
    int n;

    n = sscanf(s, "%d-%d-%d %d:%d:%d", &Y, &M, &D, &h, &m, &sec);
    if (n != 6) return 0;

    if (Y < 2000 || Y > 2099) return 0;
    if (M < 1 || M > 12) return 0;
    if (D < 1 || D > 31) return 0;
    if (h < 0 || h > 23) return 0;
    if (m < 0 || m > 59) return 0;
    if (sec < 0 || sec > 59) return 0;

    t->year   = (UBYTE)(Y - 2000);
    t->month  = (UBYTE)M;
    t->date   = (UBYTE)D;
    t->hour   = (UBYTE)h;
    t->minute = (UBYTE)m;
    t->second = (UBYTE)sec;
    t->day    = 1;
    return 1;
}

/*------------------------------------------------------------------------------
 * Usage
 *----------------------------------------------------------------------------*/
static void show_usage(void)
{
    printf("A640 RTC Tool v1.0 - DS3231 support\n\n");
    printf("Usage:\n");
    printf("  RTC                          show current RTC time\n");
    printf("  RTC sync                     sync AmigaOS clock from RTC\n");
    printf("  RTC set YYYY-MM-DD HH:MM:SS  set RTC time\n");
    printf("  RTC setsys                   set RTC from current AmigaOS time\n\n");
    printf("Tip: add 'C:RTC sync >NIL:' to startup-sequence\n");
}

/*==============================================================================
 * Main
 *============================================================================*/
int main(int argc, char *argv[])
{
    RtcTime t;
    struct DateStamp ds;
    char arg_buf[64];

    if (argc == 1) {
        /* No args: show RTC time */
        if (!ds3231_read(&t)) {
            printf("ERROR: DS3231 not responding (no ACK at 0x68)\n");
            return RETURN_FAIL;
        }
        printf("RTC time: ");
        print_time(&t);
        return RETURN_OK;
    }

    /*-------- sync --------*/
    if (strcmp(argv[1], "sync") == 0 || strcmp(argv[1], "SYNC") == 0) {
        if (!ds3231_read(&t)) {
            printf("ERROR: DS3231 not responding\n");
            return RETURN_FAIL;
        }

        /* Sanity check - DS3231 returns 00 for unset clock */
        if (t.year == 0 && t.month == 1 && t.date == 1 &&
            t.hour == 0 && t.minute == 0 && t.second < 5) {
            printf("WARNING: RTC appears uninitialized.\n");
            printf("Use 'RTC set YYYY-MM-DD HH:MM:SS' to set time.\n");
            return RETURN_WARN;
        }

        if (!set_system_time_secs(rtc_to_seconds(&t))) {
            printf("ERROR: failed to set system time via timer.device\n");
            return RETURN_FAIL;
        }

        printf("AmigaOS clock synced from RTC: ");
        print_time(&t);
        return RETURN_OK;
    }

    /*-------- set --------*/
    if (strcmp(argv[1], "set") == 0 || strcmp(argv[1], "SET") == 0) {
        int i, len;

        if (argc < 4) {
            printf("ERROR: usage: RTC set YYYY-MM-DD HH:MM:SS\n");
            return RETURN_FAIL;
        }

        /* Concatenate argv[2] and argv[3] with a space */
        len = 0;
        for (i = 2; i < argc && len < 60; i++) {
            int n = strlen(argv[i]);
            if (i > 2) arg_buf[len++] = ' ';
            if (len + n >= 63) break;
            strcpy(&arg_buf[len], argv[i]);
            len += n;
        }
        arg_buf[len] = 0;

        if (!parse_time_arg(arg_buf, &t)) {
            printf("ERROR: bad time format. Use YYYY-MM-DD HH:MM:SS\n");
            return RETURN_FAIL;
        }

        if (!ds3231_write(&t)) {
            printf("ERROR: DS3231 not responding\n");
            return RETURN_FAIL;
        }

        printf("RTC set to: ");
        print_time(&t);
        return RETURN_OK;
    }

    /*-------- setsys --------*/
    if (strcmp(argv[1], "setsys") == 0 || strcmp(argv[1], "SETSYS") == 0) {
        DateStamp(&ds);
        datestamp_to_rtc(&ds, &t);

        if (!ds3231_write(&t)) {
            printf("ERROR: DS3231 not responding\n");
            return RETURN_FAIL;
        }

        printf("RTC set from AmigaOS clock: ");
        print_time(&t);
        return RETURN_OK;
    }

    /*-------- help --------*/
    show_usage();
    return RETURN_OK;
}
