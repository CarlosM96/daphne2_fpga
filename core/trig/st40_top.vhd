-- st40_top.vhd
-- DAPHNE core logic, top level, self triggered mode sender
-- all 40 AFE channels -> one output link to DAQ
-- 
-- Jamieson Olsen <jamieson@fnal.gov>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

use work.daphne2_package.all;

entity st40_top is
generic( link_id: std_logic_vector(5 downto 0)  := "000000" ); -- this is the OUTPUT link ID that goes into the header
port(
    reset: in std_logic;

    threshold: in std_logic_vector(13 downto 0); -- user defined threshold relative to avg baseline
    ti_trigger: in std_logic_vector(7 downto 0); -------------------------
    ti_trigger_stbr: in std_logic;  -------------------------
    slot_id: in std_logic_vector(3 downto 0);
    crate_id: in std_logic_vector(9 downto 0);
    detector_id: in std_logic_vector(5 downto 0);
    version_id: in std_logic_vector(5 downto 0);
    enable: in std_logic_vector(39 downto 0);

    aclk: in std_logic; -- AFE clock 62.500 MHz
    timestamp: in std_logic_vector(63 downto 0);
	afe_dat: in array_5x9x14_type; -- ALL AFE channels feed into this module

    fclk: in std_logic; -- transmit clock to FELIX 120.237 MHz 
    dout: out std_logic_vector(31 downto 0);
    kout: out std_logic_vector(3 downto 0)
);
end st40_top;

architecture st40_top_arch of st40_top is
 
    type state_type is (rst, scan, dump, idle);
    signal state: state_type;

    signal sela: integer range 0 to 4;
    signal selc: integer range 0 to 7;
    signal fifo_ae: array_5x8_type;
    signal fifo_rden: array_5x8_type;
    signal fifo_ready: std_logic;
    signal fifo_do: array_5x8x32_type;
    signal fifo_ko: array_5x8x4_type;
    signal d, dout_reg: std_logic_vector(31 downto 0);
    signal k, kout_reg: std_logic_vector( 3 downto 0);

    component stc is
    generic( link_id: std_logic_vector(5 downto 0) := "000000"; ch_id: std_logic_vector(5 downto 0) := "000000" );
    port(
        reset: in std_logic;

        threshold: std_logic_vector(13 downto 0);
        slot_id: std_logic_vector(3 downto 0);
        crate_id: std_logic_vector(9 downto 0);
        detector_id: std_logic_vector(5 downto 0);
        version_id: std_logic_vector(5 downto 0);
        enable: std_logic;

        aclk: in std_logic; -- AFE clock 62.500 MHz
        timestamp: in std_logic_vector(63 downto 0);
        ti_trigger: in std_logic_vector(7 downto 0); -------------------------
        ti_trigger_stbr: in std_logic;  -------------------------
    	afe_dat: in std_logic_vector(13 downto 0);
        fclk: in std_logic; -- transmit clock to FELIX 120.237 MHz 
        fifo_rden: in std_logic;
        fifo_ae: out std_logic;
        fifo_do: out std_logic_vector(31 downto 0);
        fifo_ko: out std_logic_vector( 3 downto 0)
      );
    end component;

begin

    -- make 40 STC machines to monitor 40 AFE channels

    gen_stc_a: for a in 4 downto 0 generate
        gen_stc_c: for c in 7 downto 0 generate

            stc_inst: stc 
            generic map( link_id => link_id, ch_id => std_logic_vector(to_unsigned(5*a+c,6)) ) 
            port map(
                reset => reset,
    
                threshold => threshold,
                ti_trigger => ti_trigger,
                ti_trigger_stbr => ti_trigger_stbr,
                slot_id => slot_id,
                crate_id => crate_id,
                detector_id => detector_id,
                version_id => version_id,
                enable => enable(5*a+c),
    
                aclk => aclk,
                timestamp => timestamp,
            	afe_dat => afe_dat(a)(c),
                fclk => fclk,
                fifo_rden => fifo_rden(a)(c),
                fifo_ae => fifo_ae(a)(c),
                fifo_do => fifo_do(a)(c),
                fifo_ko => fifo_ko(a)(c)
              );

    end generate gen_stc_c;
    end generate gen_stc_a;

    -- fifo read enable and fifo flag selection

