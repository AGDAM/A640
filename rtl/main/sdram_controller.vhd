LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;

-- =====================================================================
-- MODU£ KONTROLERA SDRAM - ORYGINALNY (DZIA£AJ¥CY)
-- =====================================================================
ENTITY SDRAM_CONTROLLER IS
    GENERIC (
        REFRESH_CYCLES : INTEGER := 2;
        REFRESH_PERIOD : INTEGER := 56
    );
    PORT (  
        -- Zegary i reset
        CLK_SDRAM  : IN  STD_LOGIC;  -- CLK100M
        CLK7M      : IN  STD_LOGIC;
        CLK_RAM    : IN  STD_LOGIC;  -- BCLK_BAR
        RESET      : IN  STD_LOGIC;
        BERR       : IN  STD_LOGIC;
        
        -- Sygna³y interfejsu 68040
        A40        : IN  STD_LOGIC_VECTOR(31 DOWNTO 0);
        SIZ40      : IN  STD_LOGIC_VECTOR(1 DOWNTO 0);
        RW40       : IN  STD_LOGIC;
        TS40       : IN  STD_LOGIC;
        TT40       : IN  STD_LOGIC_VECTOR(1 DOWNTO 0);
        TM40       : IN  STD_LOGIC_VECTOR(2 DOWNTO 0);
        
        -- Sygna³y wyjœciowe do 68040
        TA40_OUT   : OUT STD_LOGIC;
        TBI40      : OUT STD_LOGIC;
        TCI40      : OUT STD_LOGIC;
        
        -- Sygna³y SDRAM
        SDR_CLK    : OUT STD_LOGIC;
        BA         : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
        RAS        : OUT STD_LOGIC;
        CAS        : OUT STD_LOGIC;
        WE         : OUT STD_LOGIC;
        DQ         : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
        ARAM       : OUT STD_LOGIC_VECTOR(12 DOWNTO 0);
        CEN        : OUT STD_LOGIC;
        RAM_OE     : OUT STD_LOGIC;
        RAM_DIR    : OUT STD_LOGIC
    );
END SDRAM_CONTROLLER;

ARCHITECTURE Behavioral OF SDRAM_CONTROLLER IS

    -- Definicja typów stanów SDRAM
    TYPE state_type IS (
        POWERUP,
        INIT_PRECHARGE,
        INIT_PRECHARGE_COMMIT,
        INIT_OPCODE,
        INIT_REFRESH,
        INIT_WAIT,
        START_STATE,
        REFRESH_START,
        REFRESH_WAIT,
        START_RAS,
        COMMIT_RAS,
        READ_START_CAS,
        READ_COMMIT_CAS,
        READ_DATA_WAIT,
        READ_LINE_BURST,
        WRITE_START_CAS,
        WRITE_COMMIT_CAS,
        WRITE_LINE_BURST,
        PRECHARGE,
        PRECHARGE_WAIT,
        END_CYCLE
    );
    
    -- Stany maszyny stanów
    SIGNAL CQ, CQ_D       : state_type := POWERUP;
    SIGNAL NQ             : UNSIGNED(2 DOWNTO 0) := "000";
      
    -- Sygna³y steruj¹ce SDRAM
    SIGNAL RAS_D          : STD_LOGIC; 
    SIGNAL CAS_D          : STD_LOGIC;
    SIGNAL TA40_D         : STD_LOGIC;
    SIGNAL WE_D           : STD_LOGIC;
    SIGNAL TA40_FB        : STD_LOGIC;
    SIGNAL ARAM_D         : STD_LOGIC_VECTOR(12 DOWNTO 0);      
    SIGNAL ARAM_LOW       : STD_LOGIC_VECTOR(12 DOWNTO 0);      
    SIGNAL ARAM_HIGH      : STD_LOGIC_VECTOR(12 DOWNTO 0);      
    
    -- Sta³e adresowe
    CONSTANT ARAM_PRECHARGE : STD_LOGIC_VECTOR(12 DOWNTO 0) := "0010000000000";
    CONSTANT ARAM_OPTCODE   : STD_LOGIC_VECTOR(12 DOWNTO 0) := "0000000100010"; 
    
    SIGNAL ENACLK_PRE     : STD_LOGIC;
    SIGNAL WAIT_CNT       : UNSIGNED(8 DOWNTO 0) := (OTHERS => '0');
    SIGNAL SDR_INI        : STD_LOGIC := '0';
    SIGNAL REFRESH_COUNT  : INTEGER RANGE 0 TO 255 := 0;
    SIGNAL REFRESH        : STD_LOGIC := '0';
    SIGNAL TRANSFER       : STD_LOGIC := '0';
    SIGNAL BURST          : UNSIGNED(1 DOWNTO 0) := "00";
    SIGNAL RAM_ADDR       : STD_LOGIC := '0';
    SIGNAL CIIN           : STD_LOGIC;
    SIGNAL CACHE_BAR      : STD_LOGIC;
    
    -- Synchronizatory miêdzy domenami zegarowymi
    SIGNAL TS40_sync1, TS40_sync2         : STD_LOGIC := '1';
    SIGNAL RW40_sync1, RW40_sync2         : STD_LOGIC := '1';
    SIGNAL TRANSFER_sync1, TRANSFER_sync2 : STD_LOGIC := '0';

    FUNCTION X(X: IN BOOLEAN) RETURN STD_LOGIC IS
        VARIABLE RET : STD_LOGIC;
    BEGIN
        IF X THEN RET := '1'; ELSE RET := '0'; END IF;
        RETURN RET;
    END X;
	 
    SIGNAL BCLK_sync1, BCLK_sync2, BCLK_sync3 : STD_LOGIC;
    SIGNAL BCLK_falling_edge : STD_LOGIC;

