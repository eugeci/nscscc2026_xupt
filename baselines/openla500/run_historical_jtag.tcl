# Program the unmodified historical Chiplab/OpenLA500 33 MHz project, then run
# each performance benchmark as an independent image.  This script is test and
# observation automation; it does not create or alter the Vivado project.

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set historical_root [file join $script_dir .work chiplab-ac3e7a1]
if {[info exists ::env(OPENLA_HISTORICAL_ROOT)]} {
    set historical_root [file normalize $::env(OPENLA_HISTORICAL_ROOT)]
}
set impl_dir [file join $historical_root fpga nscscc-team run_vivado \
                  project loongson.runs impl_1]
set bitstream [file join $impl_dir soc_top.bit]
set probes_file [file join $impl_dir debug_nets.ltx]
set benchmark_root [file join $repo_root chiplab software examples \
                         nscscc_perf obj]
set result_file [file join $script_dir openla500_perf_results.csv]

set timeout_ms 120000
set poll_ms 100
set cpu_clock_nominal_mhz 33.0
set cpu_hz [expr {100000000.0 * 18.0 / 55.0}]
set cpu_clock_actual_mhz [expr {$cpu_hz / 1000000.0}]
set soc_hz 100000000.0
set has_instret 1
if {[info exists ::env(OPENLA_HAS_INSTRET)]} {
    set has_instret $::env(OPENLA_HAS_INSTRET)
}

# Binary loads are intentionally verbose; keep the terminal focused on one
# result line per benchmark.
set_msg_config -id {Labtoolstcl 44-481} -suppress

set test_names {
    bitcount bubble_sort coremark crc32 dhrystone quick_sort select_sort sha
    stream_copy stringsearch fireye_A0 fireye_B2 fireye_C0 fireye_D1
    fireye_I2 inner_product lookup_table loop_induction my_memcmp
    minmax_sequence
}
if {[info exists ::env(OPENLA_TEST_NAMES)]} {
    set test_names $::env(OPENLA_TEST_NAMES)
}
if {[info exists ::env(OPENLA_RESULT_FILE)]} {
    set result_file [file normalize $::env(OPENLA_RESULT_FILE)]
}

