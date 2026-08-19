# Build the full Chiplab Loongson SoC with the repository's LA32R core.

set script_dir [file dirname [file normalize [info script]]]
set project_file [file join $script_dir system_run.xpr]
set core_root [file normalize [file join $script_dir ../../../../myCPU]]
set debug_vio_dir [file join $script_dir ip]
set debug_vio_xci [file join $debug_vio_dir \
    linux_debug_vio13/linux_debug_vio13.xci]
set legacy_debug_vio_xci [file normalize [file join $script_dir \
    ../../../chip/soc_demo/nscscc-team/xilinx_ip/vio/vio_0.xci]]

proc collect_filelist {list_path} {
    set result {}
    set list_path [file normalize $list_path]
    set base_dir [file dirname $list_path]
    set handle [open $list_path r]
    while {[gets $handle line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string match "#*" $line] ||
            [string match "//*" $line]} {
            continue
        }
        if {[regexp {^-F[[:space:]]+(.+)$} $line -> nested]} {
            foreach source [collect_filelist [file join $base_dir $nested]] {
                lappend result $source
            }
        } else {
            lappend result [file normalize [file join $base_dir $line]]
        }
    }
    close $handle
    return $result
}

if {![file exists $project_file]} {
    error "system_run project not found: $project_file"
}
if {![file isdirectory $core_root]} {
    error "LA32R source directory not found: $core_root"
}

# The merged SoC top includes the NPU MMIO path.  Its RTL is intentionally
# maintained through the NPU file list rather than duplicated in system_run,
# so prepare those sources and definitions before adding the LA32R core.
source [file join $script_dir prepare_visionarm_npu.tcl]
open_project $project_file

# The integrated camera/VGA path uses a third 50 MHz output.  The checked-in
# XCI carries this configuration, but its generated XML/DCP may still describe
# the older two-output clock core after a merge.  Reapply the intended values
# and force regeneration so top synthesis sees clk_out3.
set clk_ip [get_ips clk_pll_33]
set_property CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 40.000 $clk_ip
set_property CONFIG.CLKOUT3_USED true $clk_ip
set_property CONFIG.CLKOUT3_REQUESTED_OUT_FREQ 50.000 $clk_ip
set clk_ip_file [get_files -quiet [get_property IP_FILE $clk_ip]]
if {[llength $clk_ip_file] != 1} {
    error "expected one clk_pll_33 IP file, found [llength $clk_ip_file]"
}
# Avoid a stale local IP-cache entry replacing the regenerated three-output
# stub with the historical two-output OOC stub.
set_property GENERATE_SYNTH_CHECKPOINT false $clk_ip_file
generate_target all $clk_ip -force

# The merged VisionArm project retains a Windows-originated source entry for
# a file that is no longer part of the design.  Remove the stale entry before
# synthesis so the LA32R build is self-contained on Linux hosts.
set stale_vga [get_files -quiet *vga_colorbar.v]
if {[llength $stale_vga] != 0} {
    remove_files $stale_vga
}

# The integrated project also carries the original OpenLA500 CPU as imported
# project sources.  soc_top now instantiates the repository core_top instead;
# leaving both implementations in sources_1 creates duplicate module names
# such as dcache/icache and can bind core_top to the wrong implementation.
set removed_openla_sources 0
foreach source [get_files -quiet -of_objects [get_filesets sources_1]] {
    set normalized_source [string map {\\ /} [file normalize $source]]
    if {[string match "*/imports/open-la500-master/*" $normalized_source]} {
        remove_files $source
        incr removed_openla_sources
    }
}
puts "REMOVED_OPENLA_SOURCE_COUNT=$removed_openla_sources"

# A generated VIO simulation netlist was once picked up as an ordinary RTL
# source by a recursive project scan.  Detach only those stale, directly added
# products before touching the intended IP.  The tracked XCI and the dedicated
# Linux VIO created below are not matched by this rule.
set removed_generated_vio_sources 0
foreach source [get_files -quiet -of_objects [get_filesets sources_1]] {
    set source_tail [file tail $source]
    if {[regexp -nocase {vio.*_(sim_netlist|stub)\.(v|vhdl)$} \
            $source_tail]} {
        puts "REMOVING_STALE_VIO_SOURCE=$source"
        remove_files $source
        incr removed_generated_vio_sources
    }
}
puts "REMOVED_STALE_VIO_SOURCE_COUNT=$removed_generated_vio_sources"

