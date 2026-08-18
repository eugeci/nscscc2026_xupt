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
package_dir="$repo_root/chiplab/IP/NPU/models/packages"
binary_fixture_dir="$fixture_dir/bin"
userspace_dir="$script_dir/userspace"
userspace_build="$work_dir/userspace-la32"
init_kind="${NPU_INIT:-stage3}"
visionarm_dir="$repo_root/VisionArm"
visionarm_rootfs="${VISIONARM_ROOTFS:-}"
visionarm_calibration="${VISIONARM_CALIBRATION:-}"

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

case "$init_kind" in
stage3)
	"$cc" -static -Os -Wall -Wextra \
		-I"$script_dir/kernel/include/uapi" \
		-I"$script_dir/userspace/fixture_shim" \
		-I"$fixture_dir" \
		"$script_dir/userspace/npu_smoke.c" \
		-o "$init_program"
	;;
stage4|stage5)
	make -C "$userspace_dir" BUILD_DIR="$userspace_build" \
		CC="$cc" AR="${cross_compile}ar" CFLAGS="-Os" LDFLAGS="-static" \
		all "$userspace_build/xnpu-$init_kind-smoke"
	cp "$userspace_build/xnpu-$init_kind-smoke" "$init_program"
	;;
demo)
	if [ -z "$visionarm_rootfs" ] || [ ! -d "$visionarm_rootfs" ]; then
		echo "NPU_INIT=demo requires VISIONARM_ROOTFS=<rootfs directory>" >&2
		exit 2
	fi
	if [ -n "$visionarm_calibration" ] && [ ! -f "$visionarm_calibration" ]; then
		echo "VISIONARM_CALIBRATION is not a file: $visionarm_calibration" >&2
		exit 2
	fi
	make -C "$userspace_dir" BUILD_DIR="$userspace_build" \
		CC="$cc" AR="${cross_compile}ar" CFLAGS="-Os" LDFLAGS="-static" all
	"$cc" -static -Os -Wall -Wextra \
		"$visionarm_dir/linux/snake/snake.c" -o "$work_dir/snake"
	make -C "$visionarm_dir/linux/visionarm-block" \
		BUILD_DIR="$work_dir/visionarm-block-la32" \
		CC="$cc" CFLAGS="-Os" LDFLAGS="-static" all
	make -C "$visionarm_dir/linux/visionarm-capture" \
		BUILD_DIR="$work_dir/visionarm-capture-la32" \
		CC="$cc" CFLAGS="-Os" LDFLAGS="-static" all
	;;
*)
	echo "Unknown NPU_INIT=$init_kind (expected stage3, stage4, stage5 or demo)" >&2
	exit 2
	;;
esac

