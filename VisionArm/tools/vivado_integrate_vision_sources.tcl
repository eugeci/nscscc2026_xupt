# Normalize the camera/video/terminal RTL as ordinary Vivado design sources.
# Run from the Tcl Console while system_run.xpr is open:
#   source C:/Users/HP/Documents/Codex/2026-07-31/d-longarch-nscscc2026-xupt-chiplab-fpga/tools/vivado_integrate_vision_sources.tcl

if {[current_project -quiet] eq ""} {
    error "No Vivado project is open. Open system_run.xpr first."
}

set project_dir [get_property DIRECTORY [current_project]]
set soc_dir [file normalize [file join $project_dir .. .. .. chip soc_demo loongson]]
set top_file [file join $soc_dir soc_top.v]

set vision_sources [list \
    ov5640_init_rom.v \
    ov5640_sccb_master.v \
    axis_test_frame_source.v \
    ov5640_axis_capture.v \
    camera_vdma_s2mm_init.v \
    axis_video_2x_scaler.v \
    axis_linebuffer_vga.v \
    ov5640_vga_bridge.v \
    camera_vdma_subsystem.v \
    uart_vga_terminal.v]

if {![file exists $top_file]} {
    error "soc_top.v was not found: $top_file"
}
foreach name $vision_sources {
    set path [file join $soc_dir $name]
    if {![file exists $path]} {
        error "Required RTL file was not found: $path"
    }
}

# Keep a recoverable copy before touching the working top file.
set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set backup_dir [file join $soc_dir .backup_source_integration_$stamp]
file mkdir $backup_dir
file copy -force $top_file [file join $backup_dir soc_top.v]
set project_file [file join $project_dir "[get_property NAME [current_project]].xpr"]
if {[file exists $project_file]} {
    file copy -force $project_file [file join $backup_dir [file tail $project_file]]
}

# These .v files were previously text-included, which made Vivado classify them
# as "Verilog Header".  Keep config.h included, but compile module files normally.
set fh [open $top_file rb]
set top_text [read $fh]
close $fh

set removed 0
foreach name $vision_sources {
    foreach ending [list "\r\n" "\n"] {
        set include_line "`include \"$name\"$ending"
        if {[string first $include_line $top_text] >= 0} {
            set top_text [string map [list $include_line ""] $top_text]
            incr removed
        }
    }
}

set fh [open $top_file wb]
puts -nonewline $fh $top_text
close $fh

set fs [get_filesets sources_1]
foreach name $vision_sources {
    set path [file normalize [file join $soc_dir $name]]
    set obj [get_files -quiet $path]
    if {[llength $obj] == 0} {
        add_files -fileset sources_1 -norecurse $path
        set obj [get_files -quiet $path]
    }
    set_property FILE_TYPE Verilog $obj
    set_property USED_IN_SYNTHESIS true $obj
    set_property USED_IN_SIMULATION true $obj
}

set_property top soc_top $fs
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts ""
puts "VISION_SOURCE_INTEGRATION_OK"
puts "Project : [get_property NAME [current_project]]"
puts "Top     : [get_property top $fs]"
puts "Removed : $removed textual .v include line(s)"
puts "Backup  : $backup_dir"
puts ""
foreach name $vision_sources {
    set obj [get_files -quiet [file normalize [file join $soc_dir $name]]]
    puts [format "%-28s  %-16s" $name [get_property FILE_TYPE $obj]]
}
puts ""
puts "In the Sources pane select the Hierarchy tab, then expand soc_top."
