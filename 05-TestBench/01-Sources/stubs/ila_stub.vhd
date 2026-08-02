library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity ila_0 is
    port (
        clk    : in std_logic;
        probe0 : in std_logic_vector(7 downto 0);
        probe1 : in std_logic_vector(0 downto 0);
        probe2 : in std_logic_vector(0 downto 0);
        probe3 : in std_logic_vector(0 downto 0);
        probe4 : in std_logic_vector(0 downto 0)
    );
end entity ila_0;

architecture stub of ila_0 is
begin
end architecture stub;

-------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity ila_2 is
    port (
        clk    : in std_logic;
        probe0 : in std_logic_vector(0 downto 0);  --! s_ftdi_rxf_n
        probe1 : in std_logic_vector(0 downto 0);  --! s_ftdi_txe_n
        probe2 : in std_logic_vector(0 downto 0);  --! s_ftdi_rd_n
        probe3 : in std_logic_vector(7 downto 0);  --! s_ftdi_adbus_in
        probe4 : in std_logic_vector(0 downto 0);  --! s_ftdi_wr_n
        probe5 : in std_logic_vector(0 downto 0);  --! s_ftdi_oe_n
        probe6 : in std_logic_vector(0 downto 0);  --! s_ftdi_adbus_oe
        probe7 : in std_logic_vector(0 downto 0);  --! s_ftdi_tx_active
        probe8 : in std_logic_vector(0 downto 0);  --! s_cmd_valid_ftdi
        probe9 : in std_logic_vector(7 downto 0)   --! s_cmd_type_ftdi
    );
end entity ila_2;

architecture stub of ila_2 is
begin
end architecture stub;