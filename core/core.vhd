-- core.vhd
-- DAPHNE2 core logic
--
-- This core logic supports BOTH the SELF-TRIGGERED and STREAMING mode senders.
-- A flexible input mux (inmux) connects any input channel to the streaming sender inputs
-- the control registers that control the inmux selection are read/write
--
-- there is one self-triggered sender, and it is hard wired to all forty inputs and does not 
-- use the flexble inmux layer
--
-- streaming and self-triggered senders are always present and active, but an output
-- mux selects which sender drives the output links:
--
-- outreg(7..6) = output link 3 control: "11"=self-trig sender3, "10"=stream sender3, else idle
-- outreg(5..4) = output link 2 control: "11"=self-trig sender2, "10"=stream sender2, else idle
-- outreg(3..2) = output link 1 control: "11"=self-trig sender1, "10"=stream sender1, else idle
-- outreg(1..0) = output link 0 control: "11"=self-trig sender0, "10"=stream sender0, else idle
--
-- a spy buffer is present on output link 0 and is triggered manually

-- jamieson olsen <jamieson@fnal.gov>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.daphne2_package.all;

entity core is
port(
    mclk: in std_logic; -- master clock 62.5MHz
    sclk100: in std_logic; -- system clock 100MHz 
    reset: in std_logic; -- for sender logic and for GTP quad
    afe_dat: in array_5x9x14_type;  -- AFE data synch to mclk
    timestamp: in std_logic_vector(63 downto 0); -- sync to mclk

    outmode: in std_logic_vector(7 downto 0); -- output link mode control
    threshold: in std_logic_vector(13 downto 0); -- for self-triggered mode, relative to average baseline

    ti_trigger: in std_logic_vector(7 downto 0); ------------------------
    ti_trigger_stbr: in std_logic; -------------------------------------

    slot_id: in std_logic_vector(3 downto 0); -- used in output header
    crate_id: in std_logic_vector(9 downto 0); -- used in output header
    detector_id: in std_logic_vector(5 downto 0); -- used in output header
    version_id: in std_logic_vector(5 downto 0); -- used in output header
    st_enable: in std_logic_vector(39 downto 0); -- enable/disable channels for self-triggered sender only

    oeiclk: in std_logic; -- interface used for output spy buffer and to configure input mux
    trig: in std_logic; -- manually trigger output spy buffer
    addr: in std_logic_vector(11 downto 0); -- for spy buffer and inmux control registers
    din: in std_logic_vector(5 downto 0); -- data to write to inmux control registers
    spy_dout: out std_logic_vector(31 downto 0); -- spy buffer data for reading
    inmux_we: in std_logic; -- write enable for inmux control regs
    inmux_dout: out std_logic_vector(5 downto 0); -- read inmux control regs

    daq_refclk_p, daq_refclk_n: in std_logic; -- MGT REFCLK for DAQ, LVDS, quad 213, refclk0, 120.237MHz
    daq0_tx_p, daq0_tx_n: out std_logic;
    daq1_tx_p, daq1_tx_n: out std_logic;
    daq2_tx_p, daq2_tx_n: out std_logic;
    daq3_tx_p, daq3_tx_n: out std_logic
);
end core;

