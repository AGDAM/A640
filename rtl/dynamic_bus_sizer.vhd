----------------------------------------------------------------------------------
-- Module      : dynamic_bus_sizer
--
-- Function    : Dynamic bus sizing bridge between a 32-bit 68040 data bus (D32)
--               and a 16-bit host data bus (D16, 68000 side).
--
--               A 32-bit CPU access is split into successive 16-bit transfers on
--               the host side. LANE_SEL encodes which byte/word phase is active:
--
--                 "000" -> byte 0  (D32[31:24])
--                 "001" -> byte 1  (D32[23:16])
--                 "010" -> byte 2  (D32[15: 8])
--                 "011" -> byte 3  (D32[ 7: 0])
--                 "100" -> word 0  (D32[31:16])
--                 "101" -> word 1  (D32[15: 0])
--
--               CPU_RD = '1' : CPU read  -> host data (D16) is latched into D32
--               CPU_RD = '0' : CPU write -> CPU data (D32) is routed onto D16
--
-- Notes       : Ported from the original 'bus_sizing' entity. German comments
--               removed, signals renamed after their role, unused CLK_BS port and
--               LONG signal removed, output-enable logic factored, redundant
--               direction guards dropped from the write mux (harmless, since the
--               write driver is already gated by drive_d16).
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity dynamic_bus_sizer is
    Port ( CPU_RD   : in    STD_LOGIC;                     -- '1' read, '0' write
           LANE_SEL : in    STD_LOGIC_VECTOR (2 downto 0); -- active byte/word phase
           LATCH_EN : in    STD_LOGIC;                     -- latch host read data
           OUT_EN   : in    STD_LOGIC;                     -- enable active bus driver
           RESET_N  : in    STD_LOGIC;                     -- active-low reset
           D16      : inout STD_LOGIC_VECTOR (15 downto 0);-- 16-bit host bus
           D32      : inout STD_LOGIC_VECTOR (31 downto 0));-- 32-bit 68040 bus
end dynamic_bus_sizer;

architecture rtl of dynamic_bus_sizer is

    -- One-hot decode of the current transfer phase
    signal byte_sel : STD_LOGIC_VECTOR (3 downto 0);
    signal word_sel : STD_LOGIC_VECTOR (1 downto 0);

    -- Write path: bytes driven onto the 16-bit host bus (D32 -> D16)
    signal d16_wr_hi : STD_LOGIC_VECTOR (7 downto 0);  -- -> D16[15:8]
    signal d16_wr_lo : STD_LOGIC_VECTOR (7 downto 0);  -- -> D16[ 7:0]

    -- Read path: latched bytes assembled for the 32-bit CPU bus (D16 -> D32)
    signal d32_lat_b0 : STD_LOGIC_VECTOR (7 downto 0); -- -> D32[31:24]
    signal d32_lat_b1 : STD_LOGIC_VECTOR (7 downto 0); -- -> D32[23:16]
    signal d32_lat_b2 : STD_LOGIC_VECTOR (7 downto 0); -- -> D32[15: 8]
    signal d32_lat_b3 : STD_LOGIC_VECTOR (7 downto 0); -- -> D32[ 7: 0]

    -- Bus driver enables
    signal drive_d32    : STD_LOGIC;                   -- read : drive CPU bus
    signal drive_d16    : STD_LOGIC;                   -- write: drive host bus
    signal rd_latch_clk : STD_LOGIC;                   -- read-data latch strobe

