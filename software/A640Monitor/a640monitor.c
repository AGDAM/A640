/*==============================================================================
 * A640 Monitor v1.3
 * Live monitor + PLL configuration for A640 accelerator (Amiga 600)
 *
 * Displays:
 *   - Current PLL multiplier
 *   - CPU temperature (LM75 @ I2C 0x48)
 *   - Min/max CPU temperature since program start
 *   - Board temperature (DS3231 @ I2C 0x68, internal sensor)
 *   - Uptime (from system clock - accurate)
 *
 * Interactive keys (press in console window):
 *   8    - set PLL x8  (28 MHz) - saved to EEPROM, takes effect after reboot
 *   0    - set PLL x10 (35 MHz)
 *   2    - set PLL x12 (42 MHz)
 *   r    - reset min/max temperature
 *   q    - quit
 *   Ctrl+C also quits
 *
 * Build with VBCC:
 *   vc -O1 -o A640Monitor a640monitor.c
 *
 * NOTE: Requires A640 register space ($E80000) accessible.
 *       If MMU is enabled, make sure mmu.config allows this range.
 *       PLL change is saved to EEPROM - takes effect after reboot.
 *       Live PLL change would crash CPU (clock glitch).
 *============================================================================*/

#include <stdio.h>
#include <string.h>
#include <exec/types.h>
#include <exec/execbase.h>
#include <dos/dos.h>
#include <dos/dosextens.h>
#include <dos/datetime.h>
#include <proto/exec.h>
#include <proto/dos.h>

/*------------------------------------------------------------------------------
 * A640 register map
 *----------------------------------------------------------------------------*/
#define RD_BASE     0x00E80000UL
#define WR_BASE     0x00BE0000UL

/* Read offsets */
#define REG_ID0     0x00
#define REG_ID1     0x04
#define REG_ID2     0x08
#define REG_ID3     0x0C
#define REG_STATUS  0x10
#define REG_PLL_R   0x14
#define REG_I2C_R   0x18
#define REG_REV     0x1C

/* Write offsets */
#define REG_LOCK1   0x0C
#define REG_LOCK2   0x00
#define REG_PLL_W   0x14
#define REG_I2C_W   0x18

/* I2C bit positions */
#define SDA_IN_BIT  15
#define SCL_BIT     13
#define SDA_BIT     12

/* I2C device addresses */
#define EEPROM_W    0xA0
#define EEPROM_R    0xA1
#define LM75_R      0x91

/* DS3231 RTC - we use it only for board temperature here */
#define DS3231_W    0xD0
#define DS3231_R    0xD1
#define DS3231_TEMP_MSB  0x11

/* PLL multiplier values (D13..D12) */
#define PLL_X8      0x0000
#define PLL_X10     0x1000
#define PLL_X12     0x2000

#define HW_RD(off)      (*(volatile UWORD *)(RD_BASE + (off)))
#define HW_WR(off,val)  (*(volatile UWORD *)(WR_BASE + (off)) = (val))

/*------------------------------------------------------------------------------
 * I2C bit-bang primitives
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
    UWORD val = HW_RD(REG_STATUS);
    return (val & (1 << SDA_IN_BIT)) ? 1 : 0;
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
    int i;
    int ack;

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
 * LM75 temperature read
 *----------------------------------------------------------------------------*/
static int lm75_read(int *temp_x10)
{
    UBYTE msb, lsb;
    int raw, integer;

    i2c_start();
    if (i2c_write_byte(LM75_R) != 0) {
        i2c_stop();
        return 0;
    }
    msb = i2c_read_byte(0);
    lsb = i2c_read_byte(1);
    i2c_stop();

    raw = (int)((signed char)msb);
    integer = raw * 10;
    if (lsb & 0x80) {
        if (raw >= 0) integer += 5;
        else          integer -= 5;
    }
    *temp_x10 = integer;
    return 1;
}

