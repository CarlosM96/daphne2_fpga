-- endpoint.vhd
-- master clock distribution for DAPHNE2 includes NEW Bristol Timing Endpoint Logic 2.0
-- 
-- MMCM0: takes 100MHz system clock and produces SCLK100, SCLK200, local 62.5MHz clock
--        this MMCM is reset by a hard reset from the uC
--
-- MMCM1: choose between local 62.5MHz clock or timing endpoint 62.5MHz clock. Generates the master clock 62.5MHz
--        and fast clock 437.5MHz for the front end. use_ep is the bit that does the switching.
--
-- Timestamp is generated by endpoint (use_ep=1) or faked with free running counter (use_ep=0)

-- jamieson olsen <jamieson@fnal.gov>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity endpoint is
port(

    sysclk_p, sysclk_n: in std_logic; -- system clock LVDS 100MHz from local oscillator
    reset_async: in std_logic; -- async hard reset from the microcontroller

    -- external optical timing SFP link interface

    cdr_sfp_los: in std_logic; -- loss of signal
    cdr_sfp_tx_dis: out std_logic; -- high to disable timing SFP TX
    cdr_sfp_tx_p, cdr_sfp_tx_n: out std_logic; -- send data upstream

    -- external CDR chip interface: ignore CLKOUT, LOS, and LOL

    adn2814_data_p, adn2814_data_n: in std_logic; -- LVDS recovered serial data ACKCHYUALLY the clock!

    -- timing endpoint interface 

    ep_reset: in std_logic; -- soft reset endpoint logic
    ep_ts_rdy: out std_logic; -- endpoint timestamp is good
    ep_stat: out std_logic_vector(3 downto 0); -- endpoint state bits

    -- misc interface signals

    mmcm1_reset: in std_logic;
    mmcm1_locked: out std_logic;
    mmcm0_locked: out std_logic;

    use_ep: in std_logic; -- 0 = run on local clocks with fake timestamp, 1 = use endpoint clocks and real timestamp

    mclk: out std_logic;  -- master clock 62.5MHz
    fclk: out std_logic;  -- fast clock for frontend
    sclk200: out std_logic; -- system clock 200MHz
    sclk100: out std_logic; -- system clock 100MHz

    timestamp: out std_logic_vector(63 downto 0) -- sync to mclk

  );
end endpoint;

architecture endpoint_arch of endpoint is

component pdts_endpoint_wrapper is -- wrapped and cleaned up for DAPHNE V2a design
	port(
		sys_clk: in std_logic; -- System clock is 100MHz
		sys_rst: in std_logic; -- System reset (sclk domain)
		sys_stat: out std_logic_vector(3 downto 0); -- Status output (sclk domain)
		los: in std_logic := '0'; -- External signal path status (async)
		rxd: in std_logic; -- Timing input (clk domain)
		txd: out std_logic; -- Timing output (clk domain)
		txenb: out std_logic; -- Timing output enable (active low for SFP) (clk domain)
		clk: out std_logic; -- Base clock output is 62.5MHz
		rst: out std_logic; -- Base clock reset (clk domain)
		ready: out std_logic; -- Endpoint ready flag (clk domain)
		tstamp: out std_logic_vector(63 downto 0) -- Timestamp (clk domain)
	);
end component;

signal sysclk_ibuf: std_logic;
signal mmcm0_clkfbout, mmcm0_clkfbout_buf: std_logic;
signal mmcm0_clkout0, mmcm0_clkout1, mmcm0_clkout2: std_logic;
signal local_clk62p5: std_logic;
signal sclk100_i: std_logic;

signal adn2814_data: std_logic;

signal ep_clk62p5: std_logic;
signal cdr_sfp_txd: std_logic;

signal mmcm1_clkfbout, mmcm1_clkfbout_buf: std_logic;
signal mmcm1_clkout0, mmcm1_clkout1, mmcm1_clkout2: std_logic;
signal mclk_i: std_logic;

signal real_timestamp, fake_timestamp, timestamp_reg: std_logic_vector(63 downto 0);

begin

-- sysclk is 100MHz LVDS, receive it with IBUFDS. sysclk comes in on bank 33
-- which has VCCO=1.5V. IOSTANDARD is LVDS and the termination resistor is external (DIFF_TERM=FALSE)

sysclk_ibufds_inst : IBUFGDS port map(O => sysclk_ibuf, I => sysclk_p, IB => sysclk_n);