proc axi_write32 {axi address data suffix} {
    set txn_name "openla_write_${suffix}"
    create_hw_axi_txn $txn_name $axi -address $address -data $data -type write
    run_hw_axi $txn_name
    delete_hw_axi_txn $txn_name
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

proc load_binary {axi binary_path test_id} {
    set fp [open $binary_path rb]
    fconfigure $fp -translation binary
    set address_dec 469762048
    set chunk_size 1024
    set chunk_index 0

    while {![eof $fp]} {
        set data [read $fp $chunk_size]
        set data_len [string length $data]
        if {$data_len == 0} {
            break
        }
        if {$data_len % 4 != 0} {
            close $fp
            error "Benchmark image is not word aligned: $binary_path"
        }

        set words [list]
        for {set byte_index 0} {$byte_index < $data_len} {incr byte_index 4} {
            set word_bytes [string range $data $byte_index \
                                [expr {$byte_index + 3}]]
            binary scan $word_bytes B* binary_data
            set bytes [list]
            for {set bit_index 0} {$bit_index < 32} {incr bit_index 8} {
                set byte_bits [string range $binary_data $bit_index \
                                   [expr {$bit_index + 7}]]
                lappend bytes [expr "0b$byte_bits"]
            }
            lappend words [format "%02X%02X%02X%02X" \
                [lindex $bytes 3] [lindex $bytes 2] \
                [lindex $bytes 1] [lindex $bytes 0]]
        }

        # Vivado's burst-data string is ordered from the highest beat down.
        set burst_data [join [lreverse $words] "_"]
        set txn_name "openla_load_${test_id}_${chunk_index}"
        create_hw_axi_txn $txn_name $axi \
            -address [format "%08x" $address_dec] \
            -len [expr {$data_len / 4}] -type write -data $burst_data
        run_hw_axi $txn_name
        delete_hw_axi_txn $txn_name

        incr address_dec $data_len
        incr chunk_index
    }
    close $fp
}

if {![file exists $bitstream]} {
    error "OpenLA500 bitstream not found: $bitstream"
}

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag

set target ""
for {set retry 0} {$retry < 20} {incr retry} {
    refresh_hw_server
    set targets [get_hw_targets]
    if {[llength $targets] != 0} {
        set target [lindex $targets 0]
        break
    }
    after 500
}
if {$target eq ""} {
    error "No JTAG target was enumerated; check board power and USB/JTAG cable"
}
current_hw_target $target
open_hw_target $target

set devices [get_hw_devices]
if {[llength $devices] == 0} {
    error "No JTAG hardware device was found"
}
set device [lindex $devices 0]
current_hw_device $device
set_property PROGRAM.FILE $bitstream $device
if {[file exists $probes_file]} {
    set_property PROBES.FILE $probes_file $device
    set_property FULL_PROBES.FILE $probes_file $device
}
program_hw_devices $device

# DDR calibration must complete before the JTAG AXI master is released.
set axi ""
for {set retry 0} {$retry < 20} {incr retry} {
    refresh_hw_device $device
    set axes [get_hw_axis]
    if {[llength $axes] != 0} {
        set axi [lindex $axes 0]
        break
    }
    after 50
}
if {$axi eq ""} {
    error "JTAG AXI master did not become available after programming"
}

set outfile [open $result_file w]
puts $outfile "test_id,test_name,result,simu_flag,cpu_clock_nominal_mhz,cpu_clock_actual_mhz,wall_wait_ms,cpu_cycles,cpu_cycle_time_ms,soc_cycles,test_time_ms,retired_instructions,ipc"
flush $outfile

puts [format "OPENLA500 clock nominal=%.3fMHz implemented=%.6fMHz" \
    $cpu_clock_nominal_mhz $cpu_clock_actual_mhz]
puts "OPENLA500 result_file=$result_file"

for {set test_id 1} {$test_id <= [llength $test_names]} {incr test_id} {
    set test_name [lindex $test_names [expr {$test_id - 1}]]
    set binary_path [file join $benchmark_root $test_name inst_data.bin]
    if {![file exists $binary_path]} {
        close $outfile
        error "Benchmark image not found: $binary_path"
    }

    # Reprogram before every benchmark after the first one.  This isolates a
    # CPU/interconnect hang in one workload from every following workload.
    if {$test_id > 1} {
        program_hw_devices $device
        set axi ""
        for {set retry 0} {$retry < 20} {incr retry} {
            refresh_hw_device $device
            set axes [get_hw_axis]
            if {[llength $axes] != 0} {
                set axi [lindex $axes 0]
                break
            }
            after 50
        }
        if {$axi eq ""} {
            close $outfile
            error "JTAG AXI master did not recover for test $test_name"
        }
    }

    set simu_flag [axi_read32 $axi 1fafff20 "${test_id}_simu_flag"]
    puts [format "LOAD %02d/20 %-16s SIMU_FLAG=%u %s" \
        $test_id $test_name $simu_flag $binary_path]

    # The historical JTAG wrapper recognizes these two write addresses as
    # assert/release commands for CPU and confreg reset.
    axi_write32 $axi 80000000 00000000 "${test_id}_reset_assert"
    after 100
    load_binary $axi $binary_path $test_id
    axi_write32 $axi 40000000 00000000 "${test_id}_reset_release"

    set start_ms [clock milliseconds]
    set timed_out 0
    set led 0
    set led_rg0 0
    set led_rg1 0
    set axi_error 0
    set elapsed_ms 0
    while {1} {
        after $poll_ms
        if {[catch {
            set led [axi_read32 $axi 1faff020 "${test_id}_led"]
            set led_rg0 [axi_read32 $axi 1faff030 "${test_id}_rg0"]
            set led_rg1 [axi_read32 $axi 1faff040 "${test_id}_rg1"]
        } axi_message]} {
            set elapsed_ms [expr {[clock milliseconds] - $start_ms}]
            set axi_error 1
            break
        }
        set elapsed_ms [expr {[clock milliseconds] - $start_ms}]

        if {$led_rg1 == 1 && ($led_rg0 == 1 || $led_rg0 == 2)} {
            # Software updates RG1/RG0 before the final LED value.  Let those
            # writes drain, then take one stable completion snapshot.
            after 20
            if {[catch {
                set led [axi_read32 $axi 1faff020 "${test_id}_led_final"]
                set led_rg0 [axi_read32 $axi 1faff030 "${test_id}_rg0_final"]
                set led_rg1 [axi_read32 $axi 1faff040 "${test_id}_rg1_final"]
            } axi_message]} {
                set elapsed_ms [expr {[clock milliseconds] - $start_ms}]
                set axi_error 1
            }
            break
        }
        if {$elapsed_ms >= $timeout_ms} {
            set timed_out 1
            break
        }
    }

    if {$axi_error} {
        set result AXI_ERROR
    } elseif {$timed_out} {
        set result TIMEOUT
    } elseif {$led == 0xffff && $led_rg0 == 1 && $led_rg1 == 1} {
        set result PASS
    } elseif {$led == 0 && $led_rg0 == 2 && $led_rg1 == 1} {
        set result FAIL
    } else {
        set result UNKNOWN
    }

    # CR0/CR1 are written by the unchanged benchmark software. CR2 is the
    # observation-only retired-instruction counter added in the baseline RTL.
    after 10
    set cpu_cycles 0
    set soc_cycles 0
    set retired 0
    if {!$axi_error} {
        if {[catch {
            set cpu_cycles [axi_read32 $axi 1faf8000 "${test_id}_cpu"]
            set soc_cycles [axi_read32 $axi 1faf8010 "${test_id}_soc"]
            if {$has_instret} {
                set retired [axi_read32 $axi 1faf8020 "${test_id}_instret"]
            }
        } counter_message]} {
            set result AXI_ERROR
            set cpu_cycles 0
            set soc_cycles 0
            set retired 0
        }
    }
    set cpu_time_ms [expr {1000.0 * double($cpu_cycles) / $cpu_hz}]
    set test_time_ms [expr {1000.0 * double($soc_cycles) / $soc_hz}]
    if {$has_instret} {
        set ipc [format "%.9f" [expr {$cpu_cycles == 0 ? 0.0 : \
                         double($retired) / double($cpu_cycles)}]]
    } else {
        set ipc "NA"
    }

    puts $outfile [format \
        "%d,%s,%s,%u,%.3f,%.6f,%d,%u,%.6f,%u,%.6f,%u,%s" \
        $test_id $test_name $result $simu_flag $cpu_clock_nominal_mhz \
        $cpu_clock_actual_mhz $elapsed_ms $cpu_cycles $cpu_time_ms \
        $soc_cycles $test_time_ms $retired $ipc]
    flush $outfile

    puts [format \
        "RESULT %02d/20 %-16s %-7s time=%9.3fms cycles=%10u inst=%10u IPC=%s" \
        $test_id $test_name $result $test_time_ms $cpu_cycles $retired $ipc]
}

close $outfile
puts "OPENLA500 baseline complete: $result_file"
close_hw_manager
