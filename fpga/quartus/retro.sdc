# retro.sdc -- timing for the DE0-Nano retro console top (50 MHz in, gated core clock).
create_clock -name sys_clk -period 20.000 [get_ports CLOCK_50]
derive_clock_uncertainty

# The core clock is sys_clk gated by an ALTCLKCTRL cell; same frequency.
# Target pin verified in the TimeQuest Tcl console (Quartus 20.1, fitted
# netlist). NOTE: in get_pins patterns each '*' matches within ONE hierarchy
# level only, so a short 'tail' pattern like *|clkctrl1|outclk matches nothing
# here -- the full 5-level path is required. There are 3 clkctrls in the
# design (CLOCK_50~inputclkctrl, core_rst~clkctrl, core_clk_buf), so the
# exact name matters: it must resolve to exactly this one pin.
create_generated_clock -name core_clk -source [get_ports CLOCK_50] \
    -divide_by 1 [get_pins {mem|core_clk_buf|auto_generated|clkctrl1|outclk}]

# Async inputs: both are synchronized in fabric before use.
set_false_path -from [get_ports {KEY[*] UART_RX}] -to [get_registers *]

# LED and UART_TX outputs have no timing requirement (megahertz at most).
set_false_path -from [get_registers *] -to [get_ports {LED[*] UART_TX}]