# Earlier board diagnostics reused the team VIO. The Linux bring-up probes now
# have a dedicated IP, so do not make this build depend on that generated IP.
set legacy_debug_vio_file [get_files -quiet $legacy_debug_vio_xci]
if {[llength $legacy_debug_vio_file] == 1} {
    remove_files $legacy_debug_vio_file
}

set existing_debug_vio [get_ips -quiet linux_debug_vio13]
if {[llength $existing_debug_vio] == 0} {
    if {[file exists $debug_vio_xci]} {
        add_files -fileset sources_1 -norecurse $debug_vio_xci
    } else {
        file mkdir $debug_vio_dir
        create_ip -name vio -vendor xilinx.com -library ip -version 3.0 \
            -module_name linux_debug_vio13 -dir $debug_vio_dir
    }
}

set core_sources [concat \
    [glob -nocomplain [file join $core_root *.sv]] \
    [glob -nocomplain [file join $core_root *.v]]]
if {[llength $core_sources] == 0} {
    error "no LA32R RTL sources found in: $core_root"
}
foreach source $core_sources {
    if {![file exists $source]} {
        error "core source not found: $source"
    }
    if {[regexp -nocase {vio.*\.(v|sv|vhdl)$} [file tail $source]]} {
        error "generated VIO source must not appear in core filelist: $source"
    }
}

add_files -fileset sources_1 -norecurse $core_sources
set debug_vio_ip [get_ips -quiet linux_debug_vio13]
if {[llength $debug_vio_ip] != 1} {
    error "expected one linux_debug_vio13 IP, found [llength $debug_vio_ip]"
}
set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN {56} \
    CONFIG.C_NUM_PROBE_OUT {0} \
    CONFIG.C_PROBE_IN0_WIDTH {32} \
    CONFIG.C_PROBE_IN1_WIDTH {32} \
    CONFIG.C_PROBE_IN2_WIDTH {32} \
    CONFIG.C_PROBE_IN3_WIDTH {32} \
    CONFIG.C_PROBE_IN4_WIDTH {32} \
    CONFIG.C_PROBE_IN5_WIDTH {32}] $debug_vio_ip
set_property -dict [list \
    CONFIG.C_PROBE_IN6_WIDTH {32} \
    CONFIG.C_PROBE_IN7_WIDTH {32} \
    CONFIG.C_PROBE_IN8_WIDTH {32}] $debug_vio_ip
set_property -dict [list \
    CONFIG.C_PROBE_IN9_WIDTH {32} \
    CONFIG.C_PROBE_IN10_WIDTH {32} \
    CONFIG.C_PROBE_IN11_WIDTH {32} \
    CONFIG.C_PROBE_IN12_WIDTH {32}] $debug_vio_ip
