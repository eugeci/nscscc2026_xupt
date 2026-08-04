#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
work_dir="$script_dir/.work"
openla_dir="$work_dir/openla500-src"
generated_dir="$work_dir/generated"
openla_commit="aa3bde1f3e720e71c2c78d6b81930d797b810149"
chiplab_clock_commit="ac3e7a1fa94b2a443a304b1ef3496c3df39a3b76"
chiplab_clock_path="chip/soc_demo/nscscc-team/xilinx_ip/clk_pll/clk_pll.xci"
baseline_clock_dir="$generated_dir/clk_pll"
baseline_clock_xci="$baseline_clock_dir/clk_pll.xci"

mkdir -p "$work_dir" "$generated_dir" "$baseline_clock_dir"

if [[ ! -d "$openla_dir/.git" ]]; then
    git clone https://github.com/loongson-community/open-la500.git "$openla_dir"
    git -C "$openla_dir" remote add gitee git@gitee.com:loongson-edu/open-la500.git
    git -C "$openla_dir" fetch --no-tags gitee "$openla_commit"
    git -C "$openla_dir" checkout --detach "$openla_commit"
fi

actual_commit="$(git -C "$openla_dir" rev-parse HEAD)"
if [[ "$actual_commit" != "$openla_commit" ]]; then
    echo "OpenLA500 worktree is at $actual_commit, expected $openla_commit" >&2
    exit 1
fi

openla_patch="$script_dir/patches/openla500_perf_window.patch"
openla_crlf_patch="$work_dir/openla500_perf_window.crlf.patch"
sed 's/$/\r/' "$openla_patch" > "$openla_crlf_patch"
if git -C "$openla_dir" apply --reverse --check "$openla_crlf_patch" >/dev/null 2>&1; then
    :
elif git -C "$openla_dir" apply --check "$openla_crlf_patch"; then
    git -C "$openla_dir" apply "$openla_crlf_patch"
else
    echo "OpenLA500 source is neither pristine nor already patched" >&2
    exit 1
fi

cp "$repo_root/chiplab/chip/soc_demo/nscscc-team/soc_top.v" \
   "$generated_dir/soc_top.v"
patch -s -d "$generated_dir" -p0 < "$script_dir/patches/soc_top_perf_probe.patch"

# Keep the OpenLA500 baseline at Chiplab's original 33 MHz operating point.
# The current shared clk_pll.xci belongs to the 125 MHz self-designed CPU and
# must not be reused or modified by this independent project.
git -C "$repo_root/chiplab" show \
    "$chiplab_clock_commit:$chiplab_clock_path" > "$baseline_clock_xci"
if ! grep -q '"C_CLKOUT0_ACTUAL_FREQ".*"32.72727"' "$baseline_clock_xci"; then
    echo "Historical OpenLA500 PLL is not the expected 33 MHz configuration" >&2
    exit 1
fi

echo "Prepared OpenLA500 $openla_commit"
echo "OpenLA500 source: $openla_dir"
echo "Generated SoC top: $generated_dir/soc_top.v"
echo "OpenLA500 clock: nominal 33 MHz, actual 32.72727 MHz"
echo "Independent PLL: $baseline_clock_xci"
