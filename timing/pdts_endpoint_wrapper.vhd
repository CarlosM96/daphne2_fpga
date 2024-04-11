-- pdts_endpoint_wrapper.vhd
-- Jamieson Olsen <jamieson@fnal.gov>
--
-- cleanup and hide the pdts specific stuff, no external PLL, no system control bus
-- static control bus, hide all the other stuff we're not using on DAPHNE...

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

use work.pdts_defs.all;
use work.pdts_ep_defs.all;
use work.pdts_clock_defs.all;

entity pdts_endpoint_wrapper is -- for DAPHNE V2a design
	port(
		sys_clk: in std_logic; -- System clock is 100MHz
		sys_rst: in std_logic; -- System reset (sclk domain)
        sys_addr: in std_logic_vector(15 downto 0); 
		sys_stat: out std_logic_vector(3 downto 0); -- Status output (sclk domain)
		los: in std_logic := '0'; -- External signal path status (async)
		rxd: in std_logic; -- Timing input (clk domain)
		txd: out std_logic; -- Timing output (clk domain)
		txenb: out std_logic; -- Timing output enable (active low for SFP) (clk domain)
		clk: out std_logic; -- Base clock output is 62.5MHz
		rst: out std_logic; -- Base clock reset (clk domain)
		ready: out std_logic; -- Endpoint ready flag (clk domain)
		tstamp: out std_logic_vector(63 downto 0); -- Timestamp (clk domain)
		sync: out std_logic_vector(7 downto 0); 
		sync_stb: out std_logic
	);
end pdts_endpoint_wrapper;

architecture pdts_endpoint_wrapper_arch of pdts_endpoint_wrapper is

component pdts_endpoint is
	generic(
		SCLK_FREQ: real := 50.0; -- Frequency (MHz) of the system clock
		USE_EXT_PLL: boolean := false; -- Use external PLL or clock source
		EXT_PLL_DIV: positive := 2; -- External PLL division ratio
		FORCE_TX: boolean := false; -- Turn on transmit permanently
		SKIP_FREQ: boolean := false; -- Skip the frequency check step (e.g. for simulation)
		EXT_ADDR: boolean := true; -- Skip the address setting step
		SKIP_DESKEW: boolean := true; -- Skip the phase adjustment step
		SKIP_TSTAMP: boolean := false -- Skip the timestamp initialisation step
	);
	port(
		sys_clk: in std_logic; -- System clock
		sys_rst: in std_logic; -- System reset (sclk domain)
		sys_addr: in std_logic_vector(15 downto 0) := X"FFF0"; -- Address of the endpoint until overridden via control bus
--		sys_ctrl_in: in pdts_cmo := PDTS_CMO_NULL; -- System control bus (sclk domain)
--		sys_ctrl_out: out pdts_cmi;
		sys_stat: out std_logic_vector(3 downto 0); -- Status output (sclk domain)
		ctrl_out: out pdts_cmo; -- Control bus (clk domain)
		ctrl_in: in pdts_cmi := PDTS_CMI_NULL;
		pll_clko: out std_logic; -- Clock to external PLL
		pll_clki: in std_logic := '0'; -- Externally produced clock
		los: in std_logic := '0'; -- External signal path status (async)
		rxd: in std_logic; -- Timing input (clk domain)
		txd: out std_logic; -- Timing output (clk domain)
		txenb: out std_logic; -- Timing output enable (active low for SFP) (clk domain)
		clk: out std_logic; -- Base clock output
		rst: out std_logic; -- Base clock reset (clk domain)
		clk2x: out std_logic; -- 2x clock output
		clk4x: out std_logic; -- 4x clock output
		ready: out std_logic; -- Endpoint ready flag (clk domain)
		tstamp: out std_logic_vector(63 downto 0); -- Timestamp (clk domain)
		sync: out std_logic_vector(7 downto 0); -- Sync command output (clk domain)
		sync_stb: out std_logic -- Sync command strobe (clk domain)
	);
end component;

begin

pdts_endpoint_inst: pdts_endpoint
	generic map(
		SCLK_FREQ => 100.0, -- Frequency (MHz) of the system clock
		USE_EXT_PLL => false, -- Use external PLL or clock source
		--EXT_PLL_DIV => 2. -- External PLL division ratio, not used
		FORCE_TX => false, -- Turn on transmit permanently, don't do this....!
		SKIP_FREQ => false, -- Skip the frequency check step (e.g. for simulation)
		EXT_ADDR => true, -- Skip the address setting step
		SKIP_DESKEW => true, -- Skip the phase adjustment step
		SKIP_TSTAMP => false )
	port map(
		sys_clk => sys_clk, -- System clock
		sys_rst => sys_rst, -- System reset (sclk domain)
		sys_stat => sys_stat, -- Status output (sclk domain)
		los => los, -- External signal path status (async)
		rxd => rxd, -- Timing input (clk domain)
		txd => txd, -- Timing output (clk domain)
		txenb => txenb, -- Timing output enable (active low for SFP) (clk domain)
		clk => clk, -- Base clock output
		rst => rst, -- Base clock reset (clk domain)
		ready => ready, -- Endpoint ready flag (clk domain)
		tstamp => tstamp, -- Timestamp (clk domain)

        -- extra stuff not used here, tie it off or ignore it...

        -- sys_ctrl_in: in pdts_cmo := PDTS_CMO_NULL; -- System control bus (sclk domain)
        -- sys_ctrl_out: out pdts_cmi;
		sys_addr => sys_addr, -- Address of the endpoint until overridden via control bus
	    ctrl_out => open, -- Control bus (clk domain)
		ctrl_in => PDTS_CMI_NULL,
		pll_clko => open, -- Clock to external PLL
		pll_clki => '0', -- Externally produced clock
		clk2x => open, -- 2x clock output
		clk4x => open, -- 4x clock output
		sync => sync, -- Sync command output (clk domain) ----- WARNING -----
		sync_stb => sync_stb -- Sync command strobe (clk domain) ---- WARNING ---
	);

end pdts_endpoint_wrapper_arch;
