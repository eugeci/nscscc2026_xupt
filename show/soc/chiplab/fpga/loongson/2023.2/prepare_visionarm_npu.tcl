# Add the XUPT NPU sources and build-time definitions to the checked-in
# VisionArm/OpenLA500 Vivado project.  Run from any directory with:
#   vivado -mode batch -source prepare_visionarm_npu.tcl

set script_dir [file dirname [file normalize [info script]]]
set project_file [file join $script_dir system_run.xpr]
set npu_root [file normalize [file join $script_dir ../../../IP/NPU]]
set npu_filelist [file join $npu_root filelists npu_soc_wrapper.f]
set mycpu_root [file normalize [file join $script_dir ../../../../myCPU]]
set debug_vio_dir [file join $script_dir ip]
set debug_vio_xci [file join $debug_vio_dir \
    linux_debug_vio13 linux_debug_vio13.xci]
set debug_vio_xcix [file join $debug_vio_dir linux_debug_vio13.xcix]

if {![file exists $project_file]} {
    error "VisionArm project not found: $project_file"
}
if {![file exists $npu_filelist]} {
    error "NPU file list not found: $npu_filelist"
}
if {![file isdirectory $mycpu_root]} {
    error "MMU CPU source directory not found: $mycpu_root"
}

open_project $project_file

# The MMU/Linux soc_top contains the bring-up snapshot probes.  A pristine
# VisionArm project does not yet contain their VIO, so preparing only the CPU
# and NPU sources leaves linux_debug_vio13 unresolved during elaboration.
set debug_vio_ip [get_ips -quiet linux_debug_vio13]
if {[llength $debug_vio_ip] == 0} {
    if {[file exists $debug_vio_xcix]} {
        add_files -fileset sources_1 -norecurse $debug_vio_xcix
    } elseif {[file exists $debug_vio_xci]} {
        add_files -fileset sources_1 -norecurse $debug_vio_xci
    } else {
        file mkdir $debug_vio_dir
        create_ip -name vio -vendor xilinx.com -library ip -version 3.0 \
            -module_name linux_debug_vio13 -dir $debug_vio_dir
    }
    set debug_vio_ip [get_ips -quiet linux_debug_vio13]
}
if {[llength $debug_vio_ip] != 1} {
    error "expected one linux_debug_vio13 IP, found [llength $debug_vio_ip]"
}
set debug_vio_config [list \
    CONFIG.C_NUM_PROBE_IN {56} \
    CONFIG.C_NUM_PROBE_OUT {0}]
for {set probe 0} {$probe < 56} {incr probe} {
    lappend debug_vio_config "CONFIG.C_PROBE_IN${probe}_WIDTH" 32
}
set_property -dict $debug_vio_config $debug_vio_ip
reset_target all $debug_vio_ip
generate_target all $debug_vio_ip

# This checked-in project originally embeds an OpenLA500 source tree.  Merely
# updating IP/myCPU does not replace those files, so the FPGA build would keep
# using OpenLA500 while the Chiplab simulation used the MMU core.  Remove the
# embedded CPU (including its private cache IPs) before adding the selected
# IP/myCPU implementation below.
set old_cpu_files {}
set old_cpu_ip_names [list \
    data_bank_sram.xci data_bank_sram.xcix \
    tagv_sram.xci tagv_sram.xcix \
    sram_32x52bit.xci sram_32x52bit.xcix \
    sram_128x22.xci sram_128x22.xcix \
    sram_128x32.xci sram_128x32.xcix \
    sram_128x64.xci sram_128x64.xcix]
# Core-container IPs keep their generated XCI in a child fileset, so inspect
# every project fileset rather than only sources_1.  Otherwise the OpenLA500
# data/tag RAM IPs survive even after their top-level XCIX is removed.
foreach source [get_files -of_objects [get_filesets]] {
    set normalized_source [string map {\\ /} [file normalize $source]]
    set source_tail [file tail $normalized_source]
    if {[string first "/open-la500-master/" $normalized_source] >= 0 ||
        $source_tail in $old_cpu_ip_names} {
        lappend old_cpu_files $source
    }
}
if {[llength $old_cpu_files] == 0} {
    puts "WARNING: no embedded OpenLA500 files were found to remove"
} else {
    puts "Removing [llength $old_cpu_files] embedded OpenLA500 files"
    remove_files $old_cpu_files
}