/*------------------------------------------------------------------------------
 * DS3231 board temperature read
 *
 * Reads register 0x11 (MSB, signed int) + 0x12 (LSB, bits 7-6 = fraction).
 * Resolution 0.25 C, but we round to 0.1 C for display consistency.
 * DS3231 updates internal temperature every 64 seconds automatically.
 *
 * Output: *temp_x10 = temperature in tenths of degree C (e.g. 235 = 23.5)
 * Returns: 1 OK, 0 error
 *----------------------------------------------------------------------------*/
static int ds3231_temp_read(int *temp_x10)
{
    UBYTE msb, lsb;
    int raw, integer, frac;

    /* Phase 1: write register pointer to 0x11 */
    i2c_start();
    if (i2c_write_byte(DS3231_W) != 0) { i2c_stop(); return 0; }
    if (i2c_write_byte(DS3231_TEMP_MSB) != 0) { i2c_stop(); return 0; }

    /* Phase 2: repeated start, read 2 bytes */
    i2c_start();
    if (i2c_write_byte(DS3231_R) != 0) { i2c_stop(); return 0; }

    msb = i2c_read_byte(0);     /* ACK */
    lsb = i2c_read_byte(1);     /* NACK on last */
    i2c_stop();

    /* MSB is signed integer part. LSB bits 7-6 = quarters (0.25 C steps) */
    raw = (int)((signed char)msb);
    integer = raw * 10;
    frac = ((lsb >> 6) & 0x03);     /* 0, 1, 2 or 3 quarters */

    /* Round 0.00, 0.25, 0.50, 0.75 to nearest 0.1 step */
    /* 0->0, 1->3 (0.25->0.3), 2->5 (0.50->0.5), 3->8 (0.75->0.8) */
    if (raw >= 0) {
        switch (frac) {
            case 1: integer += 3; break;
            case 2: integer += 5; break;
            case 3: integer += 8; break;
            default: break;
        }
    } else {
        switch (frac) {
            case 1: integer -= 3; break;
            case 2: integer -= 5; break;
            case 3: integer -= 8; break;
            default: break;
        }
    }

    *temp_x10 = integer;
    return 1;
}

/*------------------------------------------------------------------------------
 * EEPROM write PLL config byte at addr 0x0000 (24LC32 - 16-bit address)
 *
 * 24LC32 uses 2-byte memory addressing (4 KB capacity):
 *   START -> 0xA0 -> ADDR_HI -> ADDR_LO -> DATA -> STOP
 *
 * For 24LC02 (256 B), the sequence would be:
 *   START -> 0xA0 -> ADDR -> DATA -> STOP
 *----------------------------------------------------------------------------*/
static int eeprom_write_config(UBYTE data)
{
    i2c_start();
    if (i2c_write_byte(EEPROM_W) != 0) { i2c_stop(); return 0; }
    if (i2c_write_byte(0x00)     != 0) { i2c_stop(); return 0; }  /* addr HI */
    if (i2c_write_byte(0x00)     != 0) { i2c_stop(); return 0; }  /* addr LO */
    if (i2c_write_byte(data)     != 0) { i2c_stop(); return 0; }
    i2c_stop();
    Delay(1);  /* wait for write cycle (~5 ms for 24LC32) */
    return 1;
}

/*------------------------------------------------------------------------------
 * Read PLL multiplier / card detect
 *----------------------------------------------------------------------------*/
static int read_pll_multiplier(void)
{
    UWORD sel = (HW_RD(REG_PLL_R) >> 12) & 0x3;
    switch (sel) {
        case 0: return 8;
        case 1: return 10;
        case 2: return 12;
        default: return 0;
    }
}

static int check_card(void)
{
    if (((HW_RD(REG_ID0) >> 12) & 0xF) != 0xA) return 0;
    if (((HW_RD(REG_ID1) >> 12) & 0xF) != 0x6) return 0;
    if (((HW_RD(REG_ID2) >> 12) & 0xF) != 0x4) return 0;
    if (((HW_RD(REG_ID3) >> 12) & 0xF) != 0x0) return 0;
    return 1;
}

