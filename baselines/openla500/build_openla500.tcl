set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_file [file join $repo_root chiplab fpga nscscc-team run_vivado \
                       project_openla500 openla500.xpr]

open_project $project_file
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set run_status [get_property STATUS [get_runs impl_1]]
if {![string match "write_bitstream Complete*" $run_status]} {
    error "OpenLA500 implementation failed: $run_status"
}

open_run impl_1
set report_dir [file dirname $project_file]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir openla500_timing_summary.rpt]
report_utilization -file [file join $report_dir openla500_utilization.rpt]
puts "OpenLA500 bitstream complete"
