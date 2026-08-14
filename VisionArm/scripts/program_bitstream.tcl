if {[llength $argv] != 1} {
    error "usage: program_bitstream.tcl BIT_FILE"
}

set bit_file [file normalize [lindex $argv 0]]
if {![file exists $bit_file]} {
    error "bitstream not found: $bit_file"
}

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
open_hw_target

set device ""
foreach candidate [get_hw_devices] {
    if {[string match -nocase "xc7a200t*" [get_property PART $candidate]]} {
        set device $candidate
        break
    }
}
if {$device eq ""} {
    error "XC7A200T device not found on the JTAG chain"
}

current_hw_device $device
refresh_hw_device $device
set_property PROGRAM.FILE $bit_file $device
program_hw_devices $device
refresh_hw_device $device
puts "PROGRAMMED: $device <- $bit_file"
close_hw_manager
