-- =============================================================================
-- A640 Accelerator - Main Logic
-- =============================================================================
-- Adapts a 68040 processor to the Amiga 600 motherboard (68000 bus).
-- Provides:
--   • 68040 › 68000 bus cycle conversion (synchronized to CLK7M)
--   • 32-bit to 16-bit bus sizing (via external bus sizer CPLD)
--   • 64MB SDRAM controller ($40000000-$43FFFFFF)
--   • Zorro III space autoconfig for SDRAM registration
--   • NB3N3020 PLL clock configuration (I2C EEPROM)
--
-- Target: Xilinx XC95288XL CPLD
-- Clock:  CLKIN from PLL (2× CPU frequency, e.g. 84MHz for 42MHz CPU)
-- =============================================================================

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;

ENTITY MAIN_LOGIC IS
    GENERIC (
        REFRESH_CYCLES : INTEGER := 2;   -- SDRAM refresh tRFC wait cycles
        REFRESH_PERIOD : INTEGER := 56   -- Refresh interval in CLK7M cycles (~7.9us)
    );
    PORT (
        -- System clocks and reset
        CLKIN  : IN    STD_LOGIC;          -- Master clock from PLL (2× CPU freq)
        JP     : IN    STD_LOGIC;          -- Jumper: CLK7M sync mode select
        CLK7M  : IN    STD_LOGIC;          -- 7.09MHz Amiga system clock (async to CLKIN)
        RESET  : INOUT STD_LOGIC;          -- Active-low system reset (active-low, active-high, active-low active-high active-low)

        -- 68040 processor interface
        A40    : IN    STD_LOGIC_VECTOR(31 DOWNTO 0);  -- Address bus
        SIZ40  : IN    STD_LOGIC_VECTOR(1 DOWNTO 0);   -- Transfer size
        RW40   : IN    STD_LOGIC;                       -- Read/Write (1=read)
        TM40   : IN    STD_LOGIC_VECTOR(2 DOWNTO 0);   -- Transfer modifier
        TT40   : IN    STD_LOGIC_VECTOR(1 DOWNTO 0);   -- Transfer type
        TS40   : IN    STD_LOGIC;                       -- Transfer start (active low)
        RSTO40 : IN    STD_LOGIC;                       -- Reset output from 68040
        PCLK   : OUT   STD_LOGIC;                       -- Processor clock output
        BCLK   : OUT   STD_LOGIC;                       -- Bus clock (CLKIN/2)
        RSTI40 : OUT   STD_LOGIC;                       -- Reset input to 68040
        IPL40  : OUT   STD_LOGIC_VECTOR(2 DOWNTO 0);   -- Interrupt priority to 68040
        TBI40  : OUT   STD_LOGIC;                       -- Transfer burst inhibit
        TCI40  : OUT   STD_LOGIC;                       -- Transfer cache inhibit
        TA40   : OUT   STD_LOGIC;                       -- Transfer acknowledge
        BR40   : INOUT STD_LOGIC;                       -- Bus request to 68040
        BG40   : OUT   STD_LOGIC;                       -- Bus grant to 68040

        -- 68000 bus interface (directly from Amiga motherboard accent accent)
        AL     : INOUT STD_LOGIC_VECTOR(1 DOWNTO 0);   -- Address low bits (active accent)
        AS     : INOUT STD_LOGIC;                       -- Address strobe (active low)
        UDS    : INOUT STD_LOGIC;                       -- Upper data strobe (active low)
        LDS    : OUT   STD_LOGIC;                       -- Lower data strobe (active low)
        RW     : OUT   STD_LOGIC;                       -- Read/Write to bus
        DTACK  : IN    STD_LOGIC;                       -- Data transfer acknowledge
        BR     : OUT   STD_LOGIC;                       -- Bus request
        BG     : IN    STD_LOGIC;                       -- Bus grant
        BGACK  : OUT   STD_LOGIC;                       -- Bus grant acknowledge
        BERR   : INOUT STD_LOGIC;                       -- Bus error
        IPL    : IN    STD_LOGIC_VECTOR(2 DOWNTO 0);   -- Interrupt priority from motherboard

        -- Bus sizer control (external CPLD)
        OE_BS  : OUT   STD_LOGIC;                       -- Output enable
        LE_BS  : INOUT STD_LOGIC;                       -- Latch enable (rising edge captures data)
        DIR_BS : OUT   STD_LOGIC;                       -- Direction (1=read from bus, 0=write)
        BWL_BS : OUT   STD_LOGIC_VECTOR(2 DOWNTO 0);   -- Byte/Word/Long select

        -- Address bus buffer control
        A_OE   : OUT   STD_LOGIC;                       -- Address buffer output enable
        A_DIR  : OUT   STD_LOGIC;                       -- Address buffer direction

        -- SDRAM interface
        RAM_DIR : OUT   STD_LOGIC;                      -- Data buffer direction
        RAM_OE  : OUT   STD_LOGIC;                      -- Data buffer output enable
        CEN     : OUT   STD_LOGIC;                      -- Clock enable
        ARAM    : OUT   STD_LOGIC_VECTOR(12 DOWNTO 0);  -- Address
        SDR_CLK : OUT   STD_LOGIC;                      -- SDRAM clock
        BA      : INOUT STD_LOGIC_VECTOR(1 DOWNTO 0);   -- Bank address
        RAS     : OUT   STD_LOGIC;                      -- Row address strobe
        CAS     : OUT   STD_LOGIC;                      -- Column address strobe
        WE      : OUT   STD_LOGIC;                      -- Write enable
        DQ      : OUT   STD_LOGIC_VECTOR(3 DOWNTO 0);   -- Data mask (DQM)

        -- Autoconfig data bus (directly accent accent accent accent accent accent accent accent accent accent accent accent accent accent)
        D       : INOUT STD_LOGIC_VECTOR(15 DOWNTO 12); -- Shared data nibble

        -- PLL configuration (NB3N3020 via I2C EEPROM)
        PLL_SCL  : OUT   STD_LOGIC;
        PLL_SDA  : INOUT STD_LOGIC;
        PLL_SEL0 : OUT   STD_LOGIC;
        PLL_SEL1 : OUT   STD_LOGIC;
        PLL_SEL2 : OUT   STD_LOGIC
    );
