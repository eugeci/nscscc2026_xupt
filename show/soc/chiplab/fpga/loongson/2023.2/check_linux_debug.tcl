if {[llength $argv] < 1 || [llength $argv] > 2} {
    error "usage: check_linux_debug.tcl PROBES_FILE ?LABEL?"
}

set probes_file [file normalize [lindex $argv 0]]
set label [expr {[llength $argv] == 2 ? [lindex $argv 1] : "snapshot"}]
if {![file exists $probes_file]} {
    error "probes file not found: $probes_file"
}

proc read_probe {name} {
    set probe [get_hw_probes $name]
    if {[llength $probe] != 1} {
        error "expected one VIO probe named $name, found [llength $probe]"
    }
    set value [get_property INPUT_VALUE $probe]
    puts "LINUX_DEBUG_PROBE $name=$value"
    return $value
}

proc hex_to_int {value} {
    if {[scan $value %x result] != 1} {
        error "cannot parse hexadecimal VIO value: $value"
    }
    return $result
}

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
open_hw_target

set device [lindex [get_hw_devices -filter {PART =~ "xc7a200t*"}] 0]
if {$device eq ""} {
    error "XC7A200T device not found on the JTAG chain"
}

current_hw_device $device
set_property PROBES.FILE $probes_file $device
set_property FULL_PROBES.FILE $probes_file $device
refresh_hw_device $device

set vios [get_hw_vios]
if {[llength $vios] != 1} {
    error "expected one VIO core, found [llength $vios]"
}
refresh_hw_vio [lindex $vios 0]

puts "LINUX_DEBUG_STATE $label"
set snapshot_raw [read_probe linux_debug_snapshot]
set exception_pc_raw [read_probe linux_first_exception_pc]
set exception_inst_raw [read_probe linux_first_exception_inst]
set crmd_raw [read_probe debug_crmd]
set badv_raw [read_probe debug_badv]
set dmw0_raw [read_probe debug_dmw0]
set dmw1_raw [read_probe debug_dmw1]
set eentry_raw [read_probe debug_eentry]
set tlbrentry_raw [read_probe debug_tlbrentry]
set arg0_raw [read_probe linux_kernel_arg0]
set arg1_raw [read_probe linux_kernel_arg1]
set arg2_raw [read_probe linux_kernel_arg2]
set arg3_raw [read_probe linux_kernel_arg3]
set pmon_context_raw [read_probe pmon_context_ptr]
set pmon_arg0_raw [read_probe pmon_context_arg0]
set pmon_arg1_raw [read_probe pmon_context_arg1]
set pmon_arg2_raw [read_probe pmon_context_arg2]
set pmon_arg3_raw [read_probe pmon_context_arg3]
set pmon_fixed_access_raw [read_probe pmon_fixed_access]
set pmon_fixed_load_arg0_raw [read_probe pmon_fixed_load_arg0]
set pmon_fixed_load_arg1_raw [read_probe pmon_fixed_load_arg1]
set pmon_fixed_load_arg2_raw [read_probe pmon_fixed_load_arg2]
set pmon_fixed_load_arg3_raw [read_probe pmon_fixed_load_arg3]
set pmon_fixed_store_arg0_raw [read_probe pmon_fixed_store_arg0]
set pmon_fixed_store_arg1_raw [read_probe pmon_fixed_store_arg1]
set pmon_fixed_store_arg2_raw [read_probe pmon_fixed_store_arg2]
set pmon_fixed_store_arg3_raw [read_probe pmon_fixed_store_arg3]
set pmon_fixed_load_dest_raw [read_probe pmon_fixed_load_dest]
set pmon_restore_gpr4_raw [read_probe pmon_restore_gpr4]
set pmon_restore_gpr5_raw [read_probe pmon_restore_gpr5]
set pmon_restore_gpr6_raw [read_probe pmon_restore_gpr6]
set pmon_restore_gpr7_raw [read_probe pmon_restore_gpr7]
set pmon_fixed_store_addr_hi_raw [read_probe pmon_fixed_store_addr_hi]
set pmon_fixed_load_addr_hi_raw [read_probe pmon_fixed_load_addr_hi]
set pmon_axi_access_raw [read_probe pmon_axi_access]
set pmon_axi_aw_addr0_raw [read_probe pmon_axi_aw_addr0]
set pmon_axi_aw_addr1_raw [read_probe pmon_axi_aw_addr1]
set pmon_axi_aw_addr2_raw [read_probe pmon_axi_aw_addr2]
set pmon_axi_aw_addr3_raw [read_probe pmon_axi_aw_addr3]
set pmon_axi_w_data0_raw [read_probe pmon_axi_w_data0]
set pmon_axi_w_data1_raw [read_probe pmon_axi_w_data1]
set pmon_axi_w_data2_raw [read_probe pmon_axi_w_data2]
set pmon_axi_w_data3_raw [read_probe pmon_axi_w_data3]
set pmon_axi_ar_addr0_raw [read_probe pmon_axi_ar_addr0]
set pmon_axi_ar_addr1_raw [read_probe pmon_axi_ar_addr1]
set pmon_axi_ar_addr2_raw [read_probe pmon_axi_ar_addr2]
set pmon_axi_ar_addr3_raw [read_probe pmon_axi_ar_addr3]
set pmon_axi_r_data0_raw [read_probe pmon_axi_r_data0]
set pmon_axi_r_data1_raw [read_probe pmon_axi_r_data1]
set pmon_axi_r_data2_raw [read_probe pmon_axi_r_data2]
set pmon_axi_r_data3_raw [read_probe pmon_axi_r_data3]
set pmon_axi_w_data4_raw [read_probe pmon_axi_w_data4]
set pmon_axi_w_data5_raw [read_probe pmon_axi_w_data5]
set pmon_axi_w_data6_raw [read_probe pmon_axi_w_data6]
set pmon_axi_w_data7_raw [read_probe pmon_axi_w_data7]
set pmon_axi_write_meta_raw [read_probe pmon_axi_write_meta]

