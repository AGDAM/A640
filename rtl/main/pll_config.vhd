--------------------------------------------------------------------------------
-- A640 PLL Config - I2C read-only engine + bit-bang write
--
-- WERSJA Z ETAPEM 1: tylko SEL piny przeniesione do logiki kombinacyjnej.
-- Usuniête sygna³y sel0_val/sel1_val oraz oba bloki "case pll_reg".
-- Oszczêdnoœæ: -2 macrocells.
-- Reszta kodu identyczna z orygina³em.
--
-- Boot: CPLD reads byte 0 from EEPROM and sets PLL multiplier.
-- Runtime: Amiga writes to EEPROM via bit-bang I2C registers.
--
-- Read registers ($E80000 after autoconfig, D15..D12):
--   +$00  R:  Card ID nibble 0 = $A
--   +$04  R:  Card ID nibble 1 = $6
--   +$08  R:  Card ID nibble 2 = $4
--   +$0C  R:  Card ID nibble 3 = $0
--   +$10  R:  Status: {SDA_IN, 0, PLL_SAVED, CONFIG_DONE}
--   +$14  R:  PLL Control: {0, 0, PLL_SEL[1:0]}
--   +$18  R:  I2C Bitbang: {0, 0, SCL_OUT, SDA_OUT}
--   +$1C  R:  Revision = $1
--
-- Write registers ($BE0000, write-lock protected, D15..D12):
--   +$00  W:  Lock step 2 (key $4)
--   +$0C  W:  Lock step 1 (key $C)
--   +$18  W:  I2C Bitbang: {0, 0, SCL_OUT, SDA_OUT}
--
-- Write lock: write $C to +$0C, then $4 to +$00 -> unlocked
-- Next write to +$18 is accepted, then auto-lock
--
-- EEPROM: 24LC02, 1-byte address (byte 0 = PLL config)
-- PLL encoding (bits 1:0): 00=x8, 01=x10(default), 10=x12
--
-- SEL pin mapping for NB3N3020:
--   x8:  SEL0=0, SEL1=Z (floating)
--   x10: SEL0=1, SEL1=Z (floating)
--   x12: SEL0=0, SEL1=1
--
-- Target: Xilinx XC95288XL CPLD
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity pll_config is
    port (
        CLK         : in    std_logic;                      -- ~7 MHz
        nRESET      : in    std_logic;

        ADDR        : in    std_logic_vector(4 downto 2);
        REG_CS      : in    std_logic;
        nDS         : in    std_logic;
        RnW         : in    std_logic;
        D_IN        : in    std_logic_vector(15 downto 12);
        D_OUT       : out   std_logic_vector(15 downto 12);

        SCL         : out   std_logic;
        SDA         : inout std_logic;

        SEL0        : out std_logic;
        SEL1        : out std_logic;
        SEL2        : out std_logic;

        CONFIG_DONE : out   std_logic;
		  
		  x12_PLL : out std_logic_vector(1 downto 0)
    );
end entity pll_config;

architecture rtl of pll_config is

    -- Card ID
    constant ID_0 : std_logic_vector(3 downto 0) := x"A";
    constant ID_1 : std_logic_vector(3 downto 0) := x"6";
    constant ID_2 : std_logic_vector(3 downto 0) := x"4";
    constant ID_3 : std_logic_vector(3 downto 0) := x"0";
    constant REV  : std_logic_vector(3 downto 0) := x"1";

    -- PLL config
    constant PLL_X8  : std_logic_vector(1 downto 0) := "00";
    constant PLL_X10 : std_logic_vector(1 downto 0) := "01";
    constant PLL_X12 : std_logic_vector(1 downto 0) := "10";
    constant PLL_DEF : std_logic_vector(1 downto 0) := "01";

    -- EEPROM I2C (24LC02 - 1 byte address)
    constant EEPROM_WR : std_logic_vector(7 downto 0) := x"A0";
    constant EEPROM_RD : std_logic_vector(7 downto 0) := x"A1";
    constant I2C_DIV   : integer := 32;

    -- Init delay counter limit
    constant INIT_MAX  : integer := 500;

    -- Registers
    signal pll_reg    : std_logic_vector(1 downto 0) := PLL_DEF;
    signal pll_saved  : std_logic := '0';
    signal cfg_done   : std_logic := '0';
    signal bb_scl     : std_logic := '1';
    signal bb_sda     : std_logic := '1';

    -- Write lock FSM
    type lock_state_t is (LOCKED, GOT_KEY1, UNLOCKED);
    signal lock_state : lock_state_t := LOCKED;

    -- Read mux
    signal reg_data_out : std_logic_vector(3 downto 0);

    -- SDA input
    signal sda_in : std_logic := '1';

    -- I2C read-only boot engine
    type boot_state_t is (
        B_INIT, B_WAIT,
        B_START,
        B_DEV_W, B_ADDR_L,B_ADDR_H,
        B_RESTART,
        B_DEV_R, B_READ_DATA, B_NACK,
        B_STOP,
        B_APPLY, B_IDLE
    );
    signal bstate : boot_state_t := B_INIT;

    type i2c_phase_t is (
        PH_IDLE,
        PH_START_SDA, PH_START_SCL,
        PH_BIT_SDA, PH_BIT_SCL_HI, PH_BIT_SCL_LO,
        PH_ACK_SDA, PH_ACK_SCL_HI, PH_ACK_SCL_LO,
        PH_STOP_SDA_LO, PH_STOP_SCL_HI, PH_STOP_SDA_HI,
        PH_DONE
    );
    signal iphase : i2c_phase_t := PH_IDLE;

    signal scl_hw, sda_hw, sda_hw_oe : std_logic := '1';
    signal i2c_shift    : std_logic_vector(7 downto 0) := x"00";
    signal i2c_bit_cnt  : integer range 0 to 7 := 7;
    signal i2c_reading  : std_logic := '0';
    signal i2c_rd_byte  : std_logic_vector(1 downto 0) := "00";

    -- I2C tick divider
    signal div_cnt : integer range 0 to I2C_DIV-1 := 0;
    signal tick    : std_logic := '0';

    -- Init delay counter
    signal init_cnt  : integer range 0 to INIT_MAX := 0;

    -- Internal reset for I2C engine
    signal i2c_reset : std_logic := '1';

    -- Boot engine active flag
    signal boot_active : std_logic := '1';