mmcm0_inst: MMCME2_ADV
generic map(
    BANDWIDTH            => "OPTIMIZED",
    CLKOUT4_CASCADE      => FALSE,
    COMPENSATION         => "ZHOLD",
    STARTUP_WAIT         => FALSE,
    DIVCLK_DIVIDE        => 1,
    CLKFBOUT_MULT_F      => 10.000, -- VCO = 1000MHz
    CLKFBOUT_PHASE       => 0.000,
    CLKFBOUT_USE_FINE_PS => FALSE,
    CLKOUT0_DIVIDE_F     => 16.000, -- CLKOUT0 = 62.5MHz
    CLKOUT0_PHASE        => 0.000,
    CLKOUT0_DUTY_CYCLE   => 0.500,
    CLKOUT0_USE_FINE_PS  => FALSE,
    CLKOUT1_DIVIDE       => 5, -- CLKOUT1 = 200MHz
    CLKOUT1_PHASE        => 0.000,
    CLKOUT1_DUTY_CYCLE   => 0.500,
    CLKOUT1_USE_FINE_PS  => FALSE,
    CLKOUT2_DIVIDE       => 10, -- CLKOUT2 = 100MHz
    CLKOUT2_PHASE        => 0.000,
    CLKOUT2_DUTY_CYCLE   => 0.500,
    CLKOUT2_USE_FINE_PS  => FALSE,
    CLKIN1_PERIOD        => 10.000 -- 100MHz system clock input
)
port map(
    CLKFBOUT            => mmcm0_clkfbout,
    CLKFBOUTB           => open,
    CLKOUT0             => mmcm0_clkout0, -- 62.5MHz
    CLKOUT0B            => open,
    CLKOUT1             => mmcm0_clkout1, -- 200MHz
    CLKOUT1B            => open,
    CLKOUT2             => mmcm0_clkout2, -- 100MHz
    CLKOUT2B            => open,     
    CLKOUT3             => open, 
    CLKOUT3B            => open,
    CLKOUT4             => open,
    CLKOUT5             => open,
    CLKOUT6             => open,
    CLKFBIN             => mmcm0_clkfbout_buf,
    CLKIN1              => sysclk_ibuf,
    CLKIN2              => '0',
    CLKINSEL            => '1', -- high to use CLKIN1
    DADDR               => (others=>'0'),
    DCLK                => '0',
    DEN                 => '0',
    DI                  => (others=>'0'),
    DO                  => open,
    DRDY                => open,
    DWE                 => '0',
    PSCLK               => '0',
    PSEN                => '0',
    PSINCDEC            => '0',
    PSDONE              => open,
    LOCKED              => mmcm0_locked,
    CLKINSTOPPED        => open,
    CLKFBSTOPPED        => open,
    PWRDWN              => '0',
    RST                 => reset_async
);

mmcm0_clkfb_inst: BUFG port map( I => mmcm0_clkfbout, O => mmcm0_clkfbout_buf);

mmcm0_clk0_inst:  BUFG port map( I => mmcm0_clkout0, O => local_clk62p5); -- local clock 62.5MHz

mmcm0_clk1_inst:  BUFG port map( I => mmcm0_clkout1, O => sclk200); -- system clock 200MHz

mmcm_clk2_inst:  BUFG port map( I => mmcm0_clkout2, O => sclk100_i);  -- system clock 100MHz

sclk100 <= sclk100_i;

-- DATA OUT from ADN2814 chip is the modulated clock

cdr_data_inst: IBUFDS
generic map( DIFF_TERM => TRUE, IBUF_LOW_PWR => FALSE, IOSTANDARD => "LVDS_25" )
port map( I => adn2814_data_p, IB => adn2814_data_n, O  => adn2814_data );

-- new timing endpoint 2.0
-- The external CDR chip is used but the CLKOUT output is ignored
-- and the PWM clock is passed through on the DATAOUT output

pdts_endpoint_inst: pdts_endpoint_wrapper
	port map(
		sys_clk => sclk100_i, -- 100MHz from MMCM0
		sys_rst => ep_reset,
		sys_stat => ep_stat,
		los => cdr_sfp_los,
		rxd => adn2814_data, -- NEW: get the modulated clock from the external CDR DATA output
		txd => cdr_sfp_txd, 
		txenb => cdr_sfp_tx_dis, -- Timing output enable (active low for SFP) (clk domain)
		clk => ep_clk62p5, -- output clock from endpoint 62.5MHz
		rst => open, -- endpoint reset output not used here
		ready => ep_ts_rdy,
		tstamp => real_timestamp
	);

-- LVDS driver for timing SFP return channel

OBUFDS_inst: OBUFDS
generic map(IOSTANDARD=>"LVDS_25")
port map( I => cdr_sfp_txd, O => cdr_sfp_tx_p, OB => cdr_sfp_tx_n );