set snapshot [hex_to_int $snapshot_raw]
set status [expr {$snapshot & 0xffff}]
set first_cause [expr {($snapshot >> 16) & 0x3f}]
set first_exception_valid [expr {($snapshot >> 22) & 1}]
set crmd [hex_to_int $crmd_raw]
set pmon_fixed_access [hex_to_int $pmon_fixed_access_raw]
set pmon_fixed_load_seen [expr {$pmon_fixed_access & 0xf}]
set pmon_fixed_store_seen [expr {($pmon_fixed_access >> 4) & 0xf}]
set pmon_restore_seen [expr {($pmon_fixed_access >> 8) & 1}]
set status_names {
    "commit_ever"
    "exception_ever"
    "fetch_valid_ever"
    "high_virtual_fetch_ever"
    "high_physical_fetch_ever"
    "dmw0_nonzero_ever"
    "dmw1_nonzero_ever"
    "crmd_pg_ever"
    "crmd_da_ever"
    "high_pc_commit_ever"
    "kernel_entry_commit_ever"
    "start_kernel_commit_ever"
    "high_pc_exception_ever"
    "pmon_go_context_seen"
    "pmon_context_matches_restore"
    "pmon_context_mismatch"
}

for {set bit 0} {$bit < [llength $status_names]} {incr bit} {
    puts "LINUX_DEBUG_BIT $bit:[lindex $status_names $bit]=[expr {($status >> $bit) & 1}]"
}
puts "LINUX_DEBUG_CRMD PG=[expr {($crmd >> 4) & 1}] DA=[expr {($crmd >> 3) & 1}]"
puts [format "LINUX_DEBUG_FIRST_EXCEPTION valid=%d cause=0x%02x pc=0x%s inst=0x%s" \
    $first_exception_valid $first_cause $exception_pc_raw $exception_inst_raw]