architecture core_arch of core is

    component inmux -- input channel mux determines which inputs connect to which sender
    port(
        clock: in std_logic;
        reset: in std_logic;
        we: in std_logic;
        addr: in std_logic_vector(3 downto 0);
        din: in std_logic_vector(5 downto 0);
        dout: out std_logic_vector(5 downto 0);    
        afe_dat: in array_5x9x14_type; -- AFE data synced to mclk
        data_out: out array_4x4x14_type; -- AFE data out to the senders
        chid_out: out array_4x4x6_type -- channel id outputs
    );
    end component;

    component dstr4 -- 4 channel streaming sender
    generic( link_id: std_logic_vector(5 downto 0) := "000000" );  
    port(
        reset: in std_logic;
        slot_id: in std_logic_vector(3 downto 0);
        crate_id: in std_logic_vector(9 downto 0);
        detector_id: in std_logic_vector(5 downto 0);
        version_id: in std_logic_vector(5 downto 0);
        mclk: in std_logic; -- master clock 62.5 MHz
        timestamp: in std_logic_vector(63 downto 0);
	    afe_dat: in array_4x14_type; -- four AFE ADC channels
        ch_id: in array_4x6_type; -- the channel ID number
        fclk: in std_logic; -- transmit clock to FELIX 120.237 MHz 
        dout: out std_logic_vector(31 downto 0);
        kout: out std_logic_vector( 3 downto 0));
    end component;

    component st40_top -- 40 channel self-triggered sender
    generic( link_id: std_logic_vector(5 downto 0)  := "000000" );
    port(
        reset: in std_logic;    
        threshold: in std_logic_vector(13 downto 0); -- user defined threshold relative to baseline
        ti_trigger: in std_logic_vector(7 downto 0); -------------------------
        ti_trigger_stbr: in std_logic;  -------------------------
        slot_id: in std_logic_vector(3 downto 0);
        crate_id: in std_logic_vector(9 downto 0);
        detector_id: in std_logic_vector(5 downto 0);
        version_id: in std_logic_vector(5 downto 0);
        enable: in std_logic_vector(39 downto 0);
        aclk: in std_logic; -- AFE clock 62.500 MHz
        timestamp: in std_logic_vector(63 downto 0);
    	afe_dat: in array_5x9x14_type; -- ADC data all 40 input streams
        fclk: in std_logic; -- transmit clock to FELIX 120.237 MHz 
        dout: out std_logic_vector(31 downto 0);
        kout: out std_logic_vector(3 downto 0)
    );
    end component;

    component spy
    port(
        clka:  in std_logic;  
        reset: in std_logic;
        trig:  in std_logic;
        dia:   in std_logic_vector(15 downto 0);
        clkb:  in  std_logic;
        addrb: in  std_logic_vector(11 downto 0);
        dob:   out std_logic_vector(15 downto 0)
      );
    end component;

    component core_mgt4  -- a wrapper for the Xilinx MGT IP core
    port(
        sysclk_in: in std_logic;
        soft_reset_tx_in: in std_logic; 
    
        q0_clk0_gtrefclk_pad_p_in: in std_logic;
        q0_clk0_gtrefclk_pad_n_in: in std_logic;
    
        gt0_txdata_in: in std_logic_vector(31 downto 0);
        gt1_txdata_in: in std_logic_vector(31 downto 0);
        gt2_txdata_in: in std_logic_vector(31 downto 0);
        gt3_txdata_in: in std_logic_vector(31 downto 0);
    
        gt0_txcharisk_in: in std_logic_vector(3 downto 0);
        gt1_txcharisk_in: in std_logic_vector(3 downto 0);
        gt2_txcharisk_in: in std_logic_vector(3 downto 0);
        gt3_txcharisk_in: in std_logic_vector(3 downto 0);
    
        gt0_txusrclk2_out: out std_logic;
        gt1_txusrclk2_out: out std_logic;
        gt2_txusrclk2_out: out std_logic;
        gt3_txusrclk2_out: out std_logic;
       
        gt0_gtptxp_out, gt0_gtptxn_out: out std_logic;
        gt1_gtptxp_out, gt1_gtptxn_out: out std_logic;
        gt2_gtptxp_out, gt2_gtptxn_out: out std_logic;
        gt3_gtptxp_out, gt3_gtptxn_out: out std_logic    
    );
    end component;

    signal fclk: std_logic_vector(3 downto 0);
    signal mux_data: array_4x4x14_type;
    signal mux_chid: array_4x4x6_type;
    signal stream_sender_dout, sender_dout: array_4x32_type; 
    signal stream_sender_kout, sender_kout: array_4x4_type;
    signal selftrig_sender_dout: std_logic_vector(31 downto 0);
    signal selftrig_sender_kout: std_logic_vector(3 downto 0);
    signal trig_fclk_reg: std_logic;

