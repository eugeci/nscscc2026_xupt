#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
run_dir="$repo_root/chiplab/fpga/nscscc-team/run_vivado"
vivado_bin="${VIVADO:-/home/eugeci/Xilinx/Vivado/2023.2/bin/vivado}"

if [[ ! -x "$vivado_bin" ]]; then
    echo "Vivado executable not found: $vivado_bin" >&2
    echo "Set VIVADO=/path/to/vivado and retry" >&2
    exit 1
fi

"$script_dir/prepare.sh"

cd "$run_dir"
"$vivado_bin" -mode batch -source "$script_dir/create_project_openla500.tcl"
"$vivado_bin" -mode batch -source "$script_dir/build_openla500.tcl"
