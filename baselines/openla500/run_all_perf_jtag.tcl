set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_dir [file join $repo_root chiplab fpga nscscc-team run_vivado \
                      project_openla500]
set probes_file [file join $project_dir openla500.runs impl_1 debug_nets.ltx]
set result_file [file join $script_dir openla500_perf_results.csv]
set timeout_ms 120000
set poll_ms 100
# Chiplab's historical OpenLA500 PLL requests 33 MHz.  With the original
# MMCM settings (100 MHz * 18 / 55), its implemented output is 32.72727 MHz.
set cpu_nominal_mhz 33.0
set cpu_hz [expr {100000000.0 * 18.0 / 55.0}]
set cpu_actual_mhz [expr {$cpu_hz / 1000000.0}]
set soc_hz 100000000.0

set test_names {
    bitcount bubble_sort coremark crc32 dhrystone quick_sort select_sort sha
    stream_copy stringsearch fireye_A0 fireye_B2 fireye_C0 fireye_D1
    fireye_I2 inner_product lookup_table loop_induction my_memcmp
    minmax_sequence
}

proc probe_hex {probe_name} {
    set raw [get_property INPUT_VALUE [get_hw_probes $probe_name]]
    scan $raw %x value
    return $value
}

proc axi_read32 {axi address suffix} {
    set txn_name "openla_read_${suffix}"
    create_hw_axi_txn $txn_name $axi -address $address -type read
    run_hw_axi $txn_name
    set raw [lindex [report_hw_axi_txn $txn_name] 1]
    delete_hw_axi_txn $txn_name
    scan $raw %x value
    return $value
}

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
open_hw_target
set device [lindex [get_hw_devices] 0]
current_hw_device $device
set_property PROBES.FILE $probes_file $device
set_property FULL_PROBES.FILE $probes_file $device
refresh_hw_device $device

set vio [lindex [get_hw_vios] 0]
set axi [lindex [get_hw_axis] 0]
set reset_probe [get_hw_probes resetn_vio]
set switch_probe [get_hw_probes switch_vio]
set instret_probe [get_hw_probes perf_instret_count]

if {[llength $instret_probe] != 1} {
    error "perf_instret_count VIO probe was not found"
}

set outfile [open $result_file w]
puts $outfile "test_id,test_name,switch_value,result,cpu_clock_nominal_mhz,cpu_clock_actual_mhz,wall_wait_ms,cpu_cycles,cpu_cycle_time_ms,soc_cycles,test_time_ms,retired_instructions,ipc"
flush $outfile

puts [format \
    "OpenLA500 baseline clock: nominal %.3f MHz, implemented %.6f MHz" \
    $cpu_nominal_mhz $cpu_actual_mhz]

for {set test_id 1} {$test_id <= 20} {incr test_id} {
    set test_name [lindex $test_names [expr {$test_id - 1}]]
    set switch_value [expr {0x7f - $test_id}]
    set_property OUTPUT_VALUE [format %02x $switch_value] $switch_probe
    commit_hw_vio $switch_probe

    set_property OUTPUT_VALUE 0 $reset_probe
    commit_hw_vio $reset_probe
    after 100
    set_property OUTPUT_VALUE 1 $reset_probe
    commit_hw_vio $reset_probe

    set start_ms [clock milliseconds]
    set timed_out 0
    while {1} {
        after $poll_ms
        refresh_hw_vio $vio
        set led [probe_hex led_OBUF]
        set led_rg0 [probe_hex led_rg0_OBUF]
        set led_rg1 [probe_hex led_rg1_OBUF]
        set elapsed_ms [expr {[clock milliseconds] - $start_ms}]
        if {$led_rg1 == 1 && ($led_rg0 == 1 || $led_rg0 == 2)} {
            break
        }
        if {$elapsed_ms >= $timeout_ms} {
            set timed_out 1
            break
        }
    }

    if {$timed_out} {
        set result TIMEOUT
    } elseif {$led == 0xffff && $led_rg0 == 1 && $led_rg1 == 1} {
        set result PASS
    } elseif {$led == 0 && $led_rg0 == 2 && $led_rg1 == 1} {
        set result FAIL
    } else {
        set result UNKNOWN
    }

    refresh_hw_vio $vio
    set retired [probe_hex perf_instret_count]
    set cpu_cycles [axi_read32 $axi 1faf8000 "${test_id}_cpu"]
    set soc_cycles [axi_read32 $axi 1faf8010 "${test_id}_soc"]
    set cpu_time_ms [expr {1000.0 * double($cpu_cycles) / $cpu_hz}]
    set soc_time_ms [expr {1000.0 * double($soc_cycles) / $soc_hz}]
    set ipc [expr {$cpu_cycles == 0 ? 0.0 : double($retired) / double($cpu_cycles)}]

    puts $outfile [format "%d,%s,0x%02x,%s,%.3f,%.6f,%d,%u,%.6f,%u,%.6f,%u,%.9f" \
        $test_id $test_name $switch_value $result \
        $cpu_nominal_mhz $cpu_actual_mhz $elapsed_ms \
        $cpu_cycles $cpu_time_ms $soc_cycles $soc_time_ms $retired $ipc]
    flush $outfile

    puts [format "RESULT %02d/20 %-16s %-7s time=%9.3fms cycles=%10u inst=%10u IPC=%.6f" \
        $test_id $test_name $result $soc_time_ms $cpu_cycles $retired $ipc]
}

close $outfile
puts "OpenLA500 baseline complete: $result_file"
close_hw_manager