BEGIN

    ----------------------------------------------------------------------------------
    -- Dekodowanie adresu
    ----------------------------------------------------------------------------------
    RAM_ADDR <= '1' WHEN (A40(31 DOWNTO 26) = "010000" AND BERR = '1') ELSE '0';
    
    ----------------------------------------------------------------------------------
    -- Sygna³y kontrolne
    ----------------------------------------------------------------------------------
    TCI40 <= '1' WHEN ((TT40(1) = '0' AND (TM40 = "010" OR TM40 = "110")) OR CIIN = '1') ELSE '0';
    TBI40 <= '0' WHEN (RESET = '1' AND ((TT40(1) = '0' AND RAM_ADDR = '0') OR TT40(1) = '1')) ELSE '1';
    
    TA40_OUT <= TA40_FB WHEN RAM_ADDR = '1' ELSE 'Z';
    
    CEN <= ENACLK_PRE;
    BA <= "00" WHEN RESET = '0' ELSE A40(25 DOWNTO 24);
    
    RAM_OE <= NOT RAM_ADDR AND NOT TRANSFER;
    RAM_DIR <= NOT RW40 AND RAM_ADDR AND TS40;
    
    ARAM_LOW <= "0000" & A40(10 DOWNTO 2);
    ARAM_HIGH <= A40(23 DOWNTO 11);
    
    SDR_CLK <= NOT CLK_SDRAM;
    
    CACHE_BAR <= NOT RAM_ADDR AND X(
        (A40(23 DOWNTO 20) = X"0") OR
        (A40(23 DOWNTO 20) = X"1") OR
 --       (A40(23 DOWNTO 20) = X"A") OR
        (A40(23 DOWNTO 20) = X"B") OR
        (A40(23 DOWNTO 20) = X"D") OR
        (A40(23 DOWNTO 20) = X"E" AND A40(19) = '1') OR
        (A40(23 DOWNTO 20) = X"F"));

    CIIN <= NOT CACHE_BAR;
    
    ----------------------------------------------------------------------------------
    -- Synchronizatory CDC dla sygna³ów miêdzy domenami zegarowymi
    ----------------------------------------------------------------------------------
    PROCESS(CLK_SDRAM, RESET)
    BEGIN
        IF RESET = '0' THEN
            TS40_sync1 <= '1';
            TS40_sync2 <= '1';
            RW40_sync1 <= '1';
            RW40_sync2 <= '1';
        ELSIF RISING_EDGE(CLK_SDRAM) THEN
            -- Podwójna synchronizacja dla metastabilnoœci
            TS40_sync1 <= TS40;
            TS40_sync2 <= TS40_sync1;
            RW40_sync1 <= RW40;
            RW40_sync2 <= RW40_sync1;
        END IF;
    END PROCESS;
    
    PROCESS(CLK_SDRAM, RESET)
    BEGIN
        IF RESET = '0' THEN
            TRANSFER_sync1 <= '0';
            TRANSFER_sync2 <= '0';
        ELSIF RISING_EDGE(CLK_SDRAM) THEN
            TRANSFER_sync1 <= TRANSFER;
            TRANSFER_sync2 <= TRANSFER_sync1;
        END IF;
    END PROCESS;
    
    ----------------------------------------------------------------------------------
    -- Inicjalizacja SDRAM
    ----------------------------------------------------------------------------------
    PROCESS(CLK7M, RESET)
    BEGIN
        IF RESET = '0' THEN
            WAIT_CNT <= (OTHERS => '0');
            SDR_INI <= '0';
        ELSIF RISING_EDGE(CLK7M) THEN
            IF SDR_INI = '0' THEN
                WAIT_CNT <= WAIT_CNT + 1;
                IF WAIT_CNT = "101100101" THEN  -- ~100us przy 7MHz
                    SDR_INI <= '1';
                END IF;
            END IF;
        END IF;
    END PROCESS;
    
    ----------------------------------------------------------------------------------
    -- Generator refresh (CLK7M domain)
    ----------------------------------------------------------------------------------
    PROCESS(CLK7M, RESET)
    BEGIN
        IF RESET = '0' THEN
            REFRESH_COUNT <= 0;
        ELSIF RISING_EDGE(CLK7M) THEN
            IF REFRESH_COUNT = REFRESH_PERIOD THEN
                REFRESH_COUNT <= 0;
            ELSE
                REFRESH_COUNT <= REFRESH_COUNT + 1;
            END IF;
        END IF;
    END PROCESS;
    
    ----------------------------------------------------------------------------------
    -- Detekcja refresh i transfer (CLK100M domain)
    ----------------------------------------------------------------------------------
    PROCESS(CLK_SDRAM, RESET)
    BEGIN
        IF RESET = '0' THEN
            REFRESH <= '0';
            TRANSFER <= '0';
        ELSIF RISING_EDGE(CLK_SDRAM) THEN
            -- Synchronizacja refresh
            IF REFRESH_COUNT = (REFRESH_PERIOD - 1) THEN
                REFRESH <= '1';
            ELSE
                REFRESH <= '0';
            END IF;
            
            -- Detekcja pocz¹tku transferu
            IF TS40_sync2 = '0' AND TT40(1) = '0' AND RAM_ADDR = '1' THEN
                TRANSFER <= '1';
            ELSIF CQ = COMMIT_RAS OR RESET = '0' THEN
                TRANSFER <= '0';
            END IF;
        END IF;
    END PROCESS;
    
    ----------------------------------------------------------------------------------
    PROCESS(CLK_SDRAM, SDR_INI) IS
    BEGIN
        IF SDR_INI = '0' THEN
            DQ <= "1111";
        ELSIF RISING_EDGE(CLK_SDRAM) THEN
            DQ(0) <= NOT ((A40(1) AND A40(0) AND (NOT SIZ40(1)) AND SIZ40(0)) OR
                          (A40(1) AND SIZ40(1)  AND (NOT SIZ40(0))) OR
                          ((NOT SIZ40(1)) AND (NOT SIZ40(0))) OR
                          (SIZ40(1)  AND SIZ40(0)));
            
            DQ(1) <= NOT ((A40(1) AND (NOT A40(0)) AND (NOT SIZ40(1)) AND SIZ40(0)) OR
                          (A40(1) AND SIZ40(1)  AND (NOT SIZ40(0))) OR
                          ((NOT SIZ40(1)) AND (NOT SIZ40(0))) OR
                          (SIZ40(1)  AND SIZ40(0)));
            
            DQ(2) <= NOT (((NOT A40(1)) AND A40(0) AND (NOT SIZ40(1)) AND SIZ40(0)) OR
                          ((NOT A40(1)) AND SIZ40(1)  AND (NOT SIZ40(0))) OR
                          ((NOT SIZ40(1)) AND (NOT SIZ40(0))) OR
                          (SIZ40(1)  AND SIZ40(0)));
            
            DQ(3) <= NOT (((NOT A40(1)) AND (NOT A40(0)) AND (NOT SIZ40(1)) AND SIZ40(0)) OR
                          ((NOT A40(1)) AND SIZ40(1)  AND (NOT SIZ40(0))) OR
                          ((NOT SIZ40(1)) AND (NOT SIZ40(0))) OR
                          (SIZ40(1)  AND SIZ40(0)));
        END IF;
    END PROCESS;
    
    ----------------------------------------------------------------------------------
    -- Rejestr stanów SDRAM
    ----------------------------------------------------------------------------------
    PROCESS(CLK_SDRAM, RESET)
    BEGIN
        IF RESET = '0' THEN
            WE <= '1';
            CAS <= '1';
            RAS <= '1';
            TA40_FB <= '1';
            ARAM <= (OTHERS => '0');
            CQ <= POWERUP;
            NQ <= "000";
            BURST <= "00";
        ELSIF RISING_EDGE(CLK_SDRAM) THEN
            -- Licznik dla wait states
            IF (CQ = INIT_PRECHARGE_COMMIT OR CQ = INIT_WAIT OR CQ = REFRESH_WAIT) THEN
                NQ <= NQ + 1;
            ELSE
                NQ <= "000";
            END IF;
            
            -- Obs³uga burst
            IF (SIZ40 = "11") THEN
                IF (CQ = COMMIT_RAS) THEN
                    BURST <= "11";
                ELSIF ((CQ = READ_DATA_WAIT OR CQ = WRITE_COMMIT_CAS)) THEN
                    BURST <= BURST - 1;
                END IF;
            ELSE
                BURST <= "00";
            END IF;           
            
            -- Aktualizacja rejestrów
            WE <= WE_D;
            CAS <= CAS_D;
            RAS <= RAS_D;
            TA40_FB <= TA40_D;
            ARAM <= ARAM_D;
            CQ <= CQ_D;
        END IF;
    END PROCESS;
	 
	 
    PROCESS(CLK_SDRAM, RESET)
    BEGIN
        IF RESET = '0' THEN
            BCLK_sync1 <= '0';
            BCLK_sync2 <= '0';
            BCLK_sync3 <= '0';
        ELSIF RISING_EDGE(CLK_SDRAM) THEN
            -- Synchronizacja BCLK
            BCLK_sync1 <= CLK_RAM;
            BCLK_sync2 <= BCLK_sync1;
            BCLK_sync3 <= BCLK_sync2;
        END IF;
    END PROCESS;	 

    BCLK_falling_edge <= NOT BCLK_sync2 AND BCLK_sync3;
    
    ----------------------------------------------------------------------------------
    -- Maszyna stanów SDRAM (logika kombinacyjna)
    ----------------------------------------------------------------------------------
    PROCESS(CQ, REFRESH, TRANSFER, CLK_RAM, NQ, RW40_sync2, 
            ARAM_LOW, ARAM_HIGH, BURST, SDR_INI)
    BEGIN
        -- Domyœlne wartoœci
        WE_D <= '1';
        TA40_D <= '1';
        CAS_D <= '1';
        RAS_D <= '1';
        ENACLK_PRE <= '1';
        ARAM_D <= (OTHERS => '0');
        CQ_D <= CQ;  -- Pozostañ w obecnym stanie
        
        CASE CQ IS
            WHEN POWERUP =>
                IF SDR_INI = '1' THEN
                    CQ_D <= INIT_PRECHARGE;
                END IF;
                
            WHEN INIT_PRECHARGE =>
                WE_D <= '0';
                RAS_D <= '0';
                ARAM_D <= ARAM_PRECHARGE;
                CQ_D <= INIT_PRECHARGE_COMMIT;
                
            WHEN INIT_PRECHARGE_COMMIT =>
                IF (NQ >= "001") THEN
                    CQ_D <= INIT_OPCODE;
                END IF;
                
            WHEN INIT_OPCODE =>
                WE_D <= '0';
                CAS_D <= '0';
                RAS_D <= '0';
                ARAM_D <= ARAM_OPTCODE;
                CQ_D <= INIT_REFRESH;
                
            WHEN INIT_REFRESH =>
                CAS_D <= '0';
                RAS_D <= '0';
                CQ_D <= INIT_WAIT;
                
            WHEN INIT_WAIT =>
                IF (NQ >= REFRESH_CYCLES) THEN
                    CQ_D <= REFRESH_START;
                END IF;
                
            WHEN START_STATE =>
                ARAM_D <= ARAM_HIGH;
                
                IF (REFRESH = '1') THEN
                    CQ_D <= REFRESH_START;
                ELSIF (TRANSFER = '1' AND CLK_RAM = '0') THEN
                    CQ_D <= START_RAS;
                END IF;
                
            WHEN REFRESH_START =>
                CAS_D <= '0';
                RAS_D <= '0';
                CQ_D <= REFRESH_WAIT;
                
            WHEN REFRESH_WAIT =>
                IF (NQ >= REFRESH_CYCLES) THEN
                    CQ_D <= START_STATE;
                END IF;
                
            WHEN START_RAS =>
                ARAM_D <= ARAM_HIGH;
                RAS_D <= '0';
                CQ_D <= COMMIT_RAS;
                
            WHEN COMMIT_RAS =>
                IF (RW40_sync2 = '1') THEN
                    CQ_D <= READ_START_CAS;
                ELSE
                    CQ_D <= WRITE_START_CAS;
                END IF;
                
            WHEN READ_START_CAS =>
                CAS_D <= '0';
                ARAM_D <= ARAM_LOW;
                CQ_D <= READ_COMMIT_CAS;
                
            WHEN READ_COMMIT_CAS =>
                TA40_D <= '0';
                CQ_D <= READ_DATA_WAIT;
                
            WHEN READ_DATA_WAIT =>
                TA40_D <= '0';
                ENACLK_PRE <= '0';
                IF (BURST /= "00") THEN
                    CQ_D <= READ_LINE_BURST;
                ELSE
                    CQ_D <= PRECHARGE;
                END IF;
                
            WHEN READ_LINE_BURST =>
                TA40_D <= '0';
                CQ_D <= READ_DATA_WAIT;
                
            WHEN WRITE_START_CAS =>
                WE_D <= '0';
                TA40_D <= '0';
                CAS_D <= '0';
                ARAM_D <= ARAM_LOW;
                CQ_D <= WRITE_COMMIT_CAS;
                
            WHEN WRITE_COMMIT_CAS =>
                TA40_D <= '0';
                ENACLK_PRE <= '0';
                IF (BURST /= "00") THEN
                    CQ_D <= WRITE_LINE_BURST;
                ELSE
                    CQ_D <= PRECHARGE;
                END IF;
                
            WHEN WRITE_LINE_BURST =>
                TA40_D <= '0';
                IF (BURST /= "00") THEN
                    CQ_D <= WRITE_COMMIT_CAS;
                ELSE
                    CQ_D <= PRECHARGE;
                END IF;
                
            WHEN PRECHARGE =>
                WE_D <= '0';
                RAS_D <= '0';
                ARAM_D <= ARAM_PRECHARGE;
                CQ_D <= PRECHARGE_WAIT;
					 
            WHEN PRECHARGE_WAIT =>
            --    CQ_D <= END_CYCLE;					 
                CQ_D <= START_STATE;
            WHEN END_CYCLE =>
                CQ_D <= START_STATE;
                
        END CASE;
    END PROCESS;

END Behavioral;