/*------------------------------------------------------------------------------
 * Terminal control
 *----------------------------------------------------------------------------*/
static void clear_screen(void) { printf("\x1b[H\x1b[J"); fflush(stdout); }
static void cursor_home(void)  { printf("\x1b[H");       fflush(stdout); }

/*------------------------------------------------------------------------------
 * Enable/disable raw keyboard mode (character-at-a-time, no line buffering)
 *----------------------------------------------------------------------------*/
static void set_raw_mode(int raw)
{
    BPTR in = Input();
    if (in) SetMode(in, raw ? 1 : 0);
}

/*------------------------------------------------------------------------------
 * Non-blocking keyboard poll. Returns char or -1.
 *----------------------------------------------------------------------------*/
static int check_key(void)
{
    BPTR in = Input();
    char c;
    if (!in) return -1;

    /* WaitForChar timeout 1us = essentially non-blocking */
    if (WaitForChar(in, 1)) {
        if (Read(in, &c, 1) == 1) return (int)(unsigned char)c;
    }
    return -1;
}

static void format_uptime(ULONG seconds, char *buf)
{
    ULONG h = seconds / 3600;
    ULONG m = (seconds / 60) % 60;
    ULONG s = seconds % 60;
    sprintf(buf, "%lu:%02lu:%02lu", h, m, s);
}

/*------------------------------------------------------------------------------
 * Convert DateStamp to total seconds since 1978-01-01.
 * Used to compute real elapsed time independent of loop overhead.
 *----------------------------------------------------------------------------*/
static ULONG datestamp_to_seconds(const struct DateStamp *ds)
{
    return (ULONG)ds->ds_Days * 86400UL +
           (ULONG)ds->ds_Minute * 60UL +
           (ULONG)(ds->ds_Tick / TICKS_PER_SECOND);
}

/*------------------------------------------------------------------------------
 * PLL change via EEPROM (takes effect after reboot)
 *----------------------------------------------------------------------------*/
static void change_pll(UBYTE code, char *msg)
{
    static const char *const names[3] = {
        "x8 (28 MHz)",
        "x10 (35 MHz)",
        "x12 (42 MHz)"
    };

    if (code > 2) {
        strcpy(msg, "ERROR: invalid PLL code");
        return;
    }

    if (!eeprom_write_config(code)) {
        strcpy(msg, "ERROR: EEPROM write failed (no ACK)");
        return;
    }
    sprintf(msg, "Saved %s to EEPROM - REBOOT to apply", names[code]);
}

/*------------------------------------------------------------------------------
 * Handle keyboard input; returns 1 if quit requested
 *----------------------------------------------------------------------------*/
static int handle_key(int key, char *status_buf, const char **status_msg,
                      int *status_ticks, int *first_reading)
{
    switch (key) {
        case 'q': case 'Q': case 0x03:
            return 1;

        case '8':
            change_pll(0, status_buf);
            *status_msg = status_buf;
            *status_ticks = 5;
            return 0;

        case '0':
            change_pll(1, status_buf);
            *status_msg = status_buf;
            *status_ticks = 5;
            return 0;

        case '2':
            change_pll(2, status_buf);
            *status_msg = status_buf;
            *status_ticks = 5;
            return 0;

        case 'r': case 'R':
            *first_reading = 1;
            strcpy(status_buf, "Min/max reset");
            *status_msg = status_buf;
            *status_ticks = 2;
            return 0;
    }
    return 0;
}

/*==============================================================================
 * Main
 *============================================================================*/