set_property -dict [list \
    CONFIG.C_PROBE_IN13_WIDTH {32} \
    CONFIG.C_PROBE_IN14_WIDTH {32} \
    CONFIG.C_PROBE_IN15_WIDTH {32} \
    CONFIG.C_PROBE_IN16_WIDTH {32} \
    CONFIG.C_PROBE_IN17_WIDTH {32} \
    CONFIG.C_PROBE_IN18_WIDTH {32} \
    CONFIG.C_PROBE_IN19_WIDTH {32} \
    CONFIG.C_PROBE_IN20_WIDTH {32} \
    CONFIG.C_PROBE_IN21_WIDTH {32} \
    CONFIG.C_PROBE_IN22_WIDTH {32} \
    CONFIG.C_PROBE_IN23_WIDTH {32} \
    CONFIG.C_PROBE_IN24_WIDTH {32} \
    CONFIG.C_PROBE_IN25_WIDTH {32} \
    CONFIG.C_PROBE_IN26_WIDTH {32} \
    CONFIG.C_PROBE_IN27_WIDTH {32} \
    CONFIG.C_PROBE_IN28_WIDTH {32} \
    CONFIG.C_PROBE_IN29_WIDTH {32} \
    CONFIG.C_PROBE_IN30_WIDTH {32} \
    CONFIG.C_PROBE_IN31_WIDTH {32} \
    CONFIG.C_PROBE_IN32_WIDTH {32} \
    CONFIG.C_PROBE_IN33_WIDTH {32} \
    CONFIG.C_PROBE_IN34_WIDTH {32} \
    CONFIG.C_PROBE_IN35_WIDTH {32} \
    CONFIG.C_PROBE_IN36_WIDTH {32} \
    CONFIG.C_PROBE_IN37_WIDTH {32} \
    CONFIG.C_PROBE_IN38_WIDTH {32} \
    CONFIG.C_PROBE_IN39_WIDTH {32} \
    CONFIG.C_PROBE_IN40_WIDTH {32} \
    CONFIG.C_PROBE_IN41_WIDTH {32} \
    CONFIG.C_PROBE_IN42_WIDTH {32} \
    CONFIG.C_PROBE_IN43_WIDTH {32} \
    CONFIG.C_PROBE_IN44_WIDTH {32} \
    CONFIG.C_PROBE_IN45_WIDTH {32} \
    CONFIG.C_PROBE_IN46_WIDTH {32} \
    CONFIG.C_PROBE_IN47_WIDTH {32} \
    CONFIG.C_PROBE_IN48_WIDTH {32} \
    CONFIG.C_PROBE_IN49_WIDTH {32} \
    CONFIG.C_PROBE_IN50_WIDTH {32} \
    CONFIG.C_PROBE_IN51_WIDTH {32} \
    CONFIG.C_PROBE_IN52_WIDTH {32} \
    CONFIG.C_PROBE_IN53_WIDTH {32} \
    CONFIG.C_PROBE_IN54_WIDTH {32} \
    CONFIG.C_PROBE_IN55_WIDTH {32}] $debug_vio_ip
# A packaged XCIX may retain generated HDL from the previous probe count even
# after its CONFIG properties change.  Invalidate all managed products so the
# synthesis stub is rebuilt from the current XCI; generated HDL is still never
# added directly to sources_1.
reset_target all $debug_vio_ip
generate_target all $debug_vio_ip
foreach source $core_sources {
    if {[string equal -nocase [file extension $source] ".sv"]} {
        set_property FILE_TYPE SystemVerilog [get_files $source]
    }
}
update_compile_order -fileset sources_1
puts "LA32R_SOURCE_COUNT=[llength $core_sources]"

set debug_vio_run [get_runs -quiet linux_debug_vio13_synth_1]
if {[llength $debug_vio_run] == 0} {
    # A merged project may retain the VIO as a core container without an
    # associated OOC synthesis run.  Regenerating the IP targets does not
    # recreate that run automatically, so create it before launching.
    create_ip_run $debug_vio_ip
    set debug_vio_run [get_runs -quiet linux_debug_vio13_synth_1]
}
if {[llength $debug_vio_run] != 1} {
    error "expected one linux_debug_vio13 synthesis run, found [llength $debug_vio_run]"
}

# The merged project contains the AXI clock converter as an XCIX container.
# Its extracted XCI is intentionally not tracked, so a checkout can retain a
# stale OOC run while having no usable top-level output product.  Rebuild that
# checkpoint and the debug VIO explicitly before top synthesis instead of
# relying on the local Vivado cache or on launch_runs synth_1 to notice them.
set required_ooc_runs [list \
    $debug_vio_run \
    [get_runs -quiet axi_clock_converter_0_synth_1]]
foreach required_run $required_ooc_runs {
    if {[llength $required_run] != 1} {
        error "required OOC synthesis run is missing: $required_run"
    }
    reset_run $required_run
}
launch_runs $required_ooc_runs -jobs 6
foreach required_run $required_ooc_runs {
    wait_on_run $required_run
    if {[get_property PROGRESS $required_run] ne "100%"} {
        error "OOC synthesis did not complete: $required_run: [get_property STATUS $required_run]"
    }
}

reset_run synth_1
reset_run impl_1
launch_runs synth_1 -jobs 6
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "synthesis did not complete: [get_property STATUS [get_runs synth_1]]"
}

launch_runs impl_1 -jobs 6 -to_step write_bitstream
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "implementation did not complete: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $script_dir la32r_linux_timing_summary.rpt]
report_utilization -file [file join $script_dir la32r_linux_utilization.rpt]
puts "LA32R_LINUX_BITSTREAM=[file join $script_dir \
    system_run.runs/impl_1/soc_top.bit]"
