/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef _UAPI_LINUX_XUPT_NPU_H
#define _UAPI_LINUX_XUPT_NPU_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define XUPT_NPU_ABI_VERSION	2U
#define XUPT_NPU_FRAME_WIDTH	160U
#define XUPT_NPU_FRAME_HEIGHT	120U
#define XUPT_NPU_FRAME_BYTES	(XUPT_NPU_FRAME_WIDTH * XUPT_NPU_FRAME_HEIGHT)
#define XUPT_NPU_DESC_WORDS	8U
#define XUPT_NPU_MAX_LAYERS	32U
#define XUPT_NPU_MAX_PARAMETER_BYTES	(1024U * 1024U)
#define XUPT_NPU_MAX_SCRATCH_BYTES	(512U * 1024U)
#define XUPT_NPU_MAX_RESULT_BYTES	(1024U * 1024U)
#define XUPT_NPU_MAX_INPUT_BYTES	XUPT_NPU_FRAME_BYTES

#define XUPT_NPU_RUN_USE_IRQ	(1U << 0)

#define XUPT_NPU_CAP_AXI_DMA		(1U << 0)
#define XUPT_NPU_CAP_PACKED_PRELOAD	(1U << 1)
#define XUPT_NPU_CAP_RESULT_WRITEBACK	(1U << 2)
#define XUPT_NPU_CAP_DESCRIPTOR_RAM	(1U << 3)
#define XUPT_NPU_CAP_IRQ			(1U << 4)
#define XUPT_NPU_CAP_LEGACY_MMIO		(1U << 5)

#define XUPT_NPU_INPUT_FRAME		0U
#define XUPT_NPU_INPUT_PACKED_PRELOAD	1U

#define XUPT_NPU_LAYOUT_LINEAR	0U
#define XUPT_NPU_LAYOUT_NHWC	1U
#define XUPT_NPU_LAYOUT_NCHW	2U

#define XUPT_NPU_DTYPE_U8	0U
#define XUPT_NPU_DTYPE_S8	1U
#define XUPT_NPU_DTYPE_U16	2U
#define XUPT_NPU_DTYPE_S16	3U
#define XUPT_NPU_DTYPE_U32	4U
#define XUPT_NPU_DTYPE_S32	5U

struct xupt_npu_info {
	__u32 abi_version;
	__u32 frame_width;
	__u32 frame_height;
	__u32 frame_bytes;
	__u32 max_layers;
	__u32 has_irq;
	__u32 reserved[2];
};

struct xupt_npu_descriptors {
	__u32 count;
	__u32 reserved;
	__u64 data;
};

struct xupt_npu_run {
	__u32 flags;
	__u32 reserved;
};

struct xupt_npu_result {
	__u32 timeout_ms;
	__u32 status;
	__u32 perf_cycles;
	__u16 frame_id;
	__u8 valid;
	__u8 bbox[5];
};

struct xupt_npu_caps {
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
struct xupt_npu_model {
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

struct xupt_npu_input {
	__u32 mode;
	__u32 bytes;
	__u32 flags;
	__u32 reserved;
	__u64 data;
};

struct xupt_npu_result_v2 {
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

#define XUPT_NPU_IOC_MAGIC	'N'
#define XUPT_NPU_IOC_GET_INFO \
	_IOR(XUPT_NPU_IOC_MAGIC, 0x00, struct xupt_npu_info)
#define XUPT_NPU_IOC_RESET \
	_IO(XUPT_NPU_IOC_MAGIC, 0x01)
#define XUPT_NPU_IOC_LOAD_DESCRIPTORS \
	_IOW(XUPT_NPU_IOC_MAGIC, 0x02, struct xupt_npu_descriptors)
#define XUPT_NPU_IOC_RUN \
	_IOW(XUPT_NPU_IOC_MAGIC, 0x03, struct xupt_npu_run)
#define XUPT_NPU_IOC_WAIT \
	_IOWR(XUPT_NPU_IOC_MAGIC, 0x04, struct xupt_npu_result)
#define XUPT_NPU_IOC_QUERY_CAPS \
	_IOR(XUPT_NPU_IOC_MAGIC, 0x10, struct xupt_npu_caps)
#define XUPT_NPU_IOC_LOAD_MODEL \
	_IOW(XUPT_NPU_IOC_MAGIC, 0x11, struct xupt_npu_model)
#define XUPT_NPU_IOC_LOAD_INPUT \
	_IOW(XUPT_NPU_IOC_MAGIC, 0x12, struct xupt_npu_input)
#define XUPT_NPU_IOC_WAIT_V2 \
	_IOWR(XUPT_NPU_IOC_MAGIC, 0x13, struct xupt_npu_result_v2)

#endif /* _UAPI_LINUX_XUPT_NPU_H */