END MAIN_LOGIC;

ARCHITECTURE BEHAVIORAL OF MAIN_LOGIC IS

    -- COMPONENT DECLARATIONS

    COMPONENT SDRAM_CONTROLLER IS
        GENERIC (
            REFRESH_CYCLES : INTEGER := 2;
            REFRESH_PERIOD : INTEGER := 56
        );
        PORT (
            CLK_SDRAM : IN  STD_LOGIC;
            CLK7M     : IN  STD_LOGIC;
            CLK_RAM   : IN  STD_LOGIC;
            RESET     : IN  STD_LOGIC;
            BERR      : IN  STD_LOGIC;
            A40       : IN  STD_LOGIC_VECTOR(31 DOWNTO 0);
            SIZ40     : IN  STD_LOGIC_VECTOR(1 DOWNTO 0);
            RW40      : IN  STD_LOGIC;
            TS40      : IN  STD_LOGIC;
            TT40      : IN  STD_LOGIC_VECTOR(1 DOWNTO 0);
            TM40      : IN  STD_LOGIC_VECTOR(2 DOWNTO 0);
            TA40_OUT  : OUT STD_LOGIC;
            TBI40     : OUT STD_LOGIC;
            TCI40     : OUT STD_LOGIC;
            SDR_CLK   : OUT STD_LOGIC;
            BA        : INOUT STD_LOGIC_VECTOR(1 DOWNTO 0);
            RAS       : OUT STD_LOGIC;
            CAS       : OUT STD_LOGIC;
            WE        : OUT STD_LOGIC;
            DQ        : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
            ARAM      : OUT STD_LOGIC_VECTOR(12 DOWNTO 0);
            CEN       : OUT STD_LOGIC;
            RAM_OE    : OUT STD_LOGIC;
            RAM_DIR   : OUT STD_LOGIC
        );
    END COMPONENT;

    COMPONENT pll_config IS
        PORT (
            CLK         : IN    STD_LOGIC;
            nRESET      : IN    STD_LOGIC;
            ADDR        : IN    STD_LOGIC_VECTOR(4 DOWNTO 2);
            REG_CS      : IN    STD_LOGIC;
            nDS         : IN    STD_LOGIC;
            RnW         : IN    STD_LOGIC;
            D_IN        : IN    STD_LOGIC_VECTOR(15 DOWNTO 12);
            D_OUT       : OUT   STD_LOGIC_VECTOR(15 DOWNTO 12);
            SCL         : OUT   STD_LOGIC;
            SDA         : INOUT STD_LOGIC;
            SEL0        : OUT   STD_LOGIC;
            SEL1        : OUT   STD_LOGIC;
            SEL2        : OUT   STD_LOGIC;
            CONFIG_DONE : OUT   STD_LOGIC;
            X12_PLL     : OUT   STD_LOGIC_VECTOR(1 DOWNTO 0)
        );
    END COMPONENT;

    -- CONSTANTS

    -- 68040 transfer size encoding
    CONSTANT SIZE_BYTE     : STD_LOGIC_VECTOR(1 DOWNTO 0) := "01";
    CONSTANT SIZE_WORD     : STD_LOGIC_VECTOR(1 DOWNTO 0) := "10";
    CONSTANT SIZE_3BYTE    : STD_LOGIC_VECTOR(1 DOWNTO 0) := "11";
    CONSTANT SIZE_LONGWORD : STD_LOGIC_VECTOR(1 DOWNTO 0) := "00";

    CONSTANT LITBUF     : STD_LOGIC := '1';

    -- CLOCK GENERATION

    SIGNAL CLK_SDRAM   : STD_LOGIC := '1';        -- SDRAM clock (= CLKIN)
    SIGNAL BCLK_BAR    : STD_LOGIC := '0';         -- Bus clock (CLKIN/2)
    SIGNAL count       : STD_LOGIC_VECTOR(1 DOWNTO 0);

    -- CLK7M synchronization (async › CLKIN domain)
    SIGNAL CLK7M_sync1 : STD_LOGIC := '1';
    SIGNAL CLK7M_sync2 : STD_LOGIC := '1';

    -- CLK7M edge detector (3-bit shift register, sampled on FALLING_EDGE)
    -- "110" = falling edge of CLK7M
    -- "001" = rising edge of CLK7M
    -- "011" = rising edge (alternate pattern)
    SIGNAL CLK7_EDGE   : STD_LOGIC_VECTOR(2 DOWNTO 0) := "111";

    -- RESET LOGIC

    SIGNAL RSTI_BAR    : STD_LOGIC := '0';          -- Synchronized reset for 68040

    -- -------------------------------------------------------------------------
    -- 68000 BUS CYCLE STATE MACHINE
    -- -------------------------------------------------------------------------
    -- Emulates 68000 bus timing on the Amiga motherboard.
    -- Each state waits for a specific CLK7M edge, matching the original
    -- 68000 half-cycle timing (S0-S7).
    --
    -- Timing (per state = half CLK7M cycle ? 70ns):
    --   S0: Idle, wait for falling CLK7M ("110")
    --   S1: Assert AS, DS(read), wait for rising CLK7M ("011")
    --   S2: Wait for falling CLK7M ("110")
    --   S3: Assert DS(write), wait for rising CLK7M ("001")
    --   S4: Check DTACK, wait for falling CLK7M ("110")
    --   S5: Wait for rising CLK7M ("001")
    --   S6: Deassert DS, wait for falling CLK7M ("110")
    --   S7: Deassert AS, latch data, wait for rising CLK7M ("001")
    -- -------------------------------------------------------------------------

    TYPE STATE68K IS (S0, S1, S2, S3, S4, S5, S6, S7);
    SIGNAL CURRENT_STATE_68K : STATE68K := S0;

    SIGNAL SM_ENABLED : STD_LOGIC := '0';          -- State machine enable
    SIGNAL AS_000     : STD_LOGIC := '1';           -- Internal AS
    SIGNAL RW_000     : STD_LOGIC := '1';           -- Internal R/W
    SIGNAL DS_EN      : STD_LOGIC := '1';           -- Data strobe enable
    SIGNAL LE_BAR     : STD_LOGIC := '0';           -- Latch enable source

    -- DTACK synchronization (raw DTACK › CLKIN domain)
    SIGNAL DTACK_sync1 : STD_LOGIC := '1';
    SIGNAL DTACK_sync2 : STD_LOGIC := '1';

    -- UDS/LDS GENERATION

    SIGNAL SIZE  : STD_LOGIC_VECTOR(1 DOWNTO 0);   -- Latched SIZ40
    SIGNAL ADDR  : STD_LOGIC_VECTOR(1 DOWNTO 0);   -- Latched A40(1:0)
    SIGNAL LDS_N : STD_LOGIC := '1';
    SIGNAL UDS_N : STD_LOGIC := '1';

    -- -------------------------------------------------------------------------
    -- LATCH ENABLE CHAIN (LE_BAR › LE4)
    -- -------------------------------------------------------------------------
    -- Generates a pulse on LE4 that:
    --   1. Triggers the external bus sizer latch (LE_BS rising edge)
    --   2. Signals end-of-cycle to the sizing state machine (TERM)
    --
    -- Chain: LE_BAR(CLKIN) › LE1(BCLK) › LE2(BCLK) › LE3(BCLK) › LE4(CLKIN)
    -- LE3 is edge detector: LE1 AND NOT LE2 (pulse on LE_BAR 0›1)
    -- LE4 on CLKIN gives ~12ns earlier capture than on BCLK (critical at 42MHz)
    -- -------------------------------------------------------------------------

    SIGNAL LE1  : STD_LOGIC := '1';
    SIGNAL LE2  : STD_LOGIC := '1';
    SIGNAL LE3  : STD_LOGIC := '1';
    SIGNAL LE4  : STD_LOGIC := '1';
    SIGNAL TERM : STD_LOGIC := '0';                 -- End-of-cycle for sizing SM

    -- -------------------------------------------------------------------------
    -- BUS SIZING STATE MACHINE
    -- -------------------------------------------------------------------------
    -- Converts 68040 32-bit transfers to 16-bit bus cycles.
    -- For longword transfers: two word cycles (upper then lower).
    -- Controls address bits AL(1:0) and byte lane selects BWL_BS.
    -- -------------------------------------------------------------------------

    TYPE SM_SIZING IS (
        IDLE,                -- Waiting for new transfer
        SIZE_DECODE,         -- First word cycle active
        GET_LOW_WORD,        -- Second word of longword transfer
        CYCLE_END            -- Acknowledge cycle completion
    );

    SIGNAL SIZING      : SM_SIZING;
    SIGNAL SIZING_D    : SM_SIZING;                 -- Next state (combinational)
    SIGNAL AL_D        : STD_LOGIC_VECTOR(1 DOWNTO 0) := "11";
    SIGNAL BWL_BS_D    : STD_LOGIC_VECTOR(2 DOWNTO 0);

    -- Transfer size decode
    SIGNAL BYTE : STD_LOGIC := '0';
    SIGNAL WORD : STD_LOGIC := '0';
    SIGNAL LONG : STD_LOGIC := '0';

    -- Bus cycle control
    SIGNAL LDTACK   : STD_LOGIC := '1';             -- Latched DTACK
    SIGNAL NAMIACC  : STD_LOGIC := '0';             -- Non-Amiga access (inhibits 68K SM)
    SIGNAL RST_TERM : STD_LOGIC := '0';             -- Reset for LDTACK
    SIGNAL TA40_BAR : STD_LOGIC := '0';             -- TA40 for non-RAM cycles
    SIGNAL AMISEL   : STD_LOGIC := '0';             -- Amiga bus selected

    -- ADDRESS DECODING

    SIGNAL RAM_ADDR : STD_LOGIC := '0';             -- SDRAM space ($40xxxxxx)

    -- AUTOCONFIG

    SIGNAL AC_ADDRESS_DECODE : STD_LOGIC;
    SIGNAL AC_OUT            : STD_LOGIC;            -- '1' = autoconfig active
    SIGNAL AC_DATA           : STD_LOGIC_VECTOR(3 DOWNTO 0);

    -- SDRAM CONTROLLER INTERFACE

    SIGNAL TA40_FB : STD_LOGIC;                     -- TA40 feedback from SDRAM ctrl

    -- PLL CONFIGURATION INTERFACE

    SIGNAL pll_reg_cs_wr : STD_LOGIC := '0';
    SIGNAL pll_d_out     : STD_LOGIC_VECTOR(15 DOWNTO 12);