-- MMCM1 chooses between local clock 62.5MHz or the endpoint clock 62.5MHz
-- after switching be sure to reset this MMCM! From the selected clock generate
-- the master 62.5MHz and the 437.5MHz clock needed for the front end

mmcm1_inst: MMCME2_ADV
generic map(
    BANDWIDTH            => "OPTIMIZED",
    CLKOUT4_CASCADE      => FALSE,
    COMPENSATION         => "ZHOLD",
    STARTUP_WAIT         => FALSE,
    DIVCLK_DIVIDE        => 1,
    CLKFBOUT_MULT_F      => 14.000, -- VCO = 875MHz
    CLKFBOUT_PHASE       => 0.000,
    CLKFBOUT_USE_FINE_PS => FALSE,
    CLKOUT0_DIVIDE_F     => 2.000, -- CLKOUT0 = 437.5MHz
    CLKOUT0_PHASE        => 0.000,
    CLKOUT0_DUTY_CYCLE   => 0.500,
    CLKOUT0_USE_FINE_PS  => FALSE,
    CLKOUT1_DIVIDE       => 14, -- CLKOUT1 = 62.5MHz
    CLKOUT1_PHASE        => 0.000,
    CLKOUT1_DUTY_CYCLE   => 0.500,
    CLKOUT1_USE_FINE_PS  => FALSE,
    CLKOUT2_DIVIDE       => 14,
    CLKOUT2_PHASE        => 0.000,
    CLKOUT2_DUTY_CYCLE   => 0.500,
    CLKOUT2_USE_FINE_PS  => FALSE,
    CLKIN1_PERIOD        => 16.000 -- CLKIN1 = 62.5MHz 
)
port map(
    CLKFBOUT            => mmcm1_clkfbout,
    CLKFBOUTB           => open,
    CLKOUT0             => mmcm1_clkout0,  -- 437.5MHz
    CLKOUT0B            => open,
    CLKOUT1             => mmcm1_clkout1,  -- 62.5MHz
    CLKOUT1B            => open,
    CLKOUT2             => open, 
    CLKOUT2B            => open,     
    CLKOUT3             => open, 
    CLKOUT3B            => open,
    CLKOUT4             => open,
    CLKOUT5             => open,
    CLKOUT6             => open,
    CLKFBIN             => mmcm1_clkfbout_buf,
    CLKIN1              => ep_clk62p5,     -- endpoint clock 62.5
    CLKIN2              => local_clk62p5,  -- local clock 62.5
    CLKINSEL            => use_ep,         -- 1 = CLKIN1 = endpoint clock, 0 = CLKIN2 = local clock
    DADDR               => (others=>'0'),
    DCLK                => '0',
    DEN                 => '0',
    DI                  => (others=>'0'),
    DO                  => open,
    DRDY                => open,
    DWE                 => '0',
    PSCLK               => '0',
    PSEN                => '0',
    PSINCDEC            => '0',
    PSDONE              => open,
    LOCKED              => mmcm1_locked,
    CLKINSTOPPED        => open,
    CLKFBSTOPPED        => open,
    PWRDWN              => '0',
    RST                 => mmcm1_reset
);

mmcm1_clkfb_inst: BUFG port map( I => mmcm1_clkfbout, O => mmcm1_clkfbout_buf);

mmcm1_clk0_inst:  BUFG port map( I => mmcm1_clkout0, O => fclk); -- fast clock 437.5MHz for front end logic

mmcm1_clk1_inst:  BUFG port map( I => mmcm1_clkout1, O => mclk_i); -- master clock 62.5MHz

mclk <= mclk_i;

-- make a fake timestamp for when we're running with local clocks (use_ep=0) free running counter

fake_ts_proc: process(mclk_i)
begin
    if rising_edge(mclk_i) then
        if (reset_async='1') then
            fake_timestamp <= (others=>'0');
        else
            fake_timestamp <= std_logic_vector(unsigned(fake_timestamp) + 1);
        end if;
    end if;
end process fake_ts_proc;

-- mux and register the timestamps in the master clock domain
--
-- CDC WARNING! real_timestamp launches in ep_clk62p5 domain, but is captured in mclk domain.
-- IF the endpoint clock is selected (use_ep=1) THEN mclk and ep_clk62p5 are frequency locked.
-- BUT the phase is unknown due to routing delays and latency through MMCM1. It is possible 
-- that timestamp_reg may capture garbage here. We'll have to see and maybe make this CDC more robust...

ts_proc: process(mclk_i)
begin
    if rising_edge(mclk_i) then
        if (use_ep='1') then
            timestamp_reg <= real_timestamp; -- from endpoint
        else
            timestamp_reg <= fake_timestamp;
        end if;
    end if;
end process ts_proc;

timestamp <= timestamp_reg;

end endpoint_arch;
