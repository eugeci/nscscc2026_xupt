/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef _UAPI_LINUX_XUPT_NPU_H
#define _UAPI_LINUX_XUPT_NPU_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define XUPT_NPU_ABI_VERSION	1U
#define XUPT_NPU_FRAME_WIDTH	160U
#define XUPT_NPU_FRAME_HEIGHT	120U
#define XUPT_NPU_FRAME_BYTES	(XUPT_NPU_FRAME_WIDTH * XUPT_NPU_FRAME_HEIGHT)
#define XUPT_NPU_DESC_WORDS	8U
#define XUPT_NPU_MAX_LAYERS	32U

#define XUPT_NPU_RUN_USE_IRQ	(1U << 0)

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

#endif /* _UAPI_LINUX_XUPT_NPU_H */

