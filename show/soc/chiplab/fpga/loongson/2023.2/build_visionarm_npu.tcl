# Reproducible synthesis, implementation, reports, and bitstream flow for the
# merged VisionArm/OpenLA500 + NPU demo on xc7a200tfbg676-2.
#
# Run from any directory:
#   vivado -mode batch -source build_visionarm_npu.tcl

set script_dir [file dirname [file normalize [info script]]]
set project_file [file join $script_dir system_run.xpr]
set output_dir [file join $script_dir visionarm_npu_output]

# Add the NPU RTL and its build definitions to the checked-in project.
source [file join $script_dir prepare_visionarm_npu.tcl]
open_project $project_file

# Remove an unused source entry left by the Windows-originated project.
set stale_vga [get_files -quiet *vga_colorbar.v]
if {[llength $stale_vga] != 0} {
    remove_files $stale_vga
}

# The merged CPU/peripheral/NPU design is congestion-limited at 50 MHz.
# Keep the CPU conservative and give VGA an independent 50 MHz source; the
# VGA timing generators divide it by two for a 25 MHz 640x480 pixel cadence.
set clk_ip [get_ips clk_pll_33]
set_property CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 40.000 $clk_ip
set_property CONFIG.CLKOUT3_USED true $clk_ip
set_property CONFIG.CLKOUT3_REQUESTED_OUT_FREQ 50.000 $clk_ip
# Force regeneration only for the IP changed above.  Unconditionally forcing
# every unrelated IP also rebuilds MIG templates and makes iterative builds
# vulnerable to an otherwise harmless MIG generator failure.
generate_target all $clk_ip -force
generate_target all [get_ips]
export_ip_user_files -of_objects [get_ips] -no_script -sync -force -quiet

# Build out-of-context IP checkpoints serially to limit host memory use.
set ooc_runs [get_runs -filter {IS_SYNTHESIS == 1 && NAME != "synth_1"}]
foreach run $ooc_runs {
    reset_run $run
    launch_runs $run -jobs 1
    wait_on_run $run
    set status [get_property STATUS $run]
    puts "=== OOC $run: $status ==="
    if {![string match -nocase "*complete*" $status] &&
        ![string match -nocase "*cached*" $status]} {
        error "OOC synthesis failed: $run ($status)"
    }
}

reset_run synth_1
launch_runs synth_1 -jobs 1
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "=== TOP SYNTHESIS STATUS: $synth_status ==="
if {![string match "*Complete*" $synth_status]} {
    error "Top-level synthesis failed: $synth_status"
}

set_property strategy "Vivado Implementation Defaults" [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED false [get_runs impl_1]
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 1
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "=== IMPLEMENTATION STATUS: $impl_status ==="
if {![string match "*Complete*" $impl_status]} {
    error "Implementation failed: $impl_status"
}

file mkdir $output_dir
open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 20 -input_pins \
    -file [file join $output_dir post_route_timing_summary.rpt]
report_utilization -hierarchical \
    -file [file join $output_dir post_route_utilization.rpt]
report_drc -file [file join $output_dir post_route_drc.rpt]
report_methodology -file [file join $output_dir post_route_methodology.rpt]
write_checkpoint -force \
    [file join $output_dir visionarm_npu_soc_top_routed.dcp]
write_bitstream -force \
    [file join $output_dir visionarm_npu_soc_top.bit]

set final_wns [get_property SLACK \
    [get_timing_paths -delay_type max -max_paths 1]]
puts "=== FINAL WNS: $final_wns ns ==="
if {$final_wns < 0.0} {
    error "Post-route timing is not met: WNS=$final_wns ns"
}

close_project
