set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set chiplab_root [file join $repo_root chiplab]
set run_dir [file join $chiplab_root fpga nscscc-team run_vivado]
set project_path [file join $run_dir project_openla500]
set project_part xc7a200tfbg676-2
set openla_root [file join $script_dir .work openla500-src]
set generated_root [file join $script_dir .work generated]

if {![file exists [file join $openla_root mycpu_top.v]]} {
    error "Run baselines/openla500/prepare.sh before creating the project"
}

create_project -force openla500 $project_path -part $project_part

set soc_root [file join $chiplab_root chip soc_demo nscscc-team]
set original_soc_top [file join $soc_root soc_top.v]
add_files -scan_for_includes $soc_root
# The shared source tree contains generated simulation netlists and OOC DCPs
# from the existing project. They must not become top-level synthesis sources
# in this independent project; the corresponding XCI files are added below.
set generated_ip_root [file normalize [file join $soc_root xilinx_ip]]
foreach source_file [get_files -quiet] {
    set normalized_file [file normalize $source_file]
    if {[string first $generated_ip_root $normalized_file] == 0} {
        remove_files $source_file
    }
}
remove_files [get_files -quiet $original_soc_top]
add_files -norecurse [file join $generated_root soc_top.v]

add_files -scan_for_includes [file join $chiplab_root IP AXI_SRAM_BRIDGE]
add_files -scan_for_includes [file join $chiplab_root IP APB_DEV URT]
add_files -norecurse [file join $chiplab_root IP APB_DEV apb_dev_top_no_nand.v]
add_files -norecurse [file join $chiplab_root IP APB_DEV apb_mux2.v]
add_files -norecurse [file join $chiplab_root IP AMBA axi2apb.v]

add_files -quiet [glob -nocomplain [file join $soc_root xilinx_ip * *.xci]]
add_files -fileset sim_1 [file join $chiplab_root fpga nscscc-team testbench]

# The pinned OpenLA500 source already implements Chiplab's core_top contract.
add_files -scan_for_includes $openla_root
add_files -quiet [glob -nocomplain [file join $openla_root IP *.xcix]]

# OpenLA500's BRAM generators were packaged with Vivado 2019.1. Upgrade only
# these ignored baseline copies for Vivado 2023.2; shared SoC IP is untouched.
set openla_ips [get_ips -quiet -regexp {^(tagv_sram|data_bank_sram)$}]
if {[llength $openla_ips] != 0} {
    upgrade_ip -quiet $openla_ips
    generate_target all $openla_ips
}

proc add_files_from_filelist {filelist_path {base_dir ""}} {
    set filelist_path [file normalize $filelist_path]
    if {$base_dir eq ""} {
        set base_dir [file dirname $filelist_path]
    } else {
        set base_dir [file normalize $base_dir]
    }
    set fp [open $filelist_path r]
    while {[gets $fp line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string match "//*" $line] || [string match "#*" $line]} {
            continue
        }
        if {[regexp {^-F\s+(.+)$} $line -> sub_filelist]} {
            add_files_from_filelist [file normalize [file join $base_dir $sub_filelist]]
            continue
        }
        if {[regexp {^\+incdir\+} $line] || [regexp {^-v} $line]} {
            continue
        }
        set abs_file [file normalize [file join $base_dir $line]]
        if {[file exists $abs_file]} {
            add_files -norecurse $abs_file
        }
    }
    close $fp
}

set npu_root [file join $chiplab_root IP NPU]
add_files_from_filelist [file join $npu_root filelists npu_soc_wrapper.f]
set npu_include_dir [file join $npu_root rtl core include]
set_property include_dirs \
    [concat [get_property include_dirs [current_fileset]] $npu_include_dir] \
    [current_fileset]
set npu_defines [list \
    "NPU_PARAMS_HEX=\"[file join $npu_root params npu_params.hex]\"" \
    "MICROCODE_FILE=\"[file join $npu_root sim microcode_face.hex]\"" \
    "NPU_DESC_FILE=\"[file join $npu_root sim npu_desc.hex]\"" \
]
set_property verilog_define \
    [concat [get_property verilog_define [current_fileset]] $npu_defines] \
    [current_fileset]

add_files -fileset constrs_1 -quiet \
    [file join $chiplab_root fpga nscscc-team constraints]

set_property top soc_top [current_fileset]
set_property top tb_top [get_filesets sim_1]
set_property {xsim.simulate.log_all_signals} true [get_filesets sim_1]
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_Explore [get_runs impl_1]

update_compile_order -fileset sources_1
puts "Created independent OpenLA500 project: $project_path/openla500.xpr"
