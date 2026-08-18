set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_dir [file join $repo_root chiplab fpga nscscc-team run_vivado \
                      project_openla500]
set bit_file [file join $project_dir openla500.runs impl_1 soc_top.bit]
set probes_file [file join $project_dir openla500.runs impl_1 debug_nets.ltx]
set bin_file_name [file join $repo_root chiplab software examples nscscc_perf \
                        obj allbench inst_data.bin]

foreach required [list $bit_file $probes_file $bin_file_name] {
    if {![file exists $required]} {
        error "Required file not found: $required"
    }
}

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
open_hw_target
set device [lindex [get_hw_devices] 0]
current_hw_device $device
set_property PROGRAM.FILE $bit_file $device
set_property PROBES.FILE $probes_file $device
set_property FULL_PROBES.FILE $probes_file $device
program_hw_devices $device
refresh_hw_device $device

set vio [lindex [get_hw_vios] 0]
set axi [lindex [get_hw_axis] 0]
set reset_probe [get_hw_probes resetn_vio]
set_property OUTPUT_VALUE 0 $reset_probe
commit_hw_vio $reset_probe

set bin_file [open $bin_file_name rb]
fconfigure $bin_file -translation binary
set address 0x1c000000
set chunk_size 1024
set bytes_written 0

while {![eof $bin_file]} {
    set data [read $bin_file $chunk_size]
    set data_len [string length $data]
    if {$data_len == 0} {
        break
    }
    if {$data_len % 4 != 0} {
        append data [string repeat "\x00" [expr {4 - ($data_len % 4)}]]
        set data_len [string length $data]
    }

    set words {}
    for {set i 0} {$i < $data_len} {incr i 4} {
        binary scan [string range $data $i [expr {$i + 3}]] cu4 bytes
        lappend words [format "%02X%02X%02X%02X" \
            [lindex $bytes 3] [lindex $bytes 2] [lindex $bytes 1] [lindex $bytes 0]]
    }
    set burst_data [join [lreverse $words] _]
    set txn_name [format "openla_load_%08x" $address]
    create_hw_axi_txn $txn_name $axi -address [format %08x $address] \
        -len [llength $words] -type write -data $burst_data
    run_hw_axi $txn_name
    delete_hw_axi_txn $txn_name
    incr address $data_len
    incr bytes_written $data_len
}

close $bin_file
puts "Loaded $bytes_written bytes at 0x1c000000; CPU remains in VIO reset"
close_hw_manager

