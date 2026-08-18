/* SPDX-License-Identifier: MIT */
#include "xnpu.h"

#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void usage(FILE *stream)
{
	fprintf(stream,
		"usage: xnpu-run [OPTIONS] MODEL.xnpu INPUT.bin\n"
		"  -d, --device PATH          NPU device (default /dev/xnpu)\n"
		"  -t, --timeout-ms N         timeout (default 30000)\n"
		"      --poll                 do not request IRQ completion\n"
		"      --expect-checksum HEX  require result checksum\n"
		"      --expect-top1 N        require uint8 top-1 class\n"
		"      --expect-bbox CSV      require first five bytes\n");
}

static int parse_u32(const char *text, uint32_t *value)
{
	char *end;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(text, &end, 0);
	if (errno || end == text || *end || parsed > UINT32_MAX)
		return -EINVAL;
	*value = (uint32_t)parsed;
	return 0;
}

static int parse_bbox(const char *text, uint8_t bbox[5])
{
	unsigned int values[5];
	char tail;
	unsigned int index;

	if (sscanf(text, "%u,%u,%u,%u,%u%c", &values[0], &values[1],
		   &values[2], &values[3], &values[4], &tail) != 5)
		return -EINVAL;
	for (index = 0; index < 5; ++index) {
		if (values[index] > 255)
			return -EINVAL;
		bbox[index] = (uint8_t)values[index];
	}
	return 0;
}

int main(int argc, char **argv)
{
	static const struct option options[] = {
		{ "device", required_argument, NULL, 'd' },
		{ "timeout-ms", required_argument, NULL, 't' },
		{ "poll", no_argument, NULL, 1 },
		{ "expect-checksum", required_argument, NULL, 2 },
		{ "expect-top1", required_argument, NULL, 3 },
		{ "expect-bbox", required_argument, NULL, 4 },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	const char *device_path = "/dev/xnpu";
	struct xnpu_result_v2 inference;
	struct xnpu_package package;
	struct xnpu_device device = { .fd = -1 };
	uint8_t expected_bbox[5] = { 0 };
	uint8_t *input = NULL;
	uint8_t *output = NULL;
	uint32_t timeout_ms = 30000;
	uint32_t expected_checksum = 0;
	uint32_t expected_top1 = 0;
	size_t input_size = 0;
	int have_checksum = 0;
	int have_top1 = 0;
	int have_bbox = 0;
	int use_irq = 1;
	int option;
	int result;

	while ((option = getopt_long(argc, argv, "d:t:h", options, NULL)) != -1) {
		switch (option) {
		case 'd':
			device_path = optarg;
			break;
		case 't':
			if (parse_u32(optarg, &timeout_ms))
				goto bad_argument;
			break;
		case 'h':
			usage(stdout);
			return 0;
		case 1:
			use_irq = 0;
			break;
		case 2:
			if (parse_u32(optarg, &expected_checksum))
				goto bad_argument;
			have_checksum = 1;
			break;
		case 3:
			if (parse_u32(optarg, &expected_top1))
				goto bad_argument;
			have_top1 = 1;
			break;
		case 4:
			if (parse_bbox(optarg, expected_bbox))
				goto bad_argument;
			have_bbox = 1;
			break;
		default:
			goto bad_argument;
		}
	}
	if (argc - optind != 2)
		goto bad_argument;
	result = xnpu_package_open(&package, argv[optind]);
	if (result) {
		fprintf(stderr, "%s: %s\n", argv[optind], strerror(-result));
		return 1;
	}
	result = xnpu_read_file(argv[optind + 1], &input, &input_size);
	if (result) {
		fprintf(stderr, "%s: %s\n", argv[optind + 1],
			strerror(-result));
		goto cleanup;
	}
	if (input_size != package.info.input.bytes) {
		result = -EMSGSIZE;
		fprintf(stderr, "%s: %s\n", argv[optind + 1],
			strerror(-result));
		goto cleanup;
	}
	output = malloc(package.info.output.bytes);
	if (!output) {
		result = -ENOMEM;
		fprintf(stderr, "xnpu-run: output: %s\n", strerror(-result));
		goto cleanup;
	}
	result = xnpu_device_open(&device, device_path);
	if (result) {
		fprintf(stderr, "%s: %s\n", device_path, strerror(-result));
		goto cleanup;
	}
	result = xnpu_device_load_model(&device, &package);
	if (result)
		goto inference_fail;
	result = xnpu_device_infer(&device, &package, input, input_size,
				   timeout_ms, use_irq, output,
				   package.info.output.bytes, &inference);
	if (result)
		goto inference_fail;
	printf("bytes=%u checksum=0x%08x perf_cycle=%u status=0x%08x\n",
	       inference.result_bytes, inference.result_checksum,
	       inference.perf_cycles, inference.result_status);
	if (package.info.task == XNPU_TASK_BBOX && package.info.output.bytes >= 5)
		printf("bbox=%u,%u,%u,%u,%u\n", output[0], output[1], output[2],
		       output[3], output[4]);
	if (package.info.task == XNPU_TASK_CLASSIFICATION &&
	    package.info.output.dtype == XNPU_DTYPE_U8)
		printf("top1=%u\n",
		       xnpu_top1_u8(output, package.info.output.bytes));
	if ((have_checksum && inference.result_checksum != expected_checksum) ||
	    (have_top1 &&
	     xnpu_top1_u8(output, package.info.output.bytes) != expected_top1) ||
	    (have_bbox && (package.info.output.bytes < sizeof(expected_bbox) ||
			   memcmp(output, expected_bbox, sizeof(expected_bbox))))) {
		result = -EBADMSG;
		goto inference_fail;
	}
	printf("XNPU_RUN_PASS\n");
	result = 0;
	goto cleanup;

inference_fail:
	fprintf(stderr, "xnpu-run: inference: %s\n", strerror(-result));
cleanup:
	if (device.fd >= 0)
		xnpu_device_close(&device);
	free(output);
	free(input);
	xnpu_package_close(&package);
	return result ? 1 : 0;
bad_argument:
	usage(stderr);
	return 2;
}
