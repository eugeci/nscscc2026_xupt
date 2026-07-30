/* SPDX-License-Identifier: GPL-2.0 */
#include "xnpu.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

#define EXPECTED_CHECKSUM 0x685184b3U

static const uint8_t expected_bbox[5] = { 58, 132, 81, 104, 137 };

static void finish_forever(void)
{
	for (;;)
		sleep(3600);
}

static void fail(const char *operation, int result)
{
	printf("XNPU_STAGE4_FAIL operation=%s error=%d (%s)\n",
	       operation, -result, strerror(-result));
	fflush(stdout);
	finish_forever();
}

int main(void)
{
	struct xupt_npu_result_v2 inference;
	struct xnpu_package package;
	struct xnpu_device device;
	uint8_t *input;
	uint8_t *output;
	size_t input_size;
	size_t name_length;
	const char *name;
	int result;

	setvbuf(stdout, NULL, _IONBF, 0);
	printf("XNPU Stage-4 Linux smoke start\n");
	if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) < 0 &&
	    errno != EBUSY)
		fail("mount_devtmpfs", -errno);
	result = xnpu_package_open(&package, "/models/facenet_lbp_v1.xnpu");
	if (result)
		fail("package_open", result);
	name = xnpu_package_name(&package, &name_length);
	printf("package=%.*s model_id=%u abi=%u layers=%u input=%u "
	       "parameters=%u sha256=",
	       (int)name_length, name, package.info.model_id,
	       package.info.hardware_abi, package.info.layer_count,
	       package.info.input.bytes, package.info.parameter_bytes);
	{
		char digest[65];

		xnpu_sha256_hex(package.info.package_sha256, digest);
		printf("%s\n", digest);
	}
	result = xnpu_read_file("/fixtures/facenet_seed42.bin",
				&input, &input_size);
	if (result)
		fail("fixture_open", result);
	output = malloc(package.info.output.bytes);
	if (!output)
		fail("output_alloc", -ENOMEM);
	result = xnpu_device_open(&device, "/dev/xupt-npu");
	if (result)
		fail("device_open", result);
	printf("driver_abi=%u hardware_abi=%u caps=0x%08x\n",
	       device.info.abi_version, device.caps.hardware_abi,
	       device.caps.capabilities);
	result = xnpu_device_load_model(&device, &package);
	if (result)
		fail("load_model", result);
	result = xnpu_device_infer(&device, &package, input, input_size,
				   30000, 1, output,
				   package.info.output.bytes, &inference);
	if (result)
		fail("infer", result);
	printf("bytes=%u checksum=0x%08x bbox=%u,%u,%u,%u,%u "
	       "perf_cycle=%u\n",
	       inference.result_bytes, inference.result_checksum,
	       output[0], output[1], output[2], output[3], output[4],
	       inference.perf_cycles);
	if (inference.result_checksum != EXPECTED_CHECKSUM ||
	    package.info.output.bytes < sizeof(expected_bbox) ||
	    memcmp(output, expected_bbox, sizeof(expected_bbox)))
		fail("golden", -EBADMSG);
	printf("XNPU_STAGE4_PASS\n");
	xnpu_device_close(&device);
	free(output);
	free(input);
	xnpu_package_close(&package);
	finish_forever();
	return 0;
}