begin

	 x12_PLL <= i2c_rd_byte;
	 
    ---------------------------------------------------------------------------
    -- I2C internal reset: active while counter < INIT_MAX and nRESET = '0'
    -- Free-running counter with intentional wraparound ensures boot FSM
    -- restarts on both power-on and warm reset.
    ---------------------------------------------------------------------------
    i2c_reset <= '0' when init_cnt < INIT_MAX and nRESET = '0' else '1';

    ---------------------------------------------------------------------------
    -- I2C bus: hardware engine during boot, bit-bang after
    ---------------------------------------------------------------------------
    sda_in <= SDA;

    SCL <= '0' when (boot_active = '1' and scl_hw = '0') else
           '0' when (boot_active = '0' and bb_scl = '0') else
           'Z';

    SDA <= '0' when (boot_active = '1' and sda_hw_oe = '1' and sda_hw = '0') else
           '0' when (boot_active = '0' and bb_sda = '0') else
           'Z';

    ---------------------------------------------------------------------------
    -- SEL pins: KOMBINACYJNE z pll_reg (oszczêdnoœæ 2 macrocells)
    --   x8:  SEL0=0, SEL1=Z
    --   x10: SEL0=1, SEL1=Z
    --   x12: SEL0=0, SEL1=1
    ---------------------------------------------------------------------------
    SEL2 <= '1';

    SEL0 <= '0' when pll_reg = PLL_X8  else
            '1' when pll_reg = PLL_X10 else
            '0' when pll_reg = PLL_X12 else
            '1';  -- default x10

    SEL1 <= 'Z' when pll_reg = PLL_X8  else
            'Z' when pll_reg = PLL_X10 else
            '1' when pll_reg = PLL_X12 else
            '1';  -- default

    CONFIG_DONE <= cfg_done;

    ---------------------------------------------------------------------------
    -- Read mux
    ---------------------------------------------------------------------------
    process(ADDR, pll_reg, pll_saved, cfg_done, sda_in, bb_scl, bb_sda)
    begin
        reg_data_out <= x"0";
        case ADDR is
            when "000" => reg_data_out <= ID_0;
            when "001" => reg_data_out <= ID_1;
            when "010" => reg_data_out <= ID_2;
            when "011" => reg_data_out <= ID_3;
            when "100" => reg_data_out <= sda_in & '0' & pll_saved & cfg_done;
            when "101" => reg_data_out <= "00" & pll_reg;
            when "110" => reg_data_out <= "00" & bb_scl & bb_sda;
            when "111" => reg_data_out <= REV;
            when others => reg_data_out <= x"0";
        end case;
    end process;

    D_OUT <= reg_data_out;

    ---------------------------------------------------------------------------
    -- Write lock FSM + I2C bitbang write
    --
    -- LOCKED -> (write $C to +$0C) -> GOT_KEY1
    -- GOT_KEY1 -> (write $4 to +$00) -> UNLOCKED
    -- UNLOCKED -> (write to +$18) -> execute + LOCKED (auto-lock)
    ---------------------------------------------------------------------------
    process(CLK, i2c_reset)
    begin
        if i2c_reset = '0' then
            lock_state <= LOCKED;
            bb_scl <= '1';
            bb_sda <= '1';

        elsif rising_edge(CLK) then
            if nDS = '0' and REG_CS = '1' and RnW = '0' then

                case lock_state is
                    when LOCKED =>
                        if D_IN(15 downto 12) = x"C" and ADDR = "011" then
                            lock_state <= GOT_KEY1;
                        end if;

                    when GOT_KEY1 =>
                        if D_IN(15 downto 12) = x"4" and ADDR = "000" then
                            lock_state <= UNLOCKED;
                        else
                            lock_state <= LOCKED;
                        end if;

                    when UNLOCKED =>
                        if ADDR = "101" then
                            null;
                        elsif ADDR = "110" then
                            bb_scl <= D_IN(13);
                            bb_sda <= D_IN(12);
                        end if;
                        lock_state <= LOCKED;

                    when others =>
                        lock_state <= LOCKED;
                end case;

            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- I2C tick divider
    ---------------------------------------------------------------------------
    process(CLK, i2c_reset)
    begin
        if i2c_reset = '0' then
            div_cnt <= 0; tick <= '0';
        elsif rising_edge(CLK) then
            tick <= '0';
            if div_cnt = I2C_DIV - 1 then
                div_cnt <= 0; tick <= '1';
            else
                div_cnt <= div_cnt + 1;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Init delay counter: free-running 0..INIT_MAX with intentional wraparound.
    -- Pauses at INIT_MAX while nRESET='0' to allow I2C bus stabilization.
    -- After reset release, counter wraps to 0 and i2c_reset pulses low
    -- for INIT_MAX clock cycles, triggering boot FSM restart.
    ---------------------------------------------------------------------------
    process(CLK)
    begin
        if rising_edge(CLK) then
            if init_cnt = INIT_MAX and nRESET = '0' then
                null;  -- hold at max during reset
            else
                init_cnt <= init_cnt + 1;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- I2C sub-engine + Boot FSM + PLL register
    -- (sygna³y sel0_val/sel1_val USUNIÊTE - SEL piny kombinacyjne wy¿ej)
    ---------------------------------------------------------------------------
    process(CLK, i2c_reset)
    begin
        if i2c_reset = '0' then
            bstate      <= B_INIT;
            iphase      <= PH_IDLE;
            scl_hw      <= '1';
            sda_hw      <= '1';
            sda_hw_oe   <= '0';
            i2c_shift   <= x"00";
            i2c_bit_cnt <= 7;
            i2c_reading <= '0';
            i2c_rd_byte <= "00";
            pll_reg     <= PLL_DEF;
            pll_saved   <= '0';
            cfg_done    <= '0';
            boot_active <= '1';

        elsif rising_edge(CLK) then

            -- Accept PLL write from bus (when unlocked, boot finished)
            -- USUNIÊTY case pll_reg z sel0_val/sel1_val - SEL piny kombinacyjne
            if boot_active = '0' and nDS = '0' and REG_CS = '1'
               and RnW = '0' and lock_state = UNLOCKED and ADDR = "101" then
                pll_reg <= D_IN(13 downto 12);
                cfg_done <= '1';
            end if;

            -- I2C engine runs on tick
            if tick = '1' then

                ---------------------------------------------------------
                -- I2C sub-phases
                ---------------------------------------------------------
                case iphase is
                    when PH_IDLE =>
                        null;

                    when PH_START_SDA =>
                        scl_hw <= '1';
                        sda_hw_oe <= '1'; sda_hw <= '0';
                        iphase <= PH_START_SCL;
                    when PH_START_SCL =>
                        scl_hw <= '0';
                        iphase <= PH_DONE;

                    when PH_BIT_SDA =>
                        scl_hw <= '0';
                        if i2c_reading = '1' then
                            sda_hw_oe <= '0';
                        else
                            sda_hw_oe <= '1';
                            sda_hw <= i2c_shift(7);
                        end if;
                        iphase <= PH_BIT_SCL_HI;

                    when PH_BIT_SCL_HI =>
                        scl_hw <= '1';
                        if i2c_reading = '1' then
                            i2c_rd_byte <= i2c_rd_byte(0) & sda_in;
                        end if;
                        iphase <= PH_BIT_SCL_LO;

                    when PH_BIT_SCL_LO =>
                        scl_hw <= '0';
                        if i2c_bit_cnt = 0 then
                            i2c_bit_cnt <= 7;
                            iphase <= PH_ACK_SDA;
                        else
                            i2c_bit_cnt <= i2c_bit_cnt - 1;
                            i2c_shift <= i2c_shift(6 downto 0) & '0';
                            iphase <= PH_BIT_SDA;
                        end if;

                    when PH_ACK_SDA =>
                        scl_hw <= '0';
                        if i2c_reading = '1' then
                            sda_hw_oe <= '1'; sda_hw <= '1'; -- NACK
                        else
                            sda_hw_oe <= '0'; -- Release SDA for slave ACK
                        end if;
                        iphase <= PH_ACK_SCL_HI;

                    when PH_ACK_SCL_HI =>
                        scl_hw <= '1';
                        iphase <= PH_ACK_SCL_LO;

                    when PH_ACK_SCL_LO =>
                        scl_hw <= '0';
                        sda_hw_oe <= '0';
                        i2c_reading <= '0';
                        iphase <= PH_DONE;

                    when PH_STOP_SDA_LO =>
                        scl_hw <= '0';
                        sda_hw_oe <= '1'; sda_hw <= '0';
                        iphase <= PH_STOP_SCL_HI;
                    when PH_STOP_SCL_HI =>
                        scl_hw <= '1';
                        iphase <= PH_STOP_SDA_HI;
                    when PH_STOP_SDA_HI =>
                        sda_hw_oe <= '0';
                        iphase <= PH_DONE;

                    when PH_DONE =>
                        iphase <= PH_IDLE;

                end case;

                ---------------------------------------------------------
                -- Boot FSM (24LC32: 2-byte address)
                ---------------------------------------------------------
                if iphase = PH_IDLE or iphase = PH_DONE then
                    case bstate is

                        when B_INIT =>
                            if i2c_reset = '1' then
                                bstate <= B_START;
                            end if;

                        when B_WAIT =>
                            if iphase = PH_IDLE then
                                bstate <= B_WAIT;
                            end if;

                        when B_START =>
                            iphase <= PH_START_SDA;
                            bstate <= B_DEV_W;

                        when B_DEV_W =>
                            if iphase = PH_IDLE then
                                i2c_shift <= EEPROM_WR;
                                i2c_reading <= '0';
                                i2c_bit_cnt <= 7;
                                iphase <= PH_BIT_SDA;
                                bstate <= B_ADDR_H; -- dla c32
									--	  bstate <= B_ADDR_L;   -- dla c02
                            end if;

                        when B_ADDR_H =>
                            if iphase = PH_IDLE then
                                i2c_shift <= x"00";
                                i2c_reading <= '0';
                                i2c_bit_cnt <= 7;
                                iphase <= PH_BIT_SDA;
                                bstate <= B_ADDR_L;
                            end if;
                        when B_ADDR_L =>
                            if iphase = PH_IDLE then
                                i2c_shift <= x"00";
                                i2c_reading <= '0';
                                i2c_bit_cnt <= 7;
                                iphase <= PH_BIT_SDA;
                                bstate <= B_RESTART;
                            end if;									 

                        when B_RESTART =>
                            if iphase = PH_IDLE then
                                sda_hw_oe <= '0';
                                scl_hw <= '1';
                                iphase <= PH_START_SDA;
                                bstate <= B_DEV_R;
                            end if;

                        when B_DEV_R =>
                            if iphase = PH_IDLE then
                                i2c_shift <= EEPROM_RD;
                                i2c_reading <= '0';
                                i2c_bit_cnt <= 7;
                                iphase <= PH_BIT_SDA;
                                bstate <= B_READ_DATA;
                            end if;

                        when B_READ_DATA =>
                            if iphase = PH_IDLE then
                                i2c_reading <= '1';
                                i2c_bit_cnt <= 7;
                                iphase <= PH_BIT_SDA;
                                bstate <= B_NACK;
                            end if;

                        when B_NACK =>
                            if iphase = PH_IDLE then
                                bstate <= B_STOP;
                            end if;

                        when B_STOP =>
                            iphase <= PH_STOP_SDA_LO;
                            if i2c_rd_byte = PLL_X8 or
                               i2c_rd_byte = PLL_X10 or
                               i2c_rd_byte = PLL_X12 then
                                pll_reg <= i2c_rd_byte;
                                pll_saved <= '1';
                            else
                                pll_reg <= PLL_DEF;
                                pll_saved <= '0';
                            end if;
                            bstate <= B_APPLY;

                        when B_APPLY =>
                            -- USUNIÊTY case pll_reg z sel0_val/sel1_val
                            -- SEL piny kombinacyjne wy¿ej, apply = ustawienie cfg_done
                            if iphase = PH_IDLE then
                                cfg_done <= '1';
                                boot_active <= '0';
                                bstate <= B_IDLE;
                            end if;

                        when B_IDLE =>
                            null;

                    end case;
                end if;

            end if;  -- tick
        end if;
    end process;

end architecture rtl;