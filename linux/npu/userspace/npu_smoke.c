// SPDX-License-Identifier: GPL-2.0
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <unistd.h>

#include <linux/xupt_npu.h>
#include "npu_golden_input.h"

#define FACENET_NUM_LAYERS 10U
#define FACENET_PARAMETER_BYTES 84392U
#define FACENET_PARAMETER_WORDS (FACENET_PARAMETER_BYTES / sizeof(uint32_t))
#define FACENET_RESULT_BYTES 16U
#define FACENET_RESULT_CHECKSUM 0x685184b3U

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

static uint8_t *load_parameter_hex(void)
{
	char line[128];
	uint8_t *parameters;
	size_t words = 0;
	FILE *stream;

	parameters = malloc(FACENET_PARAMETER_BYTES);
	if (!parameters)
		return NULL;

	stream = fopen("/npu_params.hex", "r");
	if (!stream) {
		free(parameters);
		return NULL;
	}

	while (fgets(line, sizeof(line), stream)) {
		unsigned long value;
		char *end;

		if (line[0] == '@' || line[0] == '\n' || line[0] == '\r')
			continue;
		errno = 0;
		value = strtoul(line, &end, 16);
		if (errno || end == line || value > UINT32_MAX ||
		    (*end && *end != '\n' && *end != '\r') ||
		    words >= FACENET_PARAMETER_WORDS) {
			fclose(stream);
			free(parameters);
			errno = EINVAL;
			return NULL;
		}
		parameters[words * 4 + 0] = value;
		parameters[words * 4 + 1] = value >> 8;
		parameters[words * 4 + 2] = value >> 16;
		parameters[words * 4 + 3] = value >> 24;
		++words;
	}
	fclose(stream);

	if (words != FACENET_PARAMETER_WORDS) {
		free(parameters);
		errno = EINVAL;
		return NULL;
	}
	return parameters;
}

static void run_legacy_smoke(int fd, const struct xupt_npu_info *info)
{
	struct xupt_npu_descriptors descriptors;
	struct xupt_npu_result result;
	struct xupt_npu_run run;
	ssize_t written;

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

	run.flags = info->has_irq ? XUPT_NPU_RUN_USE_IRQ : 0;
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
}

static void run_dma_smoke(int fd, const struct xupt_npu_info *info)
{
	struct xupt_npu_result_v2 result;
	struct xupt_npu_model model;
	struct xupt_npu_input input;
	struct xupt_npu_run run;
	uint8_t output[FACENET_RESULT_BYTES];
	uint8_t *parameters;
	size_t received = 0;

	parameters = load_parameter_hex();
	if (!parameters)
		fail("load_parameter_hex");

	memset(&model, 0, sizeof(model));
	model.layer_count = FACENET_NUM_LAYERS;
	model.input_mode = XUPT_NPU_INPUT_FRAME;
	model.input_bytes = XUPT_NPU_FRAME_BYTES;
	model.parameter_bytes = FACENET_PARAMETER_BYTES;
	model.scratch_bytes = XUPT_NPU_MAX_SCRATCH_BYTES;
	model.result_bytes = FACENET_RESULT_BYTES;
	model.result_width = 1;
	model.result_height = 1;
	model.result_channels = 5;
	model.result_layout = XUPT_NPU_LAYOUT_LINEAR;
	model.result_dtype = XUPT_NPU_DTYPE_U8;
	model.descriptors =
		(uint64_t)(uintptr_t)facenet_descriptors;
	model.parameters = (uint64_t)(uintptr_t)parameters;
	if (ioctl(fd, XUPT_NPU_IOC_LOAD_MODEL, &model) < 0)
		fail("load_model");
	free(parameters);

	memset(&input, 0, sizeof(input));
	input.mode = XUPT_NPU_INPUT_FRAME;
	input.bytes = XUPT_NPU_FRAME_BYTES;
	input.data = (uint64_t)(uintptr_t)npu_golden_frame;
	if (ioctl(fd, XUPT_NPU_IOC_LOAD_INPUT, &input) < 0)
		fail("load_input");

	run.flags = info->has_irq ? XUPT_NPU_RUN_USE_IRQ : 0;
	run.reserved = 0;
	if (ioctl(fd, XUPT_NPU_IOC_RUN, &run) < 0)
		fail("run_dma");

	memset(&result, 0, sizeof(result));
	result.timeout_ms = 30000;
	if (ioctl(fd, XUPT_NPU_IOC_WAIT_V2, &result) < 0)
		fail("wait_dma");

	while (received < sizeof(output)) {
		ssize_t bytes = read(fd, output + received,
				     sizeof(output) - received);

		if (bytes < 0)
			fail("read_result");
		if (!bytes) {
			errno = EIO;
			fail("short_result");
		}
		received += bytes;
	}

	printf("dma status=0x%08x result_status=0x%08x bytes=%u "
	       "checksum=0x%08x shape=%ux%ux%u bbox=%u,%u,%u,%u,%u "
	       "perf_cycle=%u\n",
	       result.status, result.result_status, result.result_bytes,
	       result.result_checksum, result.result_width,
	       result.result_height, result.result_channels,
	       output[0], output[1], output[2], output[3], output[4],
	       result.perf_cycles);

	if (result.result_bytes != FACENET_RESULT_BYTES ||
	    result.result_checksum != FACENET_RESULT_CHECKSUM ||
	    memcmp(output, npu_golden_bbox, NPU_GOLDEN_BBOX_BYTES)) {
		errno = EIO;
		fail("dma_golden");
	}
}

int main(void)
{
	struct xupt_npu_caps caps;
	struct xupt_npu_info info;
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
	if (ioctl(fd, XUPT_NPU_IOC_QUERY_CAPS, &caps) < 0)
		fail("query_caps");

	printf("npu abi=%u hw_abi=%u caps=0x%08x frame=%ux%u bytes=%u "
	       "max_layers=%u irq=%u\n",
	       info.abi_version, caps.hardware_abi, caps.capabilities,
	       info.frame_width, info.frame_height, info.frame_bytes,
	       info.max_layers, info.has_irq);

	if (info.abi_version != XUPT_NPU_ABI_VERSION ||
	    caps.abi_version != XUPT_NPU_ABI_VERSION ||
	    info.frame_bytes != XUPT_NPU_FRAME_BYTES) {
		errno = EPROTO;
		fail("abi_check");
	}

	if (caps.capabilities & XUPT_NPU_CAP_AXI_DMA)
		run_dma_smoke(fd, &info);
	else
		run_legacy_smoke(fd, &info);

	printf("NPU_LINUX_PASS\n");
	close(fd);
	finish_forever();
	return 0;
}