begin
    
    -- big mux to determine which input channels are connected to which streaming sender module
    -- the mux control registers are set by the oei ethernet interface and can be read back to verify
    -- the senders need to know the input channel id's for each data stream they are receiving from the mux
    -- and that is the purpose of the chid_out output
    
    input_inst: inmux 
    port map(
        clock => oeiclk,
        reset => reset,
        we => inmux_we, -- R/W access to mux control registers
        addr => addr(3 downto 0),
        din => din,
        dout => inmux_dout, 

        afe_dat => afe_dat, -- AFE raw data after alignment 
        data_out => mux_data, -- afe data streams array_4x4x14
        chid_out => mux_chid  -- input channel id array_4x4x6
    );

    -- instantiate four streaming senders

    gen_stream_sender: for i in 3 downto 0 generate

        stream_sender_inst: dstr4 
        generic map( link_id => std_logic_vector( to_unsigned(i,6)) )
        port map(
            reset => reset,
            slot_id => slot_id,
            crate_id => crate_id,
            detector_id => detector_id,
            version_id => version_id,
            mclk => mclk,
            timestamp => timestamp,
        	afe_dat(3) => mux_data(i)(3), 
            afe_dat(2) => mux_data(i)(2), 
            afe_dat(1) => mux_data(i)(1), 
            afe_dat(0) => mux_data(i)(0), 
            ch_id(3) => mux_chid(i)(3),
            ch_id(2) => mux_chid(i)(2), 
            ch_id(1) => mux_chid(i)(1),
            ch_id(0) => mux_chid(i)(0),
            fclk => fclk(i),
            dout => stream_sender_dout(i),
            kout => stream_sender_kout(i)
        );

    end generate gen_stream_sender;

    -- instantiate ONE 40-input self-triggered sender

    st40_sender_inst: st40_top 
    generic map( link_id => "000000" )
    port map(
        reset => reset,
        threshold => threshold,
        slot_id => slot_id,
        crate_id => crate_id,
        detector_id => detector_id,
        version_id => version_id,
        enable => st_enable,
        aclk => mclk,
        timestamp => timestamp,
        ti_trigger => ti_trigger, ------------------------------
        ti_trigger_stbr => ti_trigger_stbr, -------------------------
    	afe_dat => afe_dat, -- AFE raw data after alignment all 40 channels
        fclk => fclk(0), 
        dout => selftrig_sender_dout,
        kout => selftrig_sender_kout
    );

    -- there are four outputs (sender_kout and sender_dout) and these muxes 
    -- determine whether the streaming or self trig sender drives them. the muxes are controlled 
    -- by bits in the outmode register. If neither the streaming nor self-trig sender is selected
    -- then idle/sync words are sent instead.

    gen_outmux: for i in 3 downto 0 generate
    
        sender_kout(i) <= stream_sender_kout(i)   when (outmode((2*i)+1 downto 2*i)="10") else 
                          selftrig_sender_kout when (outmode((2*i)+1 downto 2*i)="11") else 
                          "0001"; -- idle word

        sender_dout(i) <= stream_sender_dout(i)   when (outmode((2*i)+1 downto 2*i)="10") else 
                          selftrig_sender_dout when (outmode((2*i)+1 downto 2*i)="11") else 
                          X"000000BC"; -- idle word

    end generate gen_outmux;

    -- the trigger input to this module comes from the mclk clock domain
    -- and the pulse is guaranteed to be several mclk cycles wide.
    -- resample in the fclk domain before it can be used by the spy buffers

    trig_fclk_proc: process(fclk(0))
    begin
        if rising_edge(fclk(0)) then
            trig_fclk_reg <= trig;
        end if;
    end process trig_fclk_proc;

    -- insert some spy buffers to capture the output of sender0
    -- stores the 32 bit data prior to 8b/10b encoding, depth is 4k
    -- has 64 pre-trigger samples too.

    sender0_spy_hi_inst: spy
    port map(
        clka  => fclk(0),
        reset => reset,
        trig  => trig_fclk_reg,
        dia   => sender_dout(0)(31 downto 16),

        clkb  => oeiclk,
        addrb => addr(11 downto 0),
        dob   => spy_dout(31 downto 16)
      );

    sender0_spy_lo_inst: spy
    port map(
        clka  => fclk(0),
        reset => reset,
        trig  => trig_fclk_reg,
        dia   => sender_dout(0)(15 downto 0),

        clkb  => oeiclk,
        addrb => addr(11 downto 0),
        dob   => spy_dout(15 downto 0)
      );

    -- wrapper for Xilinx MGT IP core. One MGT quad, for channels TX only, no DRP

    core_mgt4_inst: core_mgt4
    port map(
        sysclk_in => sclk100, -- system clock constant 100MHz
        soft_reset_tx_in => reset,
       
        gt0_txdata_in => sender_dout(0),
        gt1_txdata_in => sender_dout(1),
        gt2_txdata_in => sender_dout(2),
        gt3_txdata_in => sender_dout(3),
    
        gt0_txcharisk_in => sender_kout(0),
        gt1_txcharisk_in => sender_kout(1),
        gt2_txcharisk_in => sender_kout(2),
        gt3_txcharisk_in => sender_kout(3),
    
        gt0_txusrclk2_out => fclk(0),
        gt1_txusrclk2_out => fclk(1),
        gt2_txusrclk2_out => fclk(2),
        gt3_txusrclk2_out => fclk(3),

        q0_clk0_gtrefclk_pad_p_in => daq_refclk_p,  -- 120.237MHz for FELIX links
        q0_clk0_gtrefclk_pad_n_in => daq_refclk_n,
      
        gt0_gtptxp_out => daq0_tx_p,
        gt0_gtptxn_out => daq0_tx_n,
        gt1_gtptxp_out => daq1_tx_p,
        gt1_gtptxn_out => daq1_tx_n,
        gt2_gtptxp_out => daq2_tx_p,
        gt2_gtptxn_out => daq2_tx_n,
        gt3_gtptxp_out => daq3_tx_p,
        gt3_gtptxn_out => daq3_tx_n    
    );

end core_arch; 
