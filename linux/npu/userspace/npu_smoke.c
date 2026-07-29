// SPDX-License-Identifier: GPL-2.0
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <unistd.h>

#include <linux/xupt_npu.h>

#define FACENET_NUM_LAYERS 10U

static const uint32_t facenet_descriptors[FACENET_NUM_LAYERS][XUPT_NPU_DESC_WORDS] = {
	{ 0x00103322, 0x00122001, 0x00080001, 0x007800a0,
	  0x003c0050, 0x00000000, 0x00000240, 0x00000008 },
	{ 0x00103322, 0x00122001, 0x00100008, 0x003c0050,
	  0x001e0028, 0x00000251, 0x00000491, 0x00000008 },
	{ 0x00101122, 0x00000000, 0x00100010, 0x001e0028,
	  0x001e0028, 0x000004a2, 0x000004e2, 0x00000006 },
	{ 0x00103322, 0x00122001, 0x00180010, 0x001e0028,
	  0x000f0014, 0x000004f3, 0x00000973, 0x00000008 },
	{ 0x00103322, 0x00122001, 0x00200018, 0x000f0014,
	  0x0007000a, 0x00000994, 0x00001294, 0x00000009 },
	{ 0x00101122, 0x00000000, 0x00200020, 0x0007000a,
	  0x0007000a, 0x000012b5, 0x000013b5, 0x00000006 },
	{ 0x00103322, 0x00122001, 0x00200020, 0x0007000a,
	  0x00030005, 0x000013d6, 0x00001cd6, 0x00000008 },
	{ 0x00102222, 0x00000001, 0x00200020, 0x00030005,
	  0x00040006, 0x00001cf7, 0x000020f7, 0x00000007 },
	{ 0x01101111, 0x00000000, 0x00400300, 0x00010001,
	  0x00010001, 0x00002118, 0x00005118, 0x00000007 },
	{ 0x01401111, 0x00000000, 0x00050040, 0x00010001,
	  0x00010001, 0x00005159, 0x00005259, 0x00000004 },
};

static uint8_t test_frame[XUPT_NPU_FRAME_BYTES];

static void fill_test_frame(void)
{
	uint32_t x;
	uint32_t y;

	for (y = 0; y < XUPT_NPU_FRAME_HEIGHT; ++y) {
		for (x = 0; x < XUPT_NPU_FRAME_WIDTH; ++x) {
			uint32_t index = y * XUPT_NPU_FRAME_WIDTH + x;

			test_frame[index] =
				(uint8_t)((x * 3U + y * 5U + (x ^ y)) & 0xffU);
		}
	}
}

static void finish_forever(void)
{
	for (;;)
		sleep(3600);
}

static void fail(const char *operation)
{
	printf("NPU_LINUX_FAIL operation=%s errno=%d (%s)\n",
	       operation, errno, strerror(errno));
	fflush(stdout);
	finish_forever();
}

int main(void)
{
	struct xupt_npu_descriptors descriptors;
	struct xupt_npu_result result;
	struct xupt_npu_info info;
	struct xupt_npu_run run;
	ssize_t written;
	int fd;

	setvbuf(stdout, NULL, _IONBF, 0);
	printf("NPU Linux smoke start\n");

	if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) < 0 &&
	    errno != EBUSY)
		fail("mount_devtmpfs");

	fd = open("/dev/xupt-npu", O_RDWR);
	if (fd < 0)
		fail("open");

	if (ioctl(fd, XUPT_NPU_IOC_GET_INFO, &info) < 0)
		fail("get_info");

	printf("npu abi=%u frame=%ux%u bytes=%u max_layers=%u irq=%u\n",
	       info.abi_version, info.frame_width, info.frame_height,
	       info.frame_bytes, info.max_layers, info.has_irq);

	if (info.abi_version != XUPT_NPU_ABI_VERSION ||
	    info.frame_bytes != XUPT_NPU_FRAME_BYTES) {
		errno = EPROTO;
		fail("abi_check");
	}

	if (ioctl(fd, XUPT_NPU_IOC_RESET) < 0)
		fail("reset");

	descriptors.count = FACENET_NUM_LAYERS;
	descriptors.reserved = 0;
	descriptors.data = (uint64_t)(uintptr_t)facenet_descriptors;
	if (ioctl(fd, XUPT_NPU_IOC_LOAD_DESCRIPTORS, &descriptors) < 0)
		fail("load_descriptors");

	fill_test_frame();
	written = write(fd, test_frame, sizeof(test_frame));
	if (written != (ssize_t)sizeof(test_frame)) {
		if (written >= 0)
			errno = EIO;
		fail("write_frame");
	}

	run.flags = info.has_irq ? XUPT_NPU_RUN_USE_IRQ : 0;
	run.reserved = 0;
	if (ioctl(fd, XUPT_NPU_IOC_RUN, &run) < 0)
		fail("run");

	memset(&result, 0, sizeof(result));
	result.timeout_ms = 30000;
	if (ioctl(fd, XUPT_NPU_IOC_WAIT, &result) < 0)
		fail("wait");

	printf("status=0x%08x bbox_valid=%u frame_id=%u "
	       "bbox=%u,%u,%u,%u,%u perf_cycle=%u\n",
	       result.status, result.valid, result.frame_id,
	       result.bbox[0], result.bbox[1], result.bbox[2],
	       result.bbox[3], result.bbox[4], result.perf_cycles);

	if (!result.valid) {
		errno = EIO;
		fail("bbox_valid");
	}

	printf("NPU_LINUX_PASS\n");
	close(fd);
	finish_forever();
	return 0;
}
