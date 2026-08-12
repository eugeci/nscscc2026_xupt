set chip_root {D:/longarch/nscscc2026_xupt/chiplab}
set uart_rtl [file join $chip_root chip soc_demo loongson arm_uart_tx.v]

if {[current_project] eq ""} {
    error "No Vivado project is open. Open fpga/loongson/2023.2/system_run.xpr first."
}
if {![file exists $uart_rtl]} {
    error "Missing UART RTL file: $uart_rtl"
}
if {[llength [get_files -quiet $uart_rtl]] == 0} {
    add_files -norecurse $uart_rtl
}
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "ARM_UART_APPLIED"
puts "Top module: [get_property top [get_filesets sources_1]]"
puts "UART TX pin: J15-4 / T19, 9600 baud"
puts "CPU register: 0x1fd0e010, read bit 8 = busy, write bits 7:0 = byte"