proc add_files_from_filelist {filelist_path} {
    set filelist_path [file normalize $filelist_path]
    if {![file exists $filelist_path]} {
        error "RTL file list not found: $filelist_path"
    }

    set base_dir [file dirname $filelist_path]
    set fp [open $filelist_path r]
    while {[gets $fp line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string match "//*" $line] ||
            [string match "#*" $line]} {
            continue
        }
        if {[regexp {^-F\s+(.+)$} $line -> nested_filelist]} {
            add_files_from_filelist [file join $base_dir $nested_filelist]
            continue
        }
        if {[string match "+incdir+*" $line] ||
            [regexp {^-v\s+} $line]} {
            puts "WARNING: skipping unsupported file-list option: $line"
            continue
        }

        set source_path [file normalize [file join $base_dir $line]]
        if {![file exists $source_path]} {
            close $fp
            error "RTL source not found: $source_path"
        }
        add_files -norecurse $source_path
    }
    close $fp
}

set mycpu_sources [concat \
    [glob -nocomplain [file join $mycpu_root *.sv]] \
    [glob -nocomplain [file join $mycpu_root *.v]]]
if {[llength $mycpu_sources] == 0} {
    error "no MMU CPU RTL sources found in: $mycpu_root"
}
add_files -norecurse $mycpu_sources

set fp [open $npu_filelist r]
set npu_sources {}
while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line] ||
        [string match "+incdir+*" $line]} {
        continue
    }
    set source_path [file normalize [file join [file dirname $npu_filelist] $line]]
    if {![file exists $source_path]} {
        close $fp
        error "NPU source not found: $source_path"
    }
    lappend npu_sources $source_path
}
close $fp

add_files -norecurse $npu_sources
set_property include_dirs \
    [concat [get_property include_dirs [current_fileset]] \
            [file join $npu_root rtl core include]] \
    [current_fileset]

set npu_defines [list \
    "NPU_PARAMS_HEX=\"[file join $npu_root params npu_params.hex]\"" \
    "MICROCODE_FILE=\"[file join $npu_root sim microcode_face.hex]\"" \
    "NPU_DESC_FILE=\"[file join $npu_root sim npu_desc.hex]\"" \
    "NPU_AXI_DMA_ENABLE" \
    "NO_VCD_DUMP" \
]
set_property verilog_define \
    [concat [get_property verilog_define [current_fileset]] $npu_defines] \
    [current_fileset]

set_property top soc_top [current_fileset]
update_compile_order -fileset sources_1

if {[info exists ::env(VISIONARM_NPU_RTL_CHECK)] &&
    [string tolower $::env(VISIONARM_NPU_RTL_CHECK)] in {1 y yes true}} {
    generate_target all [get_ips]
    # synth_design -rtl does not launch out-of-context IP runs on its own.
    # Build the IP checkpoints so the top-level interconnect, clocking, DDR,
    # video and debug modules all resolve during this optional elaboration.
    set ip_runs {}
    foreach ip [get_ips] {
        set run_name "[get_property NAME $ip]_synth_1"
        set ip_run [get_runs -quiet $run_name]
        if {[llength $ip_run] == 0} {
            create_ip_run $ip
            set ip_run [get_runs -quiet $run_name]
        }
        if {[llength $ip_run] != 1} {
            error "expected one synthesis run for [get_property NAME $ip]"
        }
        reset_run $ip_run
        lappend ip_runs $ip_run
    }
    launch_runs $ip_runs -jobs 4
    foreach ip_run $ip_runs {
        wait_on_run $ip_run
        if {[get_property PROGRESS $ip_run] ne "100%"} {
            error "IP synthesis failed: [get_property NAME $ip_run]"
        }
    }
    synth_design -rtl -name visionarm_npu_rtl -top soc_top \
        -part xc7a200tfbg676-2
    close_design
}

close_project

puts "VisionArm project prepared with the selected MMU CPU and XUPT NPU DMA support."
