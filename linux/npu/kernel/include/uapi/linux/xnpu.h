/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef _UAPI_LINUX_XNPU_H
#define _UAPI_LINUX_XNPU_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define XNPU_ABI_VERSION	2U
#define XNPU_FRAME_WIDTH	160U
#define XNPU_FRAME_HEIGHT	120U
#define XNPU_FRAME_BYTES	(XNPU_FRAME_WIDTH * XNPU_FRAME_HEIGHT)
#define XNPU_DESC_WORDS	8U
#define XNPU_MAX_LAYERS	32U
#define XNPU_MAX_PARAMETER_BYTES	(1024U * 1024U)
#define XNPU_MAX_SCRATCH_BYTES	(512U * 1024U)
#define XNPU_MAX_RESULT_BYTES	(1024U * 1024U)
#define XNPU_MAX_INPUT_BYTES	XNPU_FRAME_BYTES

#define XNPU_RUN_USE_IRQ	(1U << 0)

#define XNPU_CAP_AXI_DMA		(1U << 0)
#define XNPU_CAP_PACKED_PRELOAD	(1U << 1)
#define XNPU_CAP_RESULT_WRITEBACK	(1U << 2)
#define XNPU_CAP_DESCRIPTOR_RAM	(1U << 3)
#define XNPU_CAP_IRQ			(1U << 4)
#define XNPU_CAP_LEGACY_MMIO		(1U << 5)

#define XNPU_INPUT_FRAME		0U
#define XNPU_INPUT_PACKED_PRELOAD	1U

#define XNPU_LAYOUT_LINEAR	0U
#define XNPU_LAYOUT_NHWC	1U
#define XNPU_LAYOUT_NCHW	2U

#define XNPU_DTYPE_U8	0U
#define XNPU_DTYPE_S8	1U
#define XNPU_DTYPE_U16	2U
#define XNPU_DTYPE_S16	3U
#define XNPU_DTYPE_U32	4U
#define XNPU_DTYPE_S32	5U

struct xnpu_info {
	__u32 abi_version;
	__u32 frame_width;
	__u32 frame_height;
	__u32 frame_bytes;
	__u32 max_layers;
	__u32 has_irq;
	__u32 reserved[2];
};

struct xnpu_descriptors {
	__u32 count;
	__u32 reserved;
	__u64 data;
};

struct xnpu_run {
	__u32 flags;
	__u32 reserved;
};

struct xnpu_result {
	__u32 timeout_ms;
	__u32 status;
	__u32 perf_cycles;
	__u16 frame_id;
	__u8 valid;
	__u8 bbox[5];
};

struct xnpu_caps {
	__u32 abi_version;
	__u32 hardware_abi;
	__u32 capabilities;
	__u32 max_layers;
	__u32 max_parameter_bytes;
	__u32 max_scratch_bytes;
	__u32 max_result_bytes;
	__u32 max_input_bytes;
	__u32 reserved[8];
};

/*
 * LOAD_MODEL atomically supplies the metadata, descriptors and parameter
 * image for the single active model.  All pointers are userspace addresses;
 * userspace never supplies a DMA/physical address.
 */
struct xnpu_model {
	__u32 flags;
	__u32 layer_count;
	__u32 input_mode;
	__u32 input_bytes;
	__u32 parameter_bytes;
	__u32 scratch_bytes;
	__u32 result_bytes;
	__u32 result_width;
	__u32 result_height;
	__u32 result_channels;
	__u32 result_layout;
	__u32 result_dtype;
	__u32 reserved[4];
	__u64 descriptors;
	__u64 parameters;
};

struct xnpu_input {
	__u32 mode;
	__u32 bytes;
	__u32 flags;
	__u32 reserved;
	__u64 data;
};

struct xnpu_result_v2 {
	__u32 timeout_ms;
	__u32 status;
	__u32 perf_cycles;
	__u32 result_status;
	__u32 result_bytes;
	__u32 result_checksum;
	__u32 result_width;
	__u32 result_height;
	__u32 result_channels;
	__u32 result_layout;
	__u32 result_dtype;
	__u32 reserved[5];
};

#define XNPU_IOC_MAGIC	'N'
#define XNPU_IOC_GET_INFO \
	_IOR(XNPU_IOC_MAGIC, 0x00, struct xnpu_info)
#define XNPU_IOC_RESET \
	_IO(XNPU_IOC_MAGIC, 0x01)
#define XNPU_IOC_LOAD_DESCRIPTORS \
	_IOW(XNPU_IOC_MAGIC, 0x02, struct xnpu_descriptors)
#define XNPU_IOC_RUN \
	_IOW(XNPU_IOC_MAGIC, 0x03, struct xnpu_run)
#define XNPU_IOC_WAIT \
	_IOWR(XNPU_IOC_MAGIC, 0x04, struct xnpu_result)
#define XNPU_IOC_QUERY_CAPS \
	_IOR(XNPU_IOC_MAGIC, 0x10, struct xnpu_caps)
#define XNPU_IOC_LOAD_MODEL \
	_IOW(XNPU_IOC_MAGIC, 0x11, struct xnpu_model)
#define XNPU_IOC_LOAD_INPUT \
	_IOW(XNPU_IOC_MAGIC, 0x12, struct xnpu_input)
#define XNPU_IOC_WAIT_V2 \
	_IOWR(XNPU_IOC_MAGIC, 0x13, struct xnpu_result_v2)

#endif /* _UAPI_LINUX_XNPU_H */