{
	if [ "$init_kind" = demo ]; then
		echo "dir /vision 0555 0 0"
		echo "dir /models 0555 0 0"
		echo "dir /fixtures 0555 0 0"
		echo "file /usr/bin/arm $visionarm_dir/linux/tools/arm 0555 0 0"
		echo "file /usr/bin/cam $visionarm_dir/linux/tools/cam 0555 0 0"
		echo "file /usr/bin/lcdctl $visionarm_dir/linux/tools/lcdctl 0555 0 0"
		echo "file /usr/bin/snake $work_dir/snake 0555 0 0"
		echo "file /usr/bin/visionarm-block $work_dir/visionarm-block-la32/visionarm-block 0555 0 0"
		echo "file /usr/bin/visionarm-capture $work_dir/visionarm-capture-la32/visionarm-capture 0555 0 0"
		echo "file /usr/bin/xnpu-inspect $userspace_build/xnpu-inspect 0555 0 0"
		echo "file /usr/bin/xnpu-run $userspace_build/xnpu-run 0555 0 0"
		echo "file /usr/bin/xnpu-regress $userspace_build/xnpu-regress 0555 0 0"
		echo "file /etc/init.d/rcS $visionarm_dir/linux/rootfs/rcS 0755 0 0"
		echo "file /vision/naruto.rgb565 $visionarm_dir/linux/assets/naruto_800x480.rgb565 0444 0 0"
		if [ -n "$visionarm_calibration" ]; then
			echo "file /vision/calibration.ini $visionarm_calibration 0444 0 0"
		fi
		echo "file /models/facenet_lbp_v1.xnpu $package_dir/facenet_lbp_v1.xnpu 0444 0 0"
		echo "file /fixtures/facenet_seed42.bin $binary_fixture_dir/facenet_seed42.bin 0444 0 0"
	else
		echo "dir /dev 0755 0 0"
		echo "dir /proc 0555 0 0"
		echo "dir /sys 0555 0 0"
		echo "nod /dev/console 0600 0 0 c 5 1"
		echo "nod /dev/null 0666 0 0 c 1 3"
		echo "file /init $init_program 0755 0 0"
	fi
	if [ "$init_kind" = stage3 ]; then
		echo "file /npu_params.hex $parameter_hex 0444 0 0"
	elif [ "$init_kind" != demo ]; then
		echo "dir /models 0555 0 0"
		echo "dir /fixtures 0555 0 0"
		echo "file /models/facenet_lbp_v1.xnpu $package_dir/facenet_lbp_v1.xnpu 0444 0 0"
		echo "file /fixtures/facenet_seed42.bin $binary_fixture_dir/facenet_seed42.bin 0444 0 0"
		if [ "$init_kind" = stage5 ]; then
			echo "file /models/mnist_lenet_v1.xnpu $package_dir/mnist_lenet_v1.xnpu 0444 0 0"
			echo "file /models/npu_vgg_s1_v1.xnpu $package_dir/npu_vgg_s1_v1.xnpu 0444 0 0"
			echo "file /models/npu_vgg_s2b_v1.xnpu $package_dir/npu_vgg_s2b_v1.xnpu 0444 0 0"
			echo "file /fixtures/facenet_seed7.bin $binary_fixture_dir/facenet_seed7.bin 0444 0 0"
			echo "file /fixtures/mnist_lenet_7.bin $binary_fixture_dir/mnist_lenet_7.bin 0444 0 0"
			echo "file /fixtures/npu_vgg_s1_demo.bin $binary_fixture_dir/npu_vgg_s1_demo.bin 0444 0 0"
			echo "file /fixtures/npu_vgg_s2b_demo.bin $binary_fixture_dir/npu_vgg_s2b_demo.bin 0444 0 0"
		fi
		if [ "${NPU_INCLUDE_TOOLS:-0}" = 1 ]; then
			echo "dir /usr 0555 0 0"
			echo "dir /usr/bin 0555 0 0"
			echo "file /usr/bin/xnpu-inspect $userspace_build/xnpu-inspect 0555 0 0"
			echo "file /usr/bin/xnpu-run $userspace_build/xnpu-run 0555 0 0"
			echo "file /usr/bin/xnpu-regress $userspace_build/xnpu-regress 0555 0 0"
		fi
	fi
} > "$initramfs_list"

if [ "$init_kind" = demo ]; then
	initramfs_source="$visionarm_rootfs $initramfs_list"
else
	initramfs_source="$initramfs_list"
fi

make -C "$kernel_dir" O="$build_dir" ARCH=loongarch \
	CROSS_COMPILE="$cross_compile" la32_defconfig

"$kernel_dir/scripts/config" --file "$build_dir/.config" \
	-e XNPU \
	-e BUILTIN_DTB \
	--set-str BUILTIN_DTB_NAME loongson32_xnpu \
	-e BLK_DEV_INITRD \
	--set-str INITRAMFS_SOURCE "$initramfs_source" \
	-e DEVTMPFS \
	-e DEVTMPFS_MOUNT

# Keep cycle-accurate validation kernels small.  Demo builds retain the board
# defconfig because the interactive VisionArm rootfs may need networking and
# normal input/device support.
if [ "$init_kind" != demo ]; then
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
fi

make -C "$kernel_dir" O="$build_dir" ARCH=loongarch \
	CROSS_COMPILE="$cross_compile" olddefconfig
make -C "$kernel_dir" O="$build_dir" ARCH=loongarch \
	CROSS_COMPILE="$cross_compile" -j"${JOBS:-$(getconf _NPROCESSORS_ONLN)}" vmlinux

echo "Built $build_dir/vmlinux with NPU_INIT=$init_kind"