begin

    -- -------------------------------------------------------------------------
    -- SECTION 1: CLOCK GENERATION AND SYNCHRONIZATION
    -- -------------------------------------------------------------------------

    -- Master clock assignments
    CLK_SDRAM <= CLKIN;
    PCLK      <= CLKIN;
    BCLK      <= BCLK_BAR;

    -- BCLK generation: divide CLKIN by 2
    PROCESS (CLKIN) IS
    BEGIN
        IF RISING_EDGE(CLKIN) THEN
            count    <= count + 1;
            BCLK_BAR <= count(0);

            CLK7M_sync1 <= CLK7M;
            CLK7M_sync2 <= CLK7M_sync1;
        END IF;
    END PROCESS;

    PROCESS (CLKIN, RESET) IS
    BEGIN
        IF RESET = '0' THEN
            CLK7_EDGE <= "111";
        ELSIF FALLING_EDGE(CLKIN) THEN
            IF JP = '0' THEN
                CLK7_EDGE <= CLK7_EDGE(1) & CLK7_EDGE(0) & CLK7M_sync2;
            ELSE
                CLK7_EDGE <= CLK7_EDGE(1) & CLK7_EDGE(0) & CLK7M_sync1;
            END IF;
        END IF;
    END PROCESS;

    -- DTACK double synchronizer (raw DTACK › CLKIN domain)
    PROCESS (CLKIN) IS
    BEGIN
        IF RISING_EDGE(CLKIN) THEN
            DTACK_sync1 <= DTACK;
            DTACK_sync2 <= DTACK_sync1;
        END IF;
    END PROCESS;

    -- -------------------------------------------------------------------------
    -- SECTION 2: RESET LOGIC
    -- -------------------------------------------------------------------------

    -- Active-low reset: directly, active-low, active-high output.
    RESET  <= '0' WHEN RSTO40 = '0' ELSE 'Z';
    RSTI40 <= RSTI_BAR;

    -- Synchronize RESET to BCLK domain
    PROCESS (BCLK_BAR) IS
    BEGIN
        IF RISING_EDGE(BCLK_BAR) THEN
            RSTI_BAR <= RESET;
        END IF;
    END PROCESS;

    -- Interrupt passthrough (active during reset: force IPL to all-ones)
    -- IPL40 during RSTI rising edge: configures MC68040 output buffer impedance
    -- "111" = small buffers (5mA/pin) for data, address & transfer, control
    -- "000" = large buffers (55mA/pin) - not recommended for A600
    -- After reset: transparent passthrough of Amiga interrupt priority lines
    IPL40(2) <= (IPL(2) AND RSTI_BAR) OR (NOT RSTI_BAR AND LITBUF);
    IPL40(1) <= (IPL(1) AND RSTI_BAR) OR (NOT RSTI_BAR AND LITBUF);
    IPL40(0) <= (IPL(0) AND RSTI_BAR) OR (NOT RSTI_BAR AND LITBUF);

    -- -------------------------------------------------------------------------
    -- SECTION 3: ADDRESS DECODING
    -- -------------------------------------------------------------------------

    -- SDRAM: $40000000-$43FFFFFF (A31:A26 = "010000")
    RAM_ADDR <= '1' WHEN A40(31 DOWNTO 26) = "010000" AND BERR = '1' ELSE '0';

    -- Autoconfig: $E80000-$E8FFFF (active until configured)
    AC_ADDRESS_DECODE <= '1' WHEN A40(23 DOWNTO 15) = "111010000" AND AC_OUT = '1' ELSE '0';

    -- -------------------------------------------------------------------------
    -- SECTION 4: STATIC BUS CONTROL
    -- -------------------------------------------------------------------------

    -- Bus arbitration (active accent accent accent accent accent accent accent accent)
    BGACK <= '1';       -- Never acknowledge bus grant
    BR    <= '0';       -- Always request bus (active low)
    BR40  <= '1';       -- Never request bus from 68040
    BG40  <= BG;        -- Pass through bus grant

    -- Address buffer: always enabled, direction 68040›bus
    A_OE  <= '0';       -- Output enable (active low)
    A_DIR <= '0';       -- Direction

    -- -------------------------------------------------------------------------
    -- SECTION 5: 68000 BUS CYCLE STATE MACHINE
    -- -------------------------------------------------------------------------

    -- Enable: active when NOT accessing SDRAM and not in reset/terminal state
    SM_ENABLED <= '1' WHEN RAM_ADDR = '0' AND RST_TERM = '0' ELSE '0';

    -- Transfer size and address for UDS/LDS generation
    SIZE <= SIZ40(1) & SIZ40(0);
    ADDR <= A40(1) & A40(0);

    -- UDS/LDS decode based on transfer size and address alignment
    PROCESS (SIZE, ADDR, SM_ENABLED, CLKIN, RESET)
    BEGIN
        IF RESET = '0' OR SM_ENABLED = '0' THEN
            UDS_N <= '1';
            LDS_N <= '1';
        ELSIF RISING_EDGE(CLKIN) THEN
            CASE SIZE IS
                WHEN SIZE_BYTE =>
                    UDS_N <= ADDR(0);            -- Even byte › UDS, Odd › LDS
                    LDS_N <= NOT ADDR(0);
                WHEN SIZE_WORD =>
                    IF ADDR = "11" THEN
                        UDS_N <= '1';
                        LDS_N <= '0';            -- Odd word › LDS only
                    ELSE
                        UDS_N <= '0';
                        LDS_N <= '0';            -- Even word › both
                    END IF;
                WHEN SIZE_3BYTE | SIZE_LONGWORD =>
                    IF ADDR = "11" THEN
                        UDS_N <= '1';
                        LDS_N <= '0';
                    ELSE
                        UDS_N <= '0';
                        LDS_N <= '0';
                    END IF;
                WHEN OTHERS =>
                    UDS_N <= '1';
                    LDS_N <= '1';
            END CASE;
        END IF;
    END PROCESS;

    -- Main 68000 bus cycle state machine
    PROCESS (CLKIN, SM_ENABLED, RESET) IS
    BEGIN
        IF SM_ENABLED = '0' OR RESET = '0' THEN
            CURRENT_STATE_68K <= S0;
            AS_000  <= '1';
            RW_000  <= '1';
            LE_BAR  <= '0';
            DS_EN   <= '0';
        ELSIF RISING_EDGE(CLKIN) THEN
            CASE CURRENT_STATE_68K IS

                -- S0: Idle - wait for falling CLK7M to start cycle
                WHEN S0 =>
                    AS_000 <= '1';
                    RW_000 <= '1';
                    DS_EN  <= '0';
                    IF CLK7_EDGE = "110" THEN
                        CURRENT_STATE_68K <= S1;
                        LE_BAR <= '0';           -- Reset latch enable
                    END IF;

                -- S1: Assert AS; assert DS for read cycles
                WHEN S1 =>
                    IF CLK7_EDGE = "011" THEN
                        AS_000 <= '0';
                        RW_000 <= RW40;
                        IF RW40 = '1' THEN
                            DS_EN <= '1';        -- Read: DS active with AS
                        END IF;
                        CURRENT_STATE_68K <= S2;
                    END IF;

                -- S2: Wait state
                WHEN S2 =>
                    IF CLK7_EDGE = "110" THEN
                        CURRENT_STATE_68K <= S3;
                    END IF;

                -- S3: Assert DS for write cycles
                WHEN S3 =>
                    IF CLK7_EDGE = "001" THEN
                        IF RW40 = '0' THEN
                            DS_EN <= '1';        -- Write: DS delayed per 68000 spec
                        END IF;
                        CURRENT_STATE_68K <= S4;
                    END IF;

                -- S4: Wait for DTACK (synchronized) or BERR
                WHEN S4 =>
                    IF CLK7_EDGE = "110" AND (DTACK_sync2 = '0' OR BERR = '0') THEN
                        CURRENT_STATE_68K <= S5;
                    END IF;

                -- S5: Wait state
                WHEN S5 =>
                    IF CLK7_EDGE = "001" THEN
                        CURRENT_STATE_68K <= S6;
                    END IF;

                -- S6: Deassert DS (data hold per 68000 spec)
                WHEN S6 =>
                    IF CLK7_EDGE = "110" THEN
                        DS_EN <= '0';            -- DS off on falling CLK7M
                        CURRENT_STATE_68K <= S7;
                    END IF;

                -- S7: Deassert AS, trigger latch enable
                WHEN S7 =>
                    AS_000 <= '1';               -- AS off (few ns after DS)
                    LE_BAR <= '1';               -- Trigger latch chain
                    IF CLK7_EDGE = "001" THEN
                        CURRENT_STATE_68K <= S0;
                    END IF;

            END CASE;
        END IF;
    END PROCESS;

    -- Drive bus signals (active only when SM enabled)
    AS  <= AS_000 WHEN SM_ENABLED = '1' ELSE '1';
    UDS <= UDS_N  WHEN DS_EN = '1'      ELSE '1';
    LDS <= LDS_N  WHEN DS_EN = '1'      ELSE '1';
    RW  <= RW_000 WHEN SM_ENABLED = '1' ELSE '1';

    -- -------------------------------------------------------------------------
    -- SECTION 6: LATCH ENABLE CHAIN
    -- -------------------------------------------------------------------------

    -- LE1, LE2, LE3 on BCLK domain (edge detector for LE_BAR)
    PROCESS (BCLK_BAR) IS
    BEGIN
        IF RISING_EDGE(BCLK_BAR) THEN
            LE1 <= LE_BAR;
            LE2 <= LE1;
            LE3 <= LE1 AND NOT LE2;             -- Rising edge pulse of LE_BAR
        END IF;
    END PROCESS;

    -- LE4 on CLKIN domain (gives ~12ns earlier capture than BCLK)
    PROCESS (CLKIN) IS
    BEGIN
        IF RISING_EDGE(CLKIN) THEN
            LE4 <= LE3;
        END IF;
    END PROCESS;

    -- Bus sizer latch enable and sizing termination
    LE_BS <= LE4;
    TERM  <= '1' WHEN LE4 = '1' ELSE '0';

    -- -------------------------------------------------------------------------
    -- SECTION 7: BUS SIZING STATE MACHINE
    -- -------------------------------------------------------------------------

    -- Transfer size classification
    BYTE <= '1' WHEN SIZ40 = "01" ELSE '0';
    WORD <= '1' WHEN SIZ40 = "10" ELSE '0';
    LONG <= '1' WHEN SIZ40 = "11" OR SIZ40 = "00" ELSE '0';

    -- Bus sizer output enable and direction
    AMISEL <= '1' WHEN RSTI_BAR = '1' AND
              ((TT40(1) = '0' AND RAM_ADDR = '0') OR TT40(1) = '1') ELSE '0';
    OE_BS  <= AMISEL;
    DIR_BS <= RW40;

    -- Address low bits output
    AL <= AL_D;

    -- Byte/Word/Long select output
    BWL_BS <= BWL_BS_D;

    -- Reset terminal condition
    RST_TERM <= '1' WHEN RSTI_BAR = '0' OR NAMIACC = '1' ELSE '0';

    -- LDTACK: latched DTACK, reset by RST_TERM
    PROCESS (RST_TERM, BCLK_BAR) IS
    BEGIN
        IF RST_TERM = '1' THEN
            LDTACK <= '1';
        ELSIF RISING_EDGE(BCLK_BAR) THEN
            IF DTACK = '0' OR BERR = '0' THEN
                LDTACK <= DTACK;
            END IF;
        END IF;
    END PROCESS;

    -- Sizing state register and TA40 generation
    PROCESS (BCLK_BAR, RSTI_BAR) IS
    BEGIN
        IF RSTI_BAR = '0' THEN
            SIZING   <= IDLE;
            TA40_BAR <= '1';
        ELSIF RISING_EDGE(BCLK_BAR) THEN
            SIZING <= SIZING_D;
            IF SIZING_D = CYCLE_END OR TT40(1 DOWNTO 0) = "11" THEN
                TA40_BAR <= '0';                 -- Assert TA40 for non-RAM cycles
            ELSE
                TA40_BAR <= '1';
            END IF;
        END IF;
    END PROCESS;

    -- NAMIACC: '1' when not in active Amiga bus cycle
    PROCESS (BCLK_BAR, RSTI_BAR) IS
    BEGIN
        IF RSTI_BAR = '0' THEN
            NAMIACC <= '1';
        ELSIF RISING_EDGE(BCLK_BAR) THEN
            IF SIZING_D = IDLE OR SIZING_D = CYCLE_END THEN
                NAMIACC <= '1';
            ELSE
                NAMIACC <= '0';
            END IF;
        END IF;
    END PROCESS;

    -- Sizing next-state logic (combinational)
    SIZING_SM: PROCESS (SIZING, TS40, A40, AMISEL, RW40, LDTACK,
                        TT40, BYTE, WORD, LONG, TERM, RAM_ADDR) IS
    BEGIN
        CASE SIZING IS

            WHEN IDLE =>
                IF LONG = '0' THEN
                    AL_D <= A40(1 DOWNTO 0);
                ELSE
                    AL_D <= "00";                -- Longword: force aligned
                END IF;
                IF TS40 = '0' AND TT40(1) = '0' AND RAM_ADDR = '0' THEN
                    SIZING_D <= SIZE_DECODE;      -- Start new bus cycle
                ELSE
                    SIZING_D <= IDLE;
                END IF;

            WHEN SIZE_DECODE =>
                IF LONG = '0' THEN
                    AL_D <= A40(1 DOWNTO 0);
                ELSE
                    AL_D <= "00";
                END IF;
                IF TERM = '1' AND LDTACK = '0' AND LONG = '1' THEN
                    SIZING_D <= GET_LOW_WORD;     -- Need second word
                ELSIF TERM = '1' AND LDTACK = '0' AND (WORD = '1' OR BYTE = '1') THEN
                    SIZING_D <= CYCLE_END;        -- Single transfer done
                ELSE
                    SIZING_D <= SIZE_DECODE;       -- Wait for completion
                END IF;

            WHEN GET_LOW_WORD =>
                AL_D <= "10";                     -- Point to lower word
                IF TERM = '1' THEN
                    SIZING_D <= CYCLE_END;
                ELSE
                    SIZING_D <= GET_LOW_WORD;
                END IF;

            WHEN CYCLE_END =>
                AL_D     <= "00";
                SIZING_D <= IDLE;

        END CASE;
    END PROCESS SIZING_SM;

    -- Byte lane decode (combinational)
    BWL_DECODE: PROCESS (SIZING, RW40, BYTE, WORD, LONG, A40, LDTACK)
    BEGIN
        CASE SIZING IS

            WHEN IDLE =>
                BWL_BS_D <= "111";                -- All inactive

            WHEN SIZE_DECODE =>
                -- BIT 0: Lower byte enable
                IF (RW40 = '0' AND NOT(BYTE = '1' AND A40(0) = '1'))
                   OR (RW40 = '1' AND LDTACK = '0') THEN
                    BWL_BS_D(0) <= '0';
                ELSE
                    BWL_BS_D(0) <= '1';
                END IF;
                -- BIT 1: Upper byte enable
                IF (RW40 = '0' AND (LONG = '1' OR (WORD = '1' AND A40(1) = '0')
                    OR (BYTE = '1' AND A40(1) = '0')))
                   OR (RW40 = '1' AND LDTACK = '0') THEN
                    BWL_BS_D(1) <= '0';
                ELSE
                    BWL_BS_D(1) <= '1';
                END IF;
                -- BIT 2: Write strobe
                IF RW40 = '0' THEN
                    BWL_BS_D(2) <= '0';
                ELSE
                    BWL_BS_D(2) <= '1';
                END IF;

            WHEN GET_LOW_WORD =>
                IF RW40 = '0' THEN
                    BWL_BS_D <= "010";            -- Write lower word
                ELSE
                    BWL_BS_D <= "101";            -- Read lower word
                END IF;

            WHEN CYCLE_END =>
                BWL_BS_D <= "111";                -- All inactive

        END CASE;
    END PROCESS BWL_DECODE;

    -- -------------------------------------------------------------------------
    -- SECTION 8: TA40 MUX (Transfer Acknowledge to 68040)
    -- -------------------------------------------------------------------------

    -- Priority: Amiga bus cycles › SDRAM cycles › tri-state
    TA40 <= TA40_BAR WHEN AMISEL = '1'   ELSE
            TA40_FB  WHEN RAM_ADDR = '1' ELSE 'Z';

    -- -------------------------------------------------------------------------
    -- SECTION 9: AUTOCONFIG (Zorro II, 64MB FastRAM at $40000000)
    -- -------------------------------------------------------------------------

    -- Autoconfig data ROM (active only until configured)
    PROCESS (CLK7M)
    BEGIN
        IF RISING_EDGE(CLK7M) THEN
            AC_DATA <= "1111";
            CASE (A40(6 DOWNTO 2) & AL(1)) IS
                WHEN "000000" => AC_DATA <= "1010";  -- Type: RAM, link to free pool
                WHEN "000001" => AC_DATA <= "0010";  -- Product number
                WHEN "000100" => AC_DATA <= "1101";  -- Flags
                WHEN "001001" => AC_DATA <= "1011";  -- Manufacturer ID high
                WHEN "001010" => AC_DATA <= "0010";  -- Manufacturer ID
                WHEN "001011" => AC_DATA <= "1101";  -- Manufacturer ID low
                WHEN "010011" => AC_DATA <= "1110";  -- Serial
                WHEN OTHERS   => AC_DATA <= "1111";
            END CASE;
        END IF;
    END PROCESS;

    -- Data bus drive: autoconfig data or PLL registers
    PROCESS (AS, RW_000, AC_ADDRESS_DECODE, AC_OUT, AC_DATA, pll_d_out, A40) IS
    BEGIN
        IF RW_000 = '1' AND AS = '0' THEN
            IF AC_OUT = '1' THEN
                -- Autoconfig active
                IF AC_ADDRESS_DECODE = '1' THEN
                    D <= AC_DATA;
                ELSE
                    D <= "ZZZZ";
                END IF;
            ELSE
                -- Autoconfig done: PLL registers visible at same address
                IF A40(23 DOWNTO 15) = "111010000" THEN
                    D <= pll_d_out;
                ELSE
                    D <= "ZZZZ";
                END IF;
            END IF;
        ELSE
            D <= "ZZZZ";
        END IF;
    END PROCESS;

    -- Autoconfig write handler (deactivate on config write)
    PROCESS (CLK7M, RESET)
    BEGIN
        IF RESET = '0' THEN
            AC_OUT <= '1';                        -- Autoconfig active after reset
        ELSIF RISING_EDGE(CLK7M) THEN
            IF RW_000 = '0' THEN
                IF AC_ADDRESS_DECODE = '1' AND UDS = '0' THEN
                    CASE (A40(6 DOWNTO 2) & AL(1)) IS
                        WHEN "100100" =>
                            AC_OUT <= '0';        -- Config write › deactivate
                        WHEN "100110" =>
                            NULL;                 -- Shut-up write (ignore)
                        WHEN OTHERS =>
                            NULL;
                    END CASE;
                END IF;
            END IF;
        END IF;
    END PROCESS;

    -- -------------------------------------------------------------------------
    -- SECTION 10: SDRAM CONTROLLER INSTANCE
    -- -------------------------------------------------------------------------

    SDRAM_INST: SDRAM_CONTROLLER
        GENERIC MAP (
            REFRESH_CYCLES => REFRESH_CYCLES,
            REFRESH_PERIOD => REFRESH_PERIOD
        )
        PORT MAP (
            CLK_SDRAM => CLK_SDRAM,
            CLK7M     => CLK7M,
            CLK_RAM   => BCLK_BAR,
            RESET     => RESET,
            BERR      => BERR,
            A40       => A40,
            SIZ40     => SIZ40,
            RW40      => RW40,
            TS40      => TS40,
            TT40      => TT40,
            TM40      => TM40,
            TA40_OUT  => TA40_FB,
            TBI40     => TBI40,
            TCI40     => TCI40,
            SDR_CLK   => SDR_CLK,
            BA        => BA,
            RAS       => RAS,
            CAS       => CAS,
            WE        => WE,
            DQ        => DQ,
            ARAM      => ARAM,
            CEN       => CEN,
            RAM_OE    => RAM_OE,
            RAM_DIR   => RAM_DIR
        );

    -- -------------------------------------------------------------------------
    -- SECTION 11: PLL CONFIGURATION (NB3N3020)
    -- -------------------------------------------------------------------------

    -- Register select for PLL config space ($BExxxx)
    PROCESS (CLK7M, RESET) IS
    BEGIN
        IF RESET = '0' THEN
            pll_reg_cs_wr <= '0';
        ELSIF RISING_EDGE(CLK7M) THEN
            IF A40(23 DOWNTO 16) = "10111110" THEN
                pll_reg_cs_wr <= '1';
            ELSE
                pll_reg_cs_wr <= '0';
            END IF;
        END IF;
    END PROCESS;

    PLL_INST: pll_config
        PORT MAP (
            CLK         => CLK7M,
            nRESET      => RESET,
            ADDR        => A40(4 DOWNTO 2),
            REG_CS      => pll_reg_cs_wr,
            nDS         => UDS,
            RnW         => RW_000,
            D_IN        => D,
            D_OUT       => pll_d_out,
            SCL         => PLL_SCL,
            SDA         => PLL_SDA,
            SEL0        => PLL_SEL0,
            SEL1        => PLL_SEL1,
            SEL2        => PLL_SEL2,
            CONFIG_DONE => OPEN,
            X12_PLL     => OPEN
        );

END BEHAVIORAL;