puts "LINUX_DEBUG_SUMMARY status=0x[format %04x $status] crmd=0x$crmd_raw badv=0x$badv_raw dmw0=0x$dmw0_raw dmw1=0x$dmw1_raw eentry=0x$eentry_raw tlbrentry=0x$tlbrentry_raw"
puts "LINUX_DEBUG_KERNEL_ARGS a0=0x$arg0_raw a1=0x$arg1_raw a2=0x$arg2_raw a3=0x$arg3_raw"
puts "LINUX_DEBUG_PMON_CONTEXT ptr=0x$pmon_context_raw a0=0x$pmon_arg0_raw a1=0x$pmon_arg1_raw a2=0x$pmon_arg2_raw a3=0x$pmon_arg3_raw expected_ptr=0x070d0b50"
puts [format "LINUX_DEBUG_PMON_FIXED access=0x%08x load_seen=0x%x store_seen=0x%x restore_seen=%d" \
    $pmon_fixed_access $pmon_fixed_load_seen $pmon_fixed_store_seen \
    $pmon_restore_seen]
puts "LINUX_DEBUG_PMON_FIXED_LOAD a0=0x$pmon_fixed_load_arg0_raw a1=0x$pmon_fixed_load_arg1_raw a2=0x$pmon_fixed_load_arg2_raw a3=0x$pmon_fixed_load_arg3_raw"
puts "LINUX_DEBUG_PMON_FIXED_STORE a0=0x$pmon_fixed_store_arg0_raw a1=0x$pmon_fixed_store_arg1_raw a2=0x$pmon_fixed_store_arg2_raw a3=0x$pmon_fixed_store_arg3_raw"
puts "LINUX_DEBUG_PMON_FIXED_DEST packed=0x$pmon_fixed_load_dest_raw"
puts "LINUX_DEBUG_PMON_RESTORE_GPRS r4=0x$pmon_restore_gpr4_raw r5=0x$pmon_restore_gpr5_raw r6=0x$pmon_restore_gpr6_raw r7=0x$pmon_restore_gpr7_raw"
puts "LINUX_DEBUG_PMON_ADDR_HI store=0x$pmon_fixed_store_addr_hi_raw load=0x$pmon_fixed_load_addr_hi_raw"
puts "LINUX_DEBUG_PMON_AXI_ACCESS value=0x$pmon_axi_access_raw"
puts "LINUX_DEBUG_PMON_AXI_AW a0=0x$pmon_axi_aw_addr0_raw a1=0x$pmon_axi_aw_addr1_raw a2=0x$pmon_axi_aw_addr2_raw a3=0x$pmon_axi_aw_addr3_raw"
puts "LINUX_DEBUG_PMON_AXI_W a0=0x$pmon_axi_w_data0_raw a1=0x$pmon_axi_w_data1_raw a2=0x$pmon_axi_w_data2_raw a3=0x$pmon_axi_w_data3_raw"
puts "LINUX_DEBUG_PMON_AXI_W_HIGH a4=0x$pmon_axi_w_data4_raw a5=0x$pmon_axi_w_data5_raw a6=0x$pmon_axi_w_data6_raw a7=0x$pmon_axi_w_data7_raw"
puts "LINUX_DEBUG_PMON_AXI_WRITE_META value=0x$pmon_axi_write_meta_raw"
puts "LINUX_DEBUG_PMON_AXI_AR a0=0x$pmon_axi_ar_addr0_raw a1=0x$pmon_axi_ar_addr1_raw a2=0x$pmon_axi_ar_addr2_raw a3=0x$pmon_axi_ar_addr3_raw"
puts "LINUX_DEBUG_PMON_AXI_R a0=0x$pmon_axi_r_data0_raw a1=0x$pmon_axi_r_data1_raw a2=0x$pmon_axi_r_data2_raw a3=0x$pmon_axi_r_data3_raw"

close_hw_manager
