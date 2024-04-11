-- DAPHNE2.vhd
-- FPGA Top Level
-- Target: XC7A200T-2FBG676C
-- PCB version: DAPHNE V2A (this adds four general output links, one dedicated GbE link, separate
-- MGT refclocks for DAQ links (120.237MHz) and GbE (125MHz). 
--
-- Firmware features: Automatic AFE data alignment, OEI GbE interface, Spy buffers, 
-- 4 outputs to DAQ, streaming and self trig senders combined, new timing endpoint logic, efuse.
--
-- Jamieson Olsen <jamieson@fnal.gov>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

library unimacro;
use unimacro.vcomponents.all;

use work.daphne2_package.all;

entity DAPHNE2 is
generic(version: std_logic_vector(27 downto 0) := X"1234567"); -- git commit number is passed in from tcl build script
port(

    reset_n: in std_logic; -- active LOW async reset from the microcontroller
    sysclk_p, sysclk_n: in std_logic; -- system clock LVDS 100MHz from local oscillator

    -- AFE interface, LVDS, 5 AFE chips, each AFE has 8 DATA + 1 FCLK outputs

    afe_p, afe_n: array_5x9_type; -- (7..0=DATA, 8=FCLK)
    afe_clk_p, afe_clk_n: out std_logic; -- copy of 62.5MHz master clock sent to AFEs

    -- four high speed links to DAQ, all four channels in quad 213 are used
    -- For FELIX links use TX only, disable RX, line rate = 4.809Gbps, refclk = 120.237 MHz

    daq_refclk_p, daq_refclk_n: in std_logic; -- MGT REFCLK for DAQ, LVDS, quad 213, refclk0

    --daq0_rx_p, daq0_rx_n: in std_logic; -- all DAQ links are TX only, GTP RX disabled!
    daq0_tx_p, daq0_tx_n: out std_logic;
    daq0_sfp_abs: in std_logic; 
    daq0_sfp_los: in std_logic; 
	daq0_sfp_tx_dis: out std_logic; 
    daq0_sfp_scl, daq0_sfp_sda: out std_logic; -- sfp I2C interface (optional)

    --daq1_rx_p, daq1_rx_n: in std_logic;
    daq1_tx_p, daq1_tx_n: out std_logic;
    daq1_sfp_abs: in std_logic; 
    daq1_sfp_los: in std_logic; 
	daq1_sfp_tx_dis: out std_logic; 
    daq1_sfp_scl, daq1_sfp_sda: out std_logic; -- sfp I2C interface (optional)

    --daq2_rx_p, daq2_rx_n: in std_logic;
    daq2_tx_p, daq2_tx_n: out std_logic;
    daq2_sfp_abs: in std_logic; 
    daq2_sfp_los: in std_logic; 
	daq2_sfp_tx_dis: out std_logic; 
    daq2_sfp_scl, daq2_sfp_sda: out std_logic; -- sfp I2C interface (optional)

    --daq3_rx_p, daq3_rx_n: in std_logic;
    daq3_tx_p, daq3_tx_n: out std_logic;
    daq3_sfp_abs: in std_logic; 
    daq3_sfp_los: in std_logic; 
	daq3_sfp_tx_dis: out std_logic; 
    daq3_sfp_scl, daq3_sfp_sda: out std_logic; -- sfp I2C interface (optional)

    -- one MGT used for GbE interface, quad 216, channel 0
    -- NOTE: on schematics this is the 4th channel

    gbe_refclk_p, gbe_refclk_n: in std_logic; -- MGT REFCLK for GbE, LVDS, 125.000 MHz, quad 216, refclk0

    gbe_rx_p, gbe_rx_n: in std_logic;
    gbe_tx_p, gbe_tx_n: out std_logic;
    gbe_sfp_abs: in std_logic; -- high if GbE SFP is absent
	gbe_sfp_los: in std_logic; -- high if RX fiber is dark
	gbe_sfp_tx_dis: out std_logic; -- high to disable GbE SFP transmitter
    gbe_sfp_scl, gbe_sfp_sda: out std_logic; -- sfp I2C interface (optional)

    -- Timing Endpoint Interface (SFP)

    cdr_sfp_los: in std_logic; -- loss of signal
    cdr_sfp_abs: in std_logic; -- high if module is absent
    cdr_sfp_tx_dis: out std_logic; -- high to disable timing SFP TX
    cdr_sfp_tx_p, cdr_sfp_tx_n: out std_logic; -- send data upstream (optional)

    -- Timing Endpoint Interface (CDR chip)

    --adn2814_clk_p, adn2814_clk_n: in std_logic; -- LVDS recovered clock 312MHz (not used anymore)
    adn2814_data_p, adn2814_data_n: in std_logic; -- LVDS recovered serial data (actually the clock)
    adn2814_los: in std_logic; -- loss of signal
    adn2814_lol: in std_logic; -- loss of lock

    -- SPI slave interface for communication with uC

    spi_clk: in std_logic;
    spi_csn: in std_logic;
    spi_mosi: in std_logic;
    spi_miso: out std_logic;
    spi_irq: out std_logic;

    -- misc board I/O

    trig_ext: in std_logic; -- from external trigger input, note INVERTED 
    led: out std_logic_vector(5 downto 0) -- DAPHNE PCB LEDs are active LOW

  );
end DAPHNE2;

architecture DAPHNE2_arch of DAPHNE2 is

    component resets
    port(
        oeiclk: in std_logic;
        rx_wren: in std_logic;
        rx_addr: in std_logic_vector(31 downto 0);
        sclk100: in std_logic;
        sclk200: in std_logic;
        mclk: in std_logic;
        reset_fe_mclk: out std_logic;  -- reset the iserdes and fsm in the front end
        reset_fe_sclk200: out std_logic; -- reset the idelay
        reset_ep: out std_logic; -- sync to sclk100
        reset_mmcm1: out std_logic -- ok to sync to sclk100
      );
    end component;

    component endpoint
    port(
        sysclk_p, sysclk_n: in std_logic; -- system clock LVDS 100MHz from local oscillator
        reset_async: in std_logic; -- from the microcontroller
        cdr_sfp_los: in std_logic; -- loss of signal
        --cdr_sfp_abs: in std_logic; -- high if module is absent
        cdr_sfp_tx_dis: out std_logic; -- high to disable timing SFP TX
        cdr_sfp_tx_p, cdr_sfp_tx_n: out std_logic; -- send data upstream (optional)
        --adn2814_clk_p, adn2814_clk_n: in std_logic; -- LVDS recovered clock 312.5MHz
        adn2814_data_p, adn2814_data_n: in std_logic; -- LVDS recovered serial data 
        --adn2814_los: in std_logic; -- loss of signal
        --adn2814_lol: in std_logic; -- loss of lock
        ep_reset: in std_logic; -- soft reset endpoint logic
        --ep_edgesel: in std_logic; -- sample CDR data on rising or falling edge of CDR clock
        --ep_addr: in std_logic_vector(7 downto 0); -- Endpoint address (async, sampled in clk domain)
	    --ep_tgrp: in std_logic_vector(1 downto 0); -- Timing group (async, sampled in clk domain)
        ep_ts_rdy: out std_logic; -- endpoint timestamp is good
        ep_stat: out std_logic_vector(3 downto 0); -- endpoint state bits
        ep_addr: in std_logic_vector(15 downto 0); 
        mmcm1_reset: in std_logic;
        mmcm1_locked: out std_logic;
        mmcm0_locked: out std_logic;
        use_ep: in std_logic; -- 0 = run on local clocks with fake timestamp, 1 = use endpoint clocks and real timestamp
        mclk: out std_logic;  -- master clock 62.5MHz
        fclk: out std_logic;  -- fast clock for frontend
        sclk200: out std_logic; -- system clock 200MHz
        sclk100: out std_logic; -- system clock 100MHz
        timestamp: out std_logic_vector(63 downto 0); -- sync to mclk
        sync: out std_logic_vector(7 downto 0); ---- WARNING
        sync_stb: out std_logic -- WARNING
    );
    end component;

	component gig_ethernet_pcs_pma_0
      port(
		gtrefclk_p           : in std_logic;                     -- Very high quality clock for GT transceiver
		gtrefclk_n           : in std_logic;                    
		gtrefclk_out         : out std_logic;                  
		gtrefclk_bufg_out    : out std_logic;                           
      
		txp                  : out std_logic;                    -- Differential +ve of serial transmission from PMA to PMD.
		txn                  : out std_logic;                    -- Differential -ve of serial transmission from PMA to PMD.
		rxp                  : in std_logic;                     -- Differential +ve for serial reception from PMD to PMA.
		rxn                  : in std_logic;                     -- Differential -ve for serial reception from PMD to PMA.

		mmcm_locked_out      : out std_logic;                     -- Locked signal from MMCM
		userclk_out          : out std_logic;                  
		userclk2_out         : out std_logic;                 
		rxuserclk_out          : out std_logic;               
		rxuserclk2_out         : out std_logic;               
		independent_clock_bufg : in std_logic;                
		pma_reset_out         : out std_logic;                     -- transceiver PMA reset signal
		resetdone             :out std_logic;

		gmii_txd             : in std_logic_vector(7 downto 0);  -- Transmit data from client MAC.
		gmii_tx_en           : in std_logic;                     -- Transmit control signal from client MAC.
		gmii_tx_er           : in std_logic;                     -- Transmit control signal from client MAC.
		gmii_rxd             : out std_logic_vector(7 downto 0); -- Received Data to client MAC.
		gmii_rx_dv           : out std_logic;                    -- Received control signal to client MAC.
		gmii_rx_er           : out std_logic;                    -- Received control signal to client MAC.
		gmii_isolate         : out std_logic;                    -- Tristate control to electrically isolate GMII.
	
		configuration_vector : in std_logic_vector(4 downto 0);  -- Alternative to MDIO interface.
		an_interrupt         : out std_logic;                    -- Interrupt to processor to signal that Auto-Negotiation has completed
		an_adv_config_vector : in std_logic_vector(15 downto 0); -- Alternate interface to program REG4 (AN ADV)
		an_restart_config    : in std_logic;                     -- Alternate signal to modify AN restart bit in REG0

		status_vector        : out std_logic_vector(15 downto 0); -- Core status.
		reset                : in std_logic;                      -- Asynchronous reset for entire core.
		signal_detect        : in std_logic;                      -- Input from PMD to indicate presence of optical input.
		gt0_pll0outclk_out     : out std_logic;
		gt0_pll0outrefclk_out  : out std_logic;
		gt0_pll1outclk_out     : out std_logic;
		gt0_pll1outrefclk_out  : out std_logic;
		gt0_pll0refclklost_out : out std_logic;
		gt0_pll0lock_out       : out std_logic
    );
	end component;

    component ethernet_interface -- Ryan's OEI core logic
    port(
        reset_in:       in  std_logic;
        tx_data:        in  std_logic_vector(63 downto 0);
        ready:          in  std_logic;
        b_data:         in  std_logic_vector(63 downto 0);
        b_data_we:      in  std_logic;
        b_force_packet: in  std_logic;
        reset_out:      out std_logic;
        rx_addr:        out std_logic_vector(31 downto 0);
        rx_data:        out std_logic_vector(63 downto 0);
        rx_wren:        out std_logic;
        tx_rden:        out std_logic;
        b_enable:       out std_logic;
        user_addr:          in  std_logic_vector( 7 downto 0);
        internal_block_sel: in  std_logic_vector(31 downto 0);
        internal_addr:      in  std_logic_vector(31 downto 0);
        internal_din:       in  std_logic_vector(63 downto 0);
        internal_we:        in  std_logic;
        internal_dout:      out std_logic_vector(63 downto 0);
        phy_rxd:    in  std_logic_vector(7 downto 0);
        phy_rx_dv:  in  std_logic;
        phy_rx_er:  in  std_logic;
        master_clk: in  std_logic;
        phy_txd:    out std_logic_vector(7 downto 0);
        phy_tx_en:  out std_logic;
        phy_tx_er:  out std_logic;
        tx_clk:     out std_logic
    );
    end component;

    component front_end
    port(
        afe_p: in array_5x9_type;
        afe_n: in array_5x9_type;
        afe_clk_p:  out std_logic; -- copy of 62.5MHz master clock sent to AFEs
        afe_clk_n:  out std_logic;
        clock:   in  std_logic; -- master clock 62.5MHz
        clock7x: in  std_logic; -- 7 x master clock = 437.5MHz
        sclk200: in  std_logic; -- 200MHz system clock, constant
        reset_clock: in  std_logic;
        reset_sclk200: in  std_logic;
        done:    out std_logic_vector(4 downto 0); -- status of automatic alignment FSM
        warn:    out std_logic_vector(4 downto 0); -- warn of bit errors on the "FCLK" sync pattern
        errcnt:  out array_5x8_type;
        dout:    out array_5x9x14_type -- data synchronized to clock
      );
    end component;

    component spy
    port(
        clka:  in std_logic;  
        reset: in std_logic; -- reset sync to clka
        trig:  in std_logic; -- trigger pulse sync to clka
        dia:   in std_logic_vector(15 downto 0); -- data bus from AFE channel    
        clkb:  in  std_logic;
        addrb: in  std_logic_vector(11 downto 0);
        dob:   out std_logic_vector(15 downto 0)
      );
    end component;

    component spi -- SPI slave used for comms with uC
    port(
        oeiclk: in std_logic;
        cmd_wren: in std_logic;
        cmd_data: in std_logic_vector(7 downto 0);
        res_rden: in std_logic;
        res_data: out std_logic_vector(7 downto 0);
    
        clock: in std_logic;
        reset: in std_logic;
    
        spi_clk:  in std_logic;
        spi_csn:  in std_logic;
        spi_mosi: in std_logic; 
        spi_miso: out std_logic;
        spi_irq:  out std_logic 
    );
    end component;

    component core
    port(
        mclk: in std_logic; -- master clock 62.5MHz
        sclk100: in std_logic; -- system clock 100MHz
        reset: in std_logic; -- for sender logic and for GTP quad
        afe_dat: in array_5x9x14_type;  -- AFE data synchronized to clock
        timestamp: in std_logic_vector(63 downto 0);
        slot_id: in std_logic_vector(3 downto 0);
        crate_id: in std_logic_vector(9 downto 0);
        detector_id: in std_logic_vector(5 downto 0);
        version_id: in std_logic_vector(5 downto 0);
        st_enable: in std_logic_vector(39 downto 0); -- enable/disable channels for self-triggered sender only
        outmode: in std_logic_vector(7 downto 0); -- choose streaming or self-trig sender for each output
        threshold: in std_logic_vector(13 downto 0); -- for self-trig senders, threshold relative to average baseline
	-- 
	    ti_trigger: in std_logic_vector(7 downto 0); -- WARNING
        ti_trigger_stbr: in std_logic; -- WARNING
	--

        oeiclk: in std_logic; -- interface used to read output spy buffer and to r/w input mux control regs
        trig: in std_logic;
        addr: in std_logic_vector(11 downto 0);
        din: in std_logic_vector(5 downto 0);
        spy_dout: out std_logic_vector(31 downto 0);
        inmux_we: in std_logic;
        inmux_dout: out std_logic_vector(5 downto 0);

        daq_refclk_p, daq_refclk_n: in std_logic; -- MGT REFCLK for DAQ, LVDS, quad 213, refclk0, 120.237MHz
        daq0_tx_p, daq0_tx_n: out std_logic;
        daq1_tx_p, daq1_tx_n: out std_logic;
        daq2_tx_p, daq2_tx_n: out std_logic;
        daq3_tx_p, daq3_tx_n: out std_logic
    
    );
    end component;
	
	-- declare signals to connect everything up

    signal gbe_refclk_bufg_out, oeiclk, ready: std_logic;
    signal gbe_refclk_p_ibuf, gbe_refclk_n_ibuf: std_logic;

    signal gmii_rxd, gmii_txd: std_logic_vector(7 downto 0);
    signal gmii_tx_en, gmii_tx_er: std_logic;
    signal gmii_rx_dv, gmii_rx_er: std_logic;
    signal status_vector: std_logic_vector(15 downto 0);
    signal EFUSEUSR: std_logic_vector(31 downto 0);

    signal tx_data, rx_data: std_logic_vector(63 downto 0);
    signal rx_addr, rx_addr_reg: std_logic_vector(31 downto 0);
    signal tx_rden, rx_wren: std_logic;

    signal test_reg: std_logic_vector(63 downto 0);
    signal testreg_we: std_logic;

    signal bram0_we: std_logic_vector(3 downto 0);
    signal bram0_do: std_logic_vector(35 downto 0);

    signal fifo_DO: std_logic_vector(63 downto 0);
    signal dummy_RDCOUNT, dummy_WRCOUNT: std_logic_vector(8 downto 0);
    signal fifo_RDEN, fifo_WREN: std_logic;

    signal count_reg: std_logic_vector(23 downto 0);
    signal edge_reg: std_logic;
    signal led_temp, led1_reg, led0_reg: std_logic_vector(5 downto 0);

    -- DAPHNE specific signals...

	signal reset_async, reset_ep, reset_fe_sclk200, reset_fe_mclk, reset_mmcm1: std_logic;

    signal sclk200, sclk100, mclk, fclk: std_logic;

    signal trig_sync, trig_gbe: std_logic;
    signal trig_gbe0_reg, trig_gbe1_reg, trig_gbe2_reg: std_logic;

    signal afe_dout: array_5x9x14_type;
    signal afe_dout_pad: array_5x9x16_type;
    signal fe_done, fe_warn: std_logic_vector(4 downto 0);
    signal spy_bufr: array_5x9x16_type;
    signal core_spy_data: std_logic_vector(31 downto 0);
    signal timestamp, ts_spy_bufr: std_logic_vector(63 downto 0);
    signal errcnt: array_5x8_type;
    signal sfp_stat_vector: std_logic_vector(63 downto 0);

    signal daq_out_param_reg: std_logic_vector(25 downto 0) := (DEFAULT_DAQ_OUT_SLOT_ID & DEFAULT_DAQ_OUT_CRATE_ID & DEFAULT_DAQ_OUT_DETECTOR_ID & DEFAULT_DAQ_OUT_VERSION_ID);
    signal daq_out_param_we:  std_logic;

    signal mclk_ctrl_reg: std_logic_vector(15 downto 0) := (others=>'0');
    signal mclk_stat_reg: std_logic_vector(12 downto 0);
    signal use_ep, ep_ts_rdy: std_logic;
    signal ep_stat: std_logic_vector(3 downto 0);
    signal ep_addr: std_logic_vector(15 downto 0);
    signal mmcm1_locked, mmcm0_locked: std_logic;
    signal mclk_ctrl_reg_we: std_logic;

    signal spi_cmd_fifo_wren, spi_res_fifo_rden: std_logic;
    signal spi_res_fifo_data: std_logic_vector(7 downto 0);

    signal inmux_we: std_logic;
    signal inmux_dout: std_logic_vector(5 downto 0);

    signal outmode_reg: std_logic_vector(7 downto 0);
    signal outmode_we: std_logic;

    signal threshold_reg : std_logic_vector(13 downto 0);
    signal threshold_we: std_logic;
    --
    signal ti_trigger_reg: std_logic_vector(7 downto 0); ------------------
    signal ti_trigger_stbr_reg: std_logic;  ---------------------------
    signal ti_trigger_en: std_logic;
    signal ti_trigger_en0: std_logic;
    signal ti_trigger_en1: std_logic;
    signal ti_trigger_en2: std_logic;

    signal st_enable_reg: std_logic_vector(39 downto 0);
    signal st_enable_we: std_logic;

begin

    -- Clocks and Resets ----------------------------------------------------

    reset_async <= not reset_n;

    reset_inst: resets -- soft reset logic
    port map(
        oeiclk => oeiclk,
        rx_wren => rx_wren,
        rx_addr => rx_addr,
        sclk100 => sclk100,
        sclk200 => sclk200,
        mclk => mclk,
        reset_fe_mclk => reset_fe_mclk,
        reset_fe_sclk200 => reset_fe_sclk200,
        reset_ep => reset_ep,
        reset_mmcm1 => reset_mmcm1
      );

    -- control and status registers for the endpoint module

    mclk_ctrl_reg_we <= '1' when (std_match(rx_addr,MCLK_CTRL_ADDR) and rx_wren='1') else '0';

    mclk_ctrl_proc: process(oeiclk)
    begin
        if rising_edge(oeiclk) then
            if (mclk_ctrl_reg_we='1') then
                mclk_ctrl_reg <= rx_data(15 downto 0);
            end if;
        end if;
    end process mclk_ctrl_proc;

    mclk_stat_reg <= ep_ts_rdy & ep_stat(3 downto 0) & 
        cdr_sfp_abs & cdr_sfp_los & 
        adn2814_lol & adn2814_los & 
        "00" & mmcm1_locked & mmcm0_locked;

    -- each endpoint in the system needs to have a unique address
    -- set this to 0x000F + EFUSE

    ep_addr <= std_logic_vector( unsigned(EFUSEUSR(15 downto 8)) + to_unsigned(15,16)  );

    -- main clock distribution includes timing endpoint logic
    -- there are two cascaded MMCMs with separate LOCKED status bits

    endpoint_inst: endpoint 
    port map(
        sysclk_p => sysclk_p,
        sysclk_n => sysclk_n,

        reset_async => reset_async,

        cdr_sfp_los => cdr_sfp_los,
        --cdr_sfp_abs => cdr_sfp_abs,
        cdr_sfp_tx_dis => cdr_sfp_tx_dis,
        cdr_sfp_tx_p => cdr_sfp_tx_p, 
        cdr_sfp_tx_n => cdr_sfp_tx_n,

        --adn2814_clk_p => adn2814_clk_p,
        --adn2814_clk_n => adn2814_clk_n,
        adn2814_data_p => adn2814_data_p,
        adn2814_data_n => adn2814_data_n,
        --adn2814_los => adn2814_los,
        --adn2814_lol => adn2814_lol,

        ep_reset => reset_ep,
        --ep_edgesel => mclk_ctrl_reg(1),
        ep_addr => ep_addr,
	    --ep_tgrp => mclk_ctrl_reg(5 downto 4),
        ep_ts_rdy => ep_ts_rdy,
        ep_stat => ep_stat,

        mmcm1_reset => reset_mmcm1,
        mmcm1_locked => mmcm1_locked,
        mmcm0_locked => mmcm0_locked,
        use_ep => mclk_ctrl_reg(0),

        mclk => mclk,
        fclk => fclk,
        sclk200 => sclk200,
        sclk100 => sclk100,

        timestamp => timestamp,

        sync => ti_trigger_reg, -- Sync command output (clk domain)
        sync_stb => ti_trigger_stbr_reg -- Sync command strobe (clk domain)
    );

    -- the trigger pulse can come from the outside world (async) or from a write to a special address (oeiclk domain). 
    -- square this up and edge detect this and move it into the MCLK domain

    trig_gbe <= '1' when (std_match(rx_addr,TRIGGER_ADDR) and rx_wren='1') else '0';
    ti_trigger_en <= '1' when (ti_trigger_reg=x"07" and ti_trigger_stbr_reg='1') else '0';


    trig_oei_proc: process(oeiclk)
    begin
        if rising_edge(oeiclk) then
            trig_gbe0_reg <= trig_gbe;
            trig_gbe1_reg <= trig_gbe0_reg;
            trig_gbe2_reg <= trig_gbe1_reg;
            ti_trigger_en0 <= ti_trigger_en;
            ti_trigger_en1 <= ti_trigger_en0;
            ti_trigger_en2 <= ti_trigger_en1;
        end if;
    end process trig_oei_proc;

    trig_proc: process(mclk) -- note external trigger input is inverted on DAPHNE2
    begin
        if rising_edge(mclk) then
            trig_sync <= (not trig_ext) or trig_gbe0_reg or trig_gbe1_reg or trig_gbe2_reg or ti_trigger_en0 or ti_trigger_en1 or ti_trigger_en2; --------------- WARNING-------------------
        end if;
    end process trig_proc;

    -- Automatic Front End ----------------------------------------------------

    -- 45 channels (40 AFE data channels + 5 frame marker channels)

    fe_inst: front_end 
    port map(
        afe_p => afe_p,
        afe_n => afe_n,
        afe_clk_p => afe_clk_p,
        afe_clk_n => afe_clk_n,
        clock => mclk,
        clock7x => fclk,
        sclk200 => sclk200,
        reset_clock => reset_fe_mclk,
        reset_sclk200 => reset_fe_sclk200,
        done  => fe_done,
        warn => fe_warn,
        errcnt => errcnt,
        dout => afe_dout -- 5x9x14
    );

    -- pad this out to make it 5x9x16
    gen_a: for a in 4 downto 0 generate
        gen_b: for b in 8 downto 0 generate
            afe_dout_pad(a)(b) <= "00" & afe_dout(a)(b);
        end generate gen_b;
    end generate gen_a;

    -- Spy Buffers ------------------------------------------------------------

    -- make 45 spy buffers for AFE data, these buffers are READ ONLY

    gen_spy_afe: for a in 4 downto 0 generate
        gen_spy_bit: for b in 8 downto 0 generate
            spy_inst: spy
            port map(
                -- mclk domain
                clka  => mclk,
                reset => reset_async,
                trig  => trig_sync,
                dia   => afe_dout_pad(a)(b),
                -- oeiclk domain    
                clkb  => oeiclk,
                addrb => rx_addr(11 downto 0),
                dob   => spy_bufr(a)(b));
        end generate gen_spy_bit;
    end generate gen_spy_afe;

    -- make 4 more spy buffers which are used to store the 64-bit timestamp value

    ts_spy_gen: for i in 3 downto 0 generate

        ts_spy_inst: spy
        port map(
            -- mclk domain
            clka  => mclk,
            reset => reset_async,
            trig  => trig_sync,
            dia   => timestamp( ((i*16)+15) downto (i*16) ),

            -- oeiclk domain    
            clkb  => oeiclk,
            addrb => rx_addr(11 downto 0),
            dob   => ts_spy_bufr( ((i*16)+15) downto (i*16) )
          );

    end generate ts_spy_gen;

    -- OEI Gigabit Ethernet ---------------------------------------------------

    -- must manually add IBUFs for refclk inputs
    -- see http://forums.xilinx.com/t5/Implementation/Vivado-IBUFDS-GTE2-driven-by-IBUF/td-p/383187

    gbe_refclk_p_ibuf_inst: IBUF port map ( I => gbe_refclk_p, O => gbe_refclk_p_ibuf );
    gbe_refclk_n_ibuf_inst: IBUF port map ( I => gbe_refclk_n, O => gbe_refclk_n_ibuf );
 
	phy_inst: gig_ethernet_pcs_pma_0 
	port map(
		gtrefclk_p    => gbe_refclk_p_ibuf,
        gtrefclk_n    => gbe_refclk_n_ibuf,
        gtrefclk_out  => open,
        gtrefclk_bufg_out => gbe_refclk_bufg_out, -- constant 125MHz derived from REFCLK
        txp               => gbe_tx_p,
        txn               => gbe_tx_n,
        rxp               => gbe_rx_p,
        rxn               => gbe_rx_n,
        mmcm_locked_out        => open,
        userclk_out            => open, 
        userclk2_out           => oeiclk, -- 125MHz clock to drive OEI logic, does it run constantly?
        rxuserclk_out          => open,
        rxuserclk2_out         => open, 
        independent_clock_bufg => sclk200,   -- 200MHz system clock always running
        pma_reset_out          => open,
        resetdone              => open,
        gmii_txd     => gmii_txd,
        gmii_tx_en   => gmii_tx_en,
        gmii_tx_er   => gmii_tx_er,
        gmii_rxd     => gmii_rxd,
        gmii_rx_dv   => gmii_rx_dv,
        gmii_rx_er   => gmii_rx_er,
        gmii_isolate => open,
        configuration_vector(4 downto 0) => "10000",  -- Autoneg=1, Isolate=0, PowerDown=0, Loopback=0, Unidir=0 
        an_interrupt          => open,
        an_adv_config_vector  => X"0020",  -- AN FD, see PG047 table 2-55
        an_restart_config     => '0',
        status_vector         => status_vector, -- PG047 table 2-41
        reset                 => reset_async, -- GbE is reset async
        signal_detect         => '1',   -- no optics, signal is always present
		gt0_pll0outclk_out => open,
		gt0_pll0outrefclk_out => open,
		gt0_pll1outclk_out => open,
		gt0_pll1outrefclk_out => open,
		gt0_pll0refclklost_out => open,
		gt0_pll0lock_out => open
      );

	-- enable GBE SFP transmitter

	gbe_sfp_tx_dis <= '0';

    -- don't use the GBE SFP I2C interface for now, this is optional
    -- leave pins in high impedance state, PCB has pullup resistors

    gbe_sfp_scl  <= 'Z';
    gbe_sfp_sda  <= 'Z';

    -- get the lower byte of the MAC and IP address from the one time programmable EFUSE USER register

    EFUSE_USR_inst : EFUSE_USR
    generic map ( SIM_EFUSE_VALUE => X"DEADBEEF" ) -- Value of the 32-bit non-volatile value used in simulation
    port map ( EFUSEUSR => EFUSEUSR );

    -- OEI = "Off the shelf" Ethernet Interface 

    eth_int_inst: ethernet_interface
    port map(
        reset_in       => reset_async, 
        tx_data        => tx_data, 
        ready          => ready,
        b_data         => X"0000000000000000",  -- burst mode not used
        b_data_we      => '0',
        b_force_packet => '0',
        reset_out      => open,
        rx_addr        => rx_addr,
        rx_data        => rx_data,
        rx_wren        => rx_wren,
        tx_rden        => tx_rden,
        b_enable       => open,
        user_addr          => EFUSEUSR(15 downto 8),
        internal_block_sel => X"00000000",  -- internal access not used
        internal_addr      => X"00000000",
        internal_din       => X"0000000000000000",
        internal_we        => '0',
        -- internal_dout   => 
        phy_rxd    => gmii_rxd,
        phy_rx_dv  => gmii_rx_dv,
        phy_rx_er  => gmii_rx_er,
        master_clk => oeiclk,
        phy_txd    => gmii_txd,
        phy_tx_en  => gmii_tx_en,
        phy_tx_er  => gmii_tx_er,
        tx_clk     => open
    );

    -- delay the read address by one clock, this register will be used to drive the readback mux
    -- going to Ethernet interface.
    
    readmux_proc: process(oeiclk)
    begin
        if rising_edge(oeiclk) then
            rx_addr_reg <= rx_addr;
        end if;
    end process readmux_proc;

    -- BIG mux to determine what 64 bit value gets sent back to the Ethernet Interface

    tx_data <= test_reg                        when std_match(rx_addr_reg, TESTREG_ADDR) else 
               fifo_DO                         when std_match(rx_addr_reg, FIFO_ADDR) else 
               (X"000000000000" &  status_vector) when std_match(rx_addr_reg, STATVEC_ADDR) else
               sfp_stat_vector                 when std_match(rx_addr_reg, SFPSTATVEC_ADDR) else  
               (X"00000000deadbeef")           when std_match(rx_addr_reg, DEADBEEF_ADDR) else
               (X"0000000"&bram0_do)           when std_match(rx_addr_reg, BRAM0_ADDR) else
               (X"000000000"&version)          when std_match(rx_addr_reg, GITVER_ADDR) else

               (X"000000000000" & spy_bufr(0)(0))  when std_match(rx_addr_reg, SPYBUF_AFE0_D0_BASEADDR) else
               (X"000000000000" & spy_bufr(0)(1))  when std_match(rx_addr_reg, SPYBUF_AFE0_D1_BASEADDR) else
               (X"000000000000" & spy_bufr(0)(2))  when std_match(rx_addr_reg, SPYBUF_AFE0_D2_BASEADDR) else
               (X"000000000000" & spy_bufr(0)(3))  when std_match(rx_addr_reg, SPYBUF_AFE0_D3_BASEADDR) else
               (X"000000000000" & spy_bufr(0)(4))  when std_match(rx_addr_reg, SPYBUF_AFE0_D4_BASEADDR) else
               (X"000000000000" & spy_bufr(0)(5))  when std_match(rx_addr_reg, SPYBUF_AFE0_D5_BASEADDR) else
               (X"000000000000" & spy_bufr(0)(6))  when std_match(rx_addr_reg, SPYBUF_AFE0_D6_BASEADDR) else
               (X"000000000000" & spy_bufr(0)(7))  when std_match(rx_addr_reg, SPYBUF_AFE0_D7_BASEADDR) else
               (X"000000000000" & spy_bufr(0)(8))  when std_match(rx_addr_reg, SPYBUF_AFE0_FR_BASEADDR) else
         
               (X"000000000000" & spy_bufr(1)(0))  when std_match(rx_addr_reg, SPYBUF_AFE1_D0_BASEADDR) else
               (X"000000000000" & spy_bufr(1)(1))  when std_match(rx_addr_reg, SPYBUF_AFE1_D1_BASEADDR) else
               (X"000000000000" & spy_bufr(1)(2))  when std_match(rx_addr_reg, SPYBUF_AFE1_D2_BASEADDR) else
               (X"000000000000" & spy_bufr(1)(3))  when std_match(rx_addr_reg, SPYBUF_AFE1_D3_BASEADDR) else
               (X"000000000000" & spy_bufr(1)(4))  when std_match(rx_addr_reg, SPYBUF_AFE1_D4_BASEADDR) else
               (X"000000000000" & spy_bufr(1)(5))  when std_match(rx_addr_reg, SPYBUF_AFE1_D5_BASEADDR) else
               (X"000000000000" & spy_bufr(1)(6))  when std_match(rx_addr_reg, SPYBUF_AFE1_D6_BASEADDR) else
               (X"000000000000" & spy_bufr(1)(7))  when std_match(rx_addr_reg, SPYBUF_AFE1_D7_BASEADDR) else
               (X"000000000000" & spy_bufr(1)(8))  when std_match(rx_addr_reg, SPYBUF_AFE1_FR_BASEADDR) else

               (X"000000000000" & spy_bufr(2)(0))  when std_match(rx_addr_reg, SPYBUF_AFE2_D0_BASEADDR) else
               (X"000000000000" & spy_bufr(2)(1))  when std_match(rx_addr_reg, SPYBUF_AFE2_D1_BASEADDR) else
               (X"000000000000" & spy_bufr(2)(2))  when std_match(rx_addr_reg, SPYBUF_AFE2_D2_BASEADDR) else
               (X"000000000000" & spy_bufr(2)(3))  when std_match(rx_addr_reg, SPYBUF_AFE2_D3_BASEADDR) else
               (X"000000000000" & spy_bufr(2)(4))  when std_match(rx_addr_reg, SPYBUF_AFE2_D4_BASEADDR) else
               (X"000000000000" & spy_bufr(2)(5))  when std_match(rx_addr_reg, SPYBUF_AFE2_D5_BASEADDR) else
               (X"000000000000" & spy_bufr(2)(6))  when std_match(rx_addr_reg, SPYBUF_AFE2_D6_BASEADDR) else
               (X"000000000000" & spy_bufr(2)(7))  when std_match(rx_addr_reg, SPYBUF_AFE2_D7_BASEADDR) else
               (X"000000000000" & spy_bufr(2)(8))  when std_match(rx_addr_reg, SPYBUF_AFE2_FR_BASEADDR) else

               (X"000000000000" & spy_bufr(3)(0))  when std_match(rx_addr_reg, SPYBUF_AFE3_D0_BASEADDR) else
               (X"000000000000" & spy_bufr(3)(1))  when std_match(rx_addr_reg, SPYBUF_AFE3_D1_BASEADDR) else
               (X"000000000000" & spy_bufr(3)(2))  when std_match(rx_addr_reg, SPYBUF_AFE3_D2_BASEADDR) else
               (X"000000000000" & spy_bufr(3)(3))  when std_match(rx_addr_reg, SPYBUF_AFE3_D3_BASEADDR) else
               (X"000000000000" & spy_bufr(3)(4))  when std_match(rx_addr_reg, SPYBUF_AFE3_D4_BASEADDR) else
               (X"000000000000" & spy_bufr(3)(5))  when std_match(rx_addr_reg, SPYBUF_AFE3_D5_BASEADDR) else
               (X"000000000000" & spy_bufr(3)(6))  when std_match(rx_addr_reg, SPYBUF_AFE3_D6_BASEADDR) else
               (X"000000000000" & spy_bufr(3)(7))  when std_match(rx_addr_reg, SPYBUF_AFE3_D7_BASEADDR) else
               (X"000000000000" & spy_bufr(3)(8))  when std_match(rx_addr_reg, SPYBUF_AFE3_FR_BASEADDR) else

               (X"000000000000" & spy_bufr(4)(0))  when std_match(rx_addr_reg, SPYBUF_AFE4_D0_BASEADDR) else
               (X"000000000000" & spy_bufr(4)(1))  when std_match(rx_addr_reg, SPYBUF_AFE4_D1_BASEADDR) else
               (X"000000000000" & spy_bufr(4)(2))  when std_match(rx_addr_reg, SPYBUF_AFE4_D2_BASEADDR) else
               (X"000000000000" & spy_bufr(4)(3))  when std_match(rx_addr_reg, SPYBUF_AFE4_D3_BASEADDR) else
               (X"000000000000" & spy_bufr(4)(4))  when std_match(rx_addr_reg, SPYBUF_AFE4_D4_BASEADDR) else
               (X"000000000000" & spy_bufr(4)(5))  when std_match(rx_addr_reg, SPYBUF_AFE4_D5_BASEADDR) else
               (X"000000000000" & spy_bufr(4)(6))  when std_match(rx_addr_reg, SPYBUF_AFE4_D6_BASEADDR) else
               (X"000000000000" & spy_bufr(4)(7))  when std_match(rx_addr_reg, SPYBUF_AFE4_D7_BASEADDR) else
               (X"000000000000" & spy_bufr(4)(8))  when std_match(rx_addr_reg, SPYBUF_AFE4_FR_BASEADDR) else

               ts_spy_bufr(63 downto 0) when std_match(rx_addr_reg, SPYBUFTS_BASEADDR) else 

               (X"00000000000000" & "000" & fe_done) when std_match(rx_addr_reg, FEDONE_ADDR) else
               (X"00000000000000" & "000" & fe_warn) when std_match(rx_addr_reg, FEWARN_ADDR) else

               (X"00000000000000" & errcnt(0)) when std_match(rx_addr_reg, AFE0_ERRCNT_ADDR) else
               (X"00000000000000" & errcnt(1)) when std_match(rx_addr_reg, AFE1_ERRCNT_ADDR) else
               (X"00000000000000" & errcnt(2)) when std_match(rx_addr_reg, AFE2_ERRCNT_ADDR) else
               (X"00000000000000" & errcnt(3)) when std_match(rx_addr_reg, AFE3_ERRCNT_ADDR) else
               (X"00000000000000" & errcnt(4)) when std_match(rx_addr_reg, AFE4_ERRCNT_ADDR) else
               (X"00000000" & core_spy_data) when std_match(rx_addr_reg, SPYBUFDOUT0_BASEADDR) else 
               (X"00000000" & "000000" & daq_out_param_reg) when std_match(rx_addr_reg, DAQ_OUT_PARAM_ADDR) else -- 26 bits
               (X"000000000000" & "000" & mclk_stat_reg) when std_match(rx_addr_reg, MCLK_STAT_ADDR) else
               (X"000000000000" & mclk_ctrl_reg) when std_match(rx_addr_reg, MCLK_CTRL_ADDR) else 
               (X"00000000000000" & spi_res_fifo_data) when std_match(rx_addr_reg, SPI_FIFO_ADDR) else 
               (X"000000000000" & "00" & threshold_reg(13 downto 0)) when std_match(rx_addr_reg, THRESHOLD_BASEADDR) else 
               (X"00000000000000" & outmode_reg(7 downto 0)) when std_match(rx_addr_reg, DAQ_OUTMODE_BASEADDR) else 
               (X"00000000000000" & "00" & inmux_dout(5 downto 0)) when std_match(rx_addr_reg, CORE_INMUX_ADDR) else
               (X"000000" & st_enable_reg) when std_match(rx_addr_reg, ST_ENABLE_ADDR) else

               (others=>'0');

    ready <= '1' when (rx_wren='1') else  -- no wait for writes 
             '1' when (tx_rden='1') else  -- no wait for reads
             '0';

    -- 64-bit R/W dummy register for testing reads and writes

    testreg_we <= '1' when (std_match(rx_addr,TESTREG_ADDR) and rx_wren='1') else '0';

    test_proc: process(oeiclk)
    begin
        if rising_edge(oeiclk) then
            if (testreg_we='1') then
                test_reg <= rx_data;
            end if;
        end if;
    end process test_proc;

    -- test: connect a single port 1k x 36 blockRAM to the OTS
    -- this memory block maps into 0x00070000 - 0x000703FF
 
    bram0_we <= "1111" when (std_match(rx_addr,BRAM0_ADDR) and rx_wren='1') else "0000";

    BRAM0_inst : BRAM_SINGLE_MACRO -- 1k x 36, 10 bit addr
    generic map(
        BRAM_SIZE => "36Kb",
        DEVICE => "7SERIES",
        DO_REG => 0, 
        INIT => X"000000000",
        INIT_FILE => "NONE",
        WRITE_WIDTH => 36,
        READ_WIDTH => 36,
        SRVAL => X"000000000",
        WRITE_MODE => "READ_FIRST"
    )   
    port map(
        DO    => bram0_do(35 downto 0),
        ADDR  => rx_addr(9 downto 0),
        CLK   => oeiclk,
        DI    => rx_data(35 downto 0),
        EN    => '1',
        REGCE => '1',
        RST   => '0',
        WE    => bram0_we
    );

    -- test FIFO is 512 x 64. what happens if we try to read from an empty FIFO?

    fifo_WREN <= '1' when (std_match(rx_addr,FIFO_ADDR) and rx_wren='1') else '0'; 
    fifo_RDEN <= '1' when (std_match(rx_addr,FIFO_ADDR) and tx_rden='1') else '0'; 
    
    FIFO_SYNC_inst: FIFO_SYNC_MACRO
    generic map (
        DEVICE => "7SERIES",
        ALMOST_FULL_OFFSET => X"0080",
        ALMOST_EMPTY_OFFSET => X"0080",
        DATA_WIDTH => 64,
        FIFO_SIZE => "36Kb")
    port map (
        ALMOSTEMPTY => open,
        ALMOSTFULL => open,
        DO => fifo_DO,
        EMPTY => open,
        FULL => open,
        RDCOUNT => dummy_RDCOUNT,
        RDERR => open,
        WRCOUNT => dummy_WRCOUNT,
        WRERR => open,
        CLK => oeiclk,
        DI => rx_data,
        RDEN => fifo_RDEN,
        RST => reset_async,
        WREN => fifo_WREN
    );

    -- SFP module status vector. Loss of signal (LOS) and Absent (ABS) bits
    -- go here. Should be zero under normal conditions. These are unregistered
    -- slow signals OK to add timing ignore constraint here. The SFP used for 
    -- 100BASE-FX Ethernet connects to the uC, not the FPGA.

    sfp_stat_vector <= X"0000" &
    ("000000" & cdr_sfp_los & cdr_sfp_abs) &  
    ("000000" & gbe_sfp_los & gbe_sfp_abs) &
	("000000" & daq3_sfp_los & daq3_sfp_abs) &
    ("000000" & daq2_sfp_los & daq2_sfp_abs) &
    ("000000" & daq1_sfp_los & daq1_sfp_abs) & 
    ("000000" & daq0_sfp_los & daq0_sfp_abs);
    
    -- DAPHNE Core Logic ------------------------------------------------------

    -- enable DAQ Link SFP transmitters...

	daq0_sfp_tx_dis <= '0';
	daq1_sfp_tx_dis <= '0';
	daq2_sfp_tx_dis <= '0';
	daq3_sfp_tx_dis <= '0';

    -- DAQ SFP I2C interface, reserved for future use...

    daq0_sfp_scl <= 'Z';
    daq1_sfp_scl <= 'Z';
    daq2_sfp_scl <= 'Z';
    daq3_sfp_scl <= 'Z';

    daq0_sfp_sda <= 'Z';
    daq1_sfp_sda <= 'Z';
    daq2_sfp_sda <= 'Z';
    daq3_sfp_sda <= 'Z';

    -- register for storing quasi-static output record parameters, R/W via GbE
    -- slot_id(3..0) & crate_id(9..0) & detector_id(5..0) & version_id(5..0)

    daq_out_param_we <= '1' when (std_match(rx_addr,DAQ_OUT_PARAM_ADDR) and rx_wren='1') else '0';

    misc_outlink_stuff_proc: process(oeiclk)
    begin
        if rising_edge(oeiclk) then
            if (reset_async='1') then
                daq_out_param_reg <= (DEFAULT_DAQ_OUT_SLOT_ID & DEFAULT_DAQ_OUT_CRATE_ID & DEFAULT_DAQ_OUT_DETECTOR_ID & DEFAULT_DAQ_OUT_VERSION_ID);
            elsif (daq_out_param_we='1') then
                daq_out_param_reg <= rx_data(25 downto 0);
            end if;
        end if;
    end process misc_outlink_stuff_proc;

    -- register for controlling daq output link mode (idle, streaming, selftrig)
    -- outmode is 8 bits, R/W from GBE

    outmode_we <= '1' when (std_match(rx_addr,DAQ_OUTMODE_BASEADDR) and rx_wren='1') else '0';

    outmode_proc: process(oeiclk)
    begin
        if rising_edge(oeiclk) then
            if (reset_async='1') then
                outmode_reg <= DEFAULT_DAQ_OUTMODE;
            elsif (outmode_we='1') then
                outmode_reg <= rx_data(7 downto 0);
            end if;
        end if;
    end process outmode_proc;

    -- register for setting threshold (relative to avg baseline) for self triggered senders
    -- register is 14 bits, R/W from GBE

    threshold_we <= '1' when (std_match(rx_addr,THRESHOLD_BASEADDR) and rx_wren='1') else '0';
    

    thresh_proc: process(oeiclk)
    begin
        if rising_edge(oeiclk) then
            if (reset_async='1') then
                threshold_reg <= DEFAULT_THRESHOLD;
            elsif (threshold_we='1') then
                threshold_reg <= rx_data(13 downto 0);
            end if;
        end if;
    end process thresh_proc;

    -- register to enable or disable individual input channels for the self triggered sender
    -- which is connected to all 40 input data channels. this 40 bit reg is R/W. this does NOT
    -- apply to the four streaming senders, which use a more flexible muxing scheme on their inputs

    st_enable_we <= '1' when (std_match(rx_addr,ST_ENABLE_ADDR) and rx_wren='1') else '0';

    st_enable_proc: process(oeiclk)
    begin
        if rising_edge(oeiclk) then
            if (reset_async='1') then
                st_enable_reg <= DEFAULT_ST_ENABLE;
            elsif (st_enable_we='1') then
                st_enable_reg <= rx_data(39 downto 0);
            end if;
        end if;
    end process st_enable_proc;

    -- decode write enable for core inmux control register block of 40 6-bit registers

    inmux_we <= '1' when (std_match(rx_addr,CORE_INMUX_ADDR) and rx_wren='1') else '0';

    -- combo core logic, streaming and self-trig

    core_inst: core
    port map(
        mclk => mclk,
        sclk100 => sclk100,
        reset => reset_async,

        afe_dat => afe_dout,
        timestamp => timestamp,

        outmode => outmode_reg,
        threshold => threshold_reg,
	--
	    ti_trigger => ti_trigger_reg, --------------------
        ti_trigger_stbr => ti_trigger_stbr_reg, -------------------

        slot_id => daq_out_param_reg(25 downto 22),  -- 4 bits
        crate_id => daq_out_param_reg(21 downto 12), -- 10 bits
        detector_id => daq_out_param_reg(11 downto 6), -- 6 bits
        version_id => daq_out_param_reg(5 downto 0), -- 6 bits
        st_enable => st_enable_reg,
   
        oeiclk => oeiclk,
        trig => trig_sync,
        addr => rx_addr(11 downto 0),
        din => rx_data(5 downto 0),
        inmux_we => inmux_we,
        spy_dout => core_spy_data(31 downto 0),
        inmux_dout => inmux_dout,
        
        daq_refclk_p => daq_refclk_p, daq_refclk_n => daq_refclk_n,
        daq0_tx_p => daq0_tx_p, daq0_tx_n => daq0_tx_n,
        daq1_tx_p => daq1_tx_p, daq1_tx_n => daq1_tx_n,
        daq2_tx_p => daq2_tx_p, daq2_tx_n => daq2_tx_n,
        daq3_tx_p => daq3_tx_p, daq3_tx_n => daq3_tx_n
    );

    -- SPI Slave Interface ----------------------------------------------------
    -- used for slow controls communication with the uC
    -- this module presents a pair of FIFOs (each 2k x 8) to the GbE interface
    -- user writes an ascii string into the CMD FIFO and reads the response
    -- from the uC from the RES FIFO. SPI_IRQ is used to tell the uC that 
    -- there is data in the CMD FIFO. Since the CMD FIFO is write only and the 
    -- RES FIFO is read only these FIFOs are memory mapped into the same location.
   
    spi_cmd_fifo_wren <= '1' when (std_match(rx_addr,SPI_FIFO_ADDR) and rx_wren='1') else '0'; 
    spi_res_fifo_rden <= '1' when (std_match(rx_addr,SPI_FIFO_ADDR) and tx_rden='1') else '0'; 

    spi_inst: spi
    port map(
        clock => sclk100, 
        reset => reset_async,

        spi_clk  => spi_clk,
        spi_csn  => spi_csn,
        spi_mosi => spi_mosi,
        spi_miso => spi_miso,
        spi_irq  => spi_irq,

        oeiclk => oeiclk,
        cmd_wren => spi_cmd_fifo_wren,
        cmd_data => rx_data(7 downto 0),
        res_rden => spi_res_fifo_rden,
        res_data => spi_res_fifo_data 
    );

    -- LED Blinker ------------------------------------------------------------

	-- DAPHNE has 6 LEDs controlled by the FPGA, which are labeled on the PCB like this:
    --  led(5)   led(4)     led(3)     led(2)    led(1)    led(0)
    -- "LED14"   "LED13"    "LED4"     "LED3"    "LED2"    "LED1"    "LED5 (uC)"     

	led_temp(0) <= mmcm1_locked; -- "LED1" on if master clock MMCM1 is locked
    led_temp(1) <= '1' when (fe_done="11111") else '0'; -- "LED2" on automatic front end is DONE
	led_temp(2) <= '1' when (ep_ts_rdy='1') else '0'; -- "LED3" on if timing endpoint is synchronized and timestamp is valid
	led_temp(3) <= '1' when (status_vector(0)='1' and status_vector(11 downto 10)="10") else '0'; -- "LED4" on if link is UP and speed is 1000
	led_temp(4) <= gmii_rx_dv or gmii_tx_en; -- "LED13" is on if there is ethernet RX or TX activity
	led_temp(5) <= trig_sync; -- "LED14" is on when DAPHNE is triggered 

	-- LED driver logic. pulse stretch fast signals so they are visible (aka a "one shot")
	-- Use a fast clock to sample the signal led_temp. whenever led_temp is HIGH, led0_reg
	-- goes high and stays high. periodically (200MHz / 2^24 = 11Hz) copy led0_reg into led1_reg 
	-- and reset led0_reg. this insures that the output signal led1_reg is HIGH for a whole
	-- 11Hz cycle, regardless of when the blip on the led_temp occurs.

    oneshot_proc: process(sclk200)
    begin
        if rising_edge(sclk200) then
            if (reset_async='1') then
                count_reg <= (others=>'0');
                edge_reg  <= '0';
                led0_reg <= (others=>'0');
				led1_reg <= (others=>'0');
            else
                count_reg <= std_logic_vector(unsigned(count_reg) + 1);
                edge_reg  <= count_reg(23);

                if (edge_reg='0' and count_reg(23)='1') then -- MSB of the counter was JUST set
                    led1_reg <= led0_reg;
                    led0_reg <= (others=>'0');
                else
                    led0_reg <= led0_reg or led_temp;
                end if;
            end if;
        end if;
    end process oneshot_proc;
   
    -- DAPHNE LEDs are ACTIVE LOW

    led <= not led1_reg;

end DAPHNE2_arch;