begin

    ------------------------------------------------------------------------------
    -- Phase decode
    ------------------------------------------------------------------------------
    byte_sel(0) <= '1' when LANE_SEL = "000" else '0';
    byte_sel(1) <= '1' when LANE_SEL = "001" else '0';
    byte_sel(2) <= '1' when LANE_SEL = "010" else '0';
    byte_sel(3) <= '1' when LANE_SEL = "011" else '0';
    word_sel(0) <= '1' when LANE_SEL = "100" else '0';
    word_sel(1) <= '1' when LANE_SEL = "101" else '0';

    ------------------------------------------------------------------------------
    -- Driver enables
    ------------------------------------------------------------------------------
    drive_d32 <= '1' when CPU_RD = '1' and OUT_EN = '1' and RESET_N = '1' else '0';
    drive_d16 <= '1' when CPU_RD = '0' and OUT_EN = '1' and RESET_N = '1' else '0';

    ------------------------------------------------------------------------------
    -- CPU read : drive the 32-bit bus from the read latch
    ------------------------------------------------------------------------------
    D32(31 downto 24) <= d32_lat_b0 when drive_d32 = '1' else (others => 'Z');
    D32(23 downto 16) <= d32_lat_b1 when drive_d32 = '1' else (others => 'Z');
    D32(15 downto  8) <= d32_lat_b2 when drive_d32 = '1' else (others => 'Z');
    D32( 7 downto  0) <= d32_lat_b3 when drive_d32 = '1' else (others => 'Z');

    ------------------------------------------------------------------------------
    -- CPU write : drive the 16-bit host bus from the write mux
    ------------------------------------------------------------------------------
    D16(15 downto 8) <= d16_wr_hi when drive_d16 = '1' else (others => 'Z');
    D16( 7 downto 0) <= d16_wr_lo when drive_d16 = '1' else (others => 'Z');

    -- Route the addressed CPU byte(s) onto the host bus.
    -- Values only matter while drive_d16 is active, so no direction guard needed.
    d16_wr_hi <= D32(31 downto 24) when byte_sel(0) = '1' else
                 D32(23 downto 16) when byte_sel(1) = '1' else
                 D32(15 downto  8) when byte_sel(2) = '1' else
                 D32( 7 downto  0) when byte_sel(3) = '1' else
                 (others => '0');

    d16_wr_lo <= D32(23 downto 16) when (byte_sel(0) = '1' or byte_sel(1) = '1') else
                 D32( 7 downto  0) when (byte_sel(2) = '1' or byte_sel(3) = '1') else
                 (others => '0');

    ------------------------------------------------------------------------------
    -- CPU read : latch host data into the 32-bit register (byte-lane replicated)
    ------------------------------------------------------------------------------
    rd_latch_clk <= '1' when LATCH_EN = '1' and CPU_RD = '1' else '0';

    rd_latch : process (rd_latch_clk, RESET_N)
    begin
        if RESET_N = '0' then
            d32_lat_b0 <= (others => '0');
            d32_lat_b1 <= (others => '0');
            d32_lat_b2 <= (others => '0');
            d32_lat_b3 <= (others => '0');
        elsif rising_edge(rd_latch_clk) then
            -- byte 0 -> D32[31:24]
            if (byte_sel(0) = '1' or word_sel(0) = '1') then
                d32_lat_b0 <= D16(15 downto 8);
            end if;
            -- byte 1 -> D32[23:16]
            if word_sel(0) = '1' then
                d32_lat_b1 <= D16(7 downto 0);
            elsif (byte_sel(0) = '1' or byte_sel(1) = '1') then
                d32_lat_b1 <= D16(15 downto 8);
            end if;
            -- byte 2 -> D32[15:8]
            if (byte_sel(0) = '1' or byte_sel(1) = '1' or byte_sel(2) = '1' or
                word_sel(0) = '1' or word_sel(1) = '1') then
                d32_lat_b2 <= D16(15 downto 8);
            end if;
            -- byte 3 -> D32[7:0]
            if (byte_sel(0) = '1' or byte_sel(1) = '1' or
                byte_sel(2) = '1' or byte_sel(3) = '1') then
                d32_lat_b3 <= D16(15 downto 8);
            elsif (word_sel(0) = '1' or word_sel(1) = '1') then
                d32_lat_b3 <= D16(7 downto 0);
            end if;
        end if;
    end process rd_latch;

end rtl; 