--    fifo_ready <= '1' when (sel_reg="000000" and fifo_ae(0)='1') else 
--                  '1' when (sel_reg="000001" and fifo_ae(1)='1') else 
--                  '1' when (sel_reg="000010" and fifo_ae(2)='1') else 
--                  '1' when (sel_reg="000011" and fifo_ae(3)='1') else 
--                  '1' when (sel_reg="000100" and fifo_ae(4)='1') else 
--                  '1' when (sel_reg="000101" and fifo_ae(5)='1') else 
--                  '1' when (sel_reg="000110" and fifo_ae(6)='1') else 
--                  '1' when (sel_reg="000111" and fifo_ae(7)='1') else 
--                  '1' when (sel_reg="001000" and fifo_ae(8)='1') else 
--                  '1' when (sel_reg="001001" and fifo_ae(9)='1') else 
--                  '0';

    -- sel_reg is a straight 6 bit register, but it is encoded with values 0-7, 10-17, 20-27, 30-37, 40-47
    -- there are gaps, so be careful when incrementing and looping...

    fifo_ready_proc: process(sela, selc, fifo_ae)
    begin
        fifo_ready <= '0'; -- default
        loop_a: for a in 4 downto 0 loop
            loop_c: for c in 7 downto 0 loop
                if (sela=a and selc=c and fifo_ae(a)(c)='1') then
                    fifo_ready <= '1';
                end if;
            end loop loop_c;
        end loop loop_a;
    end process fifo_ready_proc;

    gen_rden_a: for a in 4 downto 0 generate
        gen_rden_c: for c in 7 downto 0 generate
            fifo_rden(a)(c) <= '1' when (sela=a and selc=c and state=dump) else '0';
        end generate gen_rden_c;
    end generate gen_rden_a;

    -- FSM scans all STC machines in round robin manner, looking for a FIFO almost empty "fifo_ae" flag set. when it finds
    -- this, it reads one complete frame from that machine, then sends a few idles, then returns to scanning again.

    fsm_proc: process(fclk)
    begin
        if rising_edge(fclk) then
            if (reset='1') then
                state <= rst;
            else
                case(state) is

                    when rst =>
                        sela <= 0;
                        selc <= 0;
                        state <= scan;

                    when scan => 
                        if (fifo_ready='1') then
                            state <= dump;
                        else
                            if (selc=7) then
                                if (sela=4) then -- loop around when sel = 4 7
                                    sela <= 0;
                                    selc <= 0;
                                else
                                    sela <= sela + 1;
                                    selc <= 0;
                                end if;
                            else
                                selc <= selc + 1;
                            end if;
                            state <= scan;
                        end if;

                    when dump =>
                        if (k="0001" and d(7 downto 0)=X"DC") then -- this the EOF word, done reading from this STC
                            state <= idle;
                        else
                            state <= dump;
                        end if;

                    when idle => -- send one idle word and resume scanning...
                        if (selc = 7) then
                            if (sela = 4) then -- loop around when sel = 4 7
                                sela <= 0;
                                selc <= 0;
                            else
                                sela <= sela + 1;
                                selc <= 0;
                            end if;
                        else
                            selc <= selc + 1;
                        end if;
                        state <= scan;

                    when others => 
                        state <= rst;
                end case;
            end if;
        end if;
    end process fsm_proc;

    -- output muxes
     
--    d <= fifo_do(0) when (sel_reg="000000" and state=dump) else
--         fifo_do(1) when (sel_reg="000001" and state=dump) else
--         fifo_do(2) when (sel_reg="000010" and state=dump) else
--         fifo_do(3) when (sel_reg="000011" and state=dump) else
--         fifo_do(4) when (sel_reg="000100" and state=dump) else
--         fifo_do(5) when (sel_reg="000101" and state=dump) else
--         fifo_do(6) when (sel_reg="000110" and state=dump) else
--         fifo_do(7) when (sel_reg="000111" and state=dump) else
--         fifo_do(8) when (sel_reg="001000" and state=dump) else
--         fifo_do(9) when (sel_reg="001001" and state=dump) else
--         X"000000BC"; -- idle word
--
--    k <= fifo_ko(0) when (sel_reg="000000" and state=dump) else
--         fifo_ko(1) when (sel_reg="000001" and state=dump) else
--         fifo_ko(2) when (sel_reg="000010" and state=dump) else
--         fifo_ko(3) when (sel_reg="000011" and state=dump) else
--         fifo_ko(4) when (sel_reg="000100" and state=dump) else
--         fifo_ko(5) when (sel_reg="000101" and state=dump) else
--         fifo_ko(6) when (sel_reg="000110" and state=dump) else
--         fifo_ko(7) when (sel_reg="000111" and state=dump) else
--         fifo_ko(8) when (sel_reg="001000" and state=dump) else
--         fifo_ko(9) when (sel_reg="001001" and state=dump) else
--         "0001"; -- idle word

    outmux_proc: process(fifo_do, fifo_ko, sela, selc, state)
    begin
        d <= X"000000BC"; -- default
        k <= "0001"; -- default
        loop_a: for a in 4 downto 0 loop
        loop_c: for c in 7 downto 0 loop
            if ( sela=a and selc=c and state=dump ) then
                d <= fifo_do(a)(c);
                k <= fifo_ko(a)(c);
            end if;
        end loop loop_c;
        end loop loop_a;
    end process outmux_proc;

    -- register the outputs

    outreg_proc: process(fclk)
    begin
        if rising_edge(fclk) then
            dout_reg <= d;
            kout_reg <= k;
        end if;
    end process outreg_proc;

    dout <= dout_reg;
    kout <= kout_reg;

end st40_top_arch;
