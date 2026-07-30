#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
kernel_dir=$("$script_dir/prepare.sh")
work_dir="$script_dir/.work"
build_dir="$work_dir/build"
rootfs_dir="$work_dir/rootfs"
init_program="$rootfs_dir/init"
initramfs_list="$work_dir/initramfs.list"
fixture_dir="$repo_root/chiplab/IP/NPU/models/fixtures"
parameter_hex="$repo_root/chiplab/IP/NPU/params/npu_params.hex"

if [ -n "${CROSS_COMPILE:-}" ]; then
	cross_compile=$CROSS_COMPILE
else
	toolchain_bin="$repo_root/chiplab/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin"
	cross_compile="$toolchain_bin/loongarch32r-linux-gnusf-"
fi

cc="${cross_compile}gcc"
if ! command -v "$cc" >/dev/null 2>&1; then
	echo "LA32R compiler not found: $cc" >&2
	echo "Set CROSS_COMPILE to the compiler prefix." >&2
	exit 1
fi

mkdir -p "$build_dir" "$rootfs_dir"

"$cc" -static -Os -Wall -Wextra \
	-I"$script_dir/kernel/include/uapi" \
	-I"$script_dir/userspace/fixture_shim" \
	-I"$fixture_dir" \
	"$script_dir/userspace/npu_smoke.c" \
	-o "$init_program"

{
	echo "dir /dev 0755 0 0"
	echo "dir /proc 0555 0 0"
	echo "dir /sys 0555 0 0"
	echo "nod /dev/console 0600 0 0 c 5 1"
	echo "nod /dev/null 0666 0 0 c 1 3"
	echo "file /init $init_program 0755 0 0"
	echo "file /npu_params.hex $parameter_hex 0444 0 0"
} > "$initramfs_list"

make -C "$kernel_dir" O="$build_dir" ARCH=loongarch \
	CROSS_COMPILE="$cross_compile" la32_defconfig

"$kernel_dir/scripts/config" --file "$build_dir/.config" \
	-e XUPT_NPU \
	-e BUILTIN_DTB \
	--set-str BUILTIN_DTB_NAME loongson32_xupt_npu \
	-e BLK_DEV_INITRD \
	--set-str INITRAMFS_SOURCE "$initramfs_list" \
	-e DEVTMPFS \
	-e DEVTMPFS_MOUNT

# Keep the cycle-accurate OpenLA500 validation kernel small.  The upstream
# board defconfig enables unrelated storage, network and multimedia stacks.
"$kernel_dir/scripts/config" --file "$build_dir/.config" \
	-e EMBEDDED \
	-e EXPERT \
	-d MODULES \
	-d BLOCK \
	-d NET \
	-d CGROUPS \
	-d NAMESPACES \
	-d BPF_SYSCALL \
	-d PERF_EVENTS \
	-d SYSVIPC \
	-d POSIX_MQUEUE \
	-d AIO \
	-d IO_URING \
	-d SECCOMP \
	-d MTD \
	-d SCSI \
	-d ATA \
	-d INPUT \
	-d HID \
	-d RC_CORE \
	-d IPMI_HANDLER \
	-d POWER_SUPPLY \
	-d HWMON \
	-d PPS \
	-d NVMEM \
	-d EXT2_FS \
	-d EXT4_FS \
	-d XFS_FS \
	-d BTRFS_FS \
	-d NTFS_FS \
	-d NLS \
	-d KEYS \
	-d SECURITY \
	-d CRYPTO \
	-d DNOTIFY \
	-d INOTIFY_USER \
	-d FANOTIFY \
	-d KALLSYMS \
	-d DEBUG_INFO \
	-d IKCONFIG \
	-d IKCONFIG_PROC

make -C "$kernel_dir" O="$build_dir" ARCH=loongarch \
	CROSS_COMPILE="$cross_compile" olddefconfig
make -C "$kernel_dir" O="$build_dir" ARCH=loongarch \
	CROSS_COMPILE="$cross_compile" -j"${JOBS:-$(getconf _NPROCESSORS_ONLN)}" vmlinux

echo "Built $build_dir/vmlinux"