int main(int argc, char *argv[])
{
    int mult, temp_x10, ok;
    int board_temp_x10, board_ok;
    ULONG uptime = 0;
    ULONG start_time;
    struct DateStamp ds;
    char uptime_buf[16];
    int mhz;
    int temp_min = 0;
    int temp_max = 0;
    int first_reading = 1;

    static const char *HELP_LINE1 =
        "CPU multiplier:  8=x8 (28MHz)  0=x10 (35MHz)  2=x12 (42MHz)";
    static const char *HELP_LINE2 =
        "Other options:   r=reset temp  q=quit";
    const char *status_msg = NULL;
    char status_buf[80];
    int status_ticks = 0;
    int broken = 0;
    int key, i;

    if (!check_card()) {
        printf("ERROR: A640 card not detected!\n");
        printf("Check MMU config allows $E80000.\n");
        return RETURN_FAIL;
    }

    set_raw_mode(1);
    clear_screen();

    /* Capture start time for accurate uptime measurement */
    DateStamp(&ds);
    start_time = datestamp_to_seconds(&ds);

    while (!broken) {
        /* Read sensors */
        mult = read_pll_multiplier();
        switch (mult) {
            case 8:  mhz = 28; break;
            case 10: mhz = 35; break;
            case 12: mhz = 42; break;
            default: mhz = 0;  break;
        }

        ok = lm75_read(&temp_x10);
        if (ok) {
            if (first_reading) {
                temp_min = temp_max = temp_x10;
                first_reading = 0;
            } else {
                if (temp_x10 < temp_min) temp_min = temp_x10;
                if (temp_x10 > temp_max) temp_max = temp_x10;
            }
        }

        board_ok = ds3231_temp_read(&board_temp_x10);

        /* Compute real uptime from system clock (not affected by loop overhead) */
        DateStamp(&ds);
        uptime = datestamp_to_seconds(&ds) - start_time;

        /* Redraw screen */
        cursor_home();
        printf("A640 Monitor v1.3  (interactive)\n");
        printf("================================\n\n");

        if (mult > 0)
            printf("  Clock:       x%-2d (%d MHz)            \n", mult, mhz);
        else
            printf("  Clock:       UNKNOWN                  \n");

        if (ok) {
            int whole = temp_x10 / 10;
            int frac  = temp_x10 % 10;
            int min_w = temp_min / 10;
            int min_f = temp_min % 10;
            int max_w = temp_max / 10;
            int max_f = temp_max % 10;
            if (frac  < 0) frac  = -frac;
            if (min_f < 0) min_f = -min_f;
            if (max_f < 0) max_f = -max_f;
            printf("  CPU temp:    %d.%d C                  \n", whole, frac);
            printf("  Min / Max:   %d.%d C / %d.%d C           \n",
                   min_w, min_f, max_w, max_f);
        } else {
            printf("  CPU temp:    LM75 not responding      \n");
            printf("  Min / Max:   ---                      \n");
        }

        if (board_ok) {
            int bw = board_temp_x10 / 10;
            int bf = board_temp_x10 % 10;
            if (bf < 0) bf = -bf;
            printf("  Board temp:  %d.%d C                  \n", bw, bf);
        } else {
            printf("  Board temp:  DS3231 not responding    \n");
        }

        format_uptime(uptime, uptime_buf);
        printf("  Uptime:      %-20s    \n\n", uptime_buf);
        /* Show either two-line help or a temporary status message */
        if (status_msg == NULL) {
            printf("  %-78s\n", HELP_LINE1);
            printf("  %-78s\n", HELP_LINE2);
        } else {
            printf("  %-78s\n", status_msg);
            printf("  %-78s\n", "");
        }

        /* Status message countdown */
        if (status_ticks > 0) {
            status_ticks--;
            if (status_ticks == 0) status_msg = NULL;
        }

        fflush(stdout);

        /* Sleep 2s in 0.2s chunks, polling keyboard each chunk */
        for (i = 0; i < 10; i++) {
            Delay(10);   /* 10 ticks = 0.2 s */

            key = check_key();
            if (key >= 0) {
                if (handle_key(key, status_buf, &status_msg,
                               &status_ticks, &first_reading)) {
                    broken = 1;
                    break;
                }
                break;  /* redraw immediately on any key */
            }
            if (SetSignal(0, 0) & SIGBREAKF_CTRL_C) {
                broken = 1;
                break;
            }
        }
    }

    set_raw_mode(0);
    printf("\n\nMonitor stopped.\n");
    return RETURN_OK;
}
