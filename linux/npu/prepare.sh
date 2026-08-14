#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work_dir="$script_dir/.work"
kernel_dir="$work_dir/la32r-linux"
kernel_url=${LA32R_LINUX_URL:-https://gitee.com/loongson-edu/la32r-Linux.git}
kernel_branch=la32r-new-world
kernel_commit=4ed7b98e08e8d9628f8d39a21ca8bbdd29ad8d1e

mkdir -p "$work_dir"

if [ ! -d "$kernel_dir/.git" ]; then
	git clone --depth 1 --branch "$kernel_branch" "$kernel_url" "$kernel_dir"
fi

actual_commit=$(git -C "$kernel_dir" rev-parse HEAD)
if [ "$actual_commit" != "$kernel_commit" ]; then
	echo "Unexpected la32r-Linux commit: $actual_commit" >&2
	echo "Expected: $kernel_commit" >&2
	exit 1
fi

for patch_file in "$script_dir"/patches/*.patch; do
	if git -C "$kernel_dir" apply --reverse --check "$patch_file" \
		>/dev/null 2>&1; then
		:
	else
		git -C "$kernel_dir" apply --check "$patch_file"
		git -C "$kernel_dir" apply "$patch_file"
	fi
done

install -D -m 0644 \
	"$script_dir/kernel/drivers/misc/xupt_npu.c" \
	"$kernel_dir/drivers/misc/xupt_npu.c"
install -D -m 0644 \
	"$script_dir/kernel/include/uapi/linux/xupt_npu.h" \
	"$kernel_dir/include/uapi/linux/xupt_npu.h"

dts_source="$script_dir/kernel/arch/loongarch/boot/dts/loongson/loongson32_xupt_npu.dts"
if [ "${NPU_INIT:-stage3}" = demo ]; then
	dts_source="$script_dir/kernel/arch/loongarch/boot/dts/loongson/loongson32_xupt_visionarm_npu.dts"
fi
install -D -m 0644 \
	"$dts_source" \
	"$kernel_dir/arch/loongarch/boot/dts/loongson/loongson32_xupt_npu.dts"

echo "$kernel_dir"
