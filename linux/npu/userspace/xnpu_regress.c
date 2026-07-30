/* SPDX-License-Identifier: MIT */
#include "xnpu.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

static int check_expected(const char *kind, const char *expected,
			  const uint8_t *output, size_t output_size)
{
	if (!strcmp(kind, "top1")) {
		uint32_t value;

		if (parse_u32(expected, &value) ||
		    xnpu_top1_u8(output, output_size) != value)
			return -EBADMSG;
		return 0;
	}
	if (!strcmp(kind, "bbox")) {
		unsigned int values[5];
		char tail;
		unsigned int index;

		if (output_size < 5 ||
		    sscanf(expected, "%u,%u,%u,%u,%u%c",
			   &values[0], &values[1], &values[2],
			   &values[3], &values[4], &tail) != 5)
			return -EINVAL;
		for (index = 0; index < 5; ++index)
			if (values[index] > 255 || output[index] != values[index])
				return -EBADMSG;
		return 0;
	}
	return -EINVAL;
}

static int split_fields(char *line, char *fields[5])
{
	unsigned int index;

	for (index = 0; index < 5; ++index) {
		char *separator;

		fields[index] = line;
		separator = strchr(line, '\t');
		if (index == 4)
			return separator ? -EINVAL : 0;
		if (!separator)
			return -EINVAL;
		*separator = '\0';
		line = separator + 1;
	}
	return -EINVAL;
}

int main(int argc, char **argv)
{
	const char *device_path = "/dev/xupt-npu";
	struct xnpu_device device;
	char line[2048];
	unsigned int count = 0;
	FILE *manifest;
	int result;

	if (argc == 4 && !strcmp(argv[1], "--device")) {
		device_path = argv[2];
		argv += 2;
		argc -= 2;
	}
	if (argc != 2) {
		fprintf(stderr,
			"usage: xnpu-regress [--device PATH] regression.tsv\n");
		return 2;
	}
	manifest = fopen(argv[1], "r");
	if (!manifest) {
		perror(argv[1]);
		return 1;
	}
	result = xnpu_device_open(&device, device_path);
	if (result) {
		fprintf(stderr, "%s: %s\n", device_path, strerror(-result));
		fclose(manifest);
		return 1;
	}
	while (fgets(line, sizeof(line), manifest)) {
		struct xupt_npu_result_v2 inference;
		struct xnpu_package package;
		char *fields[5];
		uint8_t *input = NULL;
		uint8_t *output = NULL;
		uint32_t checksum;
		size_t input_size;

		if (line[0] == '#' || line[0] == '\n')
			continue;
		line[strcspn(line, "\r\n")] = '\0';
		if (split_fields(line, fields) ||
		    parse_u32(fields[2], &checksum)) {
			result = -EINVAL;
			fprintf(stderr, "manifest line %u is invalid\n", count + 1);
			goto fail;
		}
		result = xnpu_package_open(&package, fields[0]);
		if (result)
			goto item_fail;
		result = xnpu_read_file(fields[1], &input, &input_size);
		if (result)
			goto package_fail;
		if (input_size != package.info.input.bytes) {
			result = -EMSGSIZE;
			goto input_fail;
		}
		output = malloc(package.info.output.bytes);
		if (!output) {
			result = -ENOMEM;
			goto input_fail;
		}
		result = xnpu_device_load_model(&device, &package);
		if (!result)
			result = xnpu_device_infer(
				&device, &package, input, input_size, 30000, 1,
				output, package.info.output.bytes, &inference);
		if (!result && inference.result_checksum != checksum)
			result = -EBADMSG;
		if (!result)
			result = check_expected(fields[3], fields[4], output,
						package.info.output.bytes);
		if (result)
			goto output_fail;
		++count;
		printf("XNPU_REGRESS_ITEM_PASS index=%u model=%s "
		       "checksum=0x%08x perf_cycle=%u\n",
		       count, fields[0], inference.result_checksum,
		       inference.perf_cycles);
		free(output);
		free(input);
		xnpu_package_close(&package);
		continue;

output_fail:
		free(output);
input_fail:
		free(input);
package_fail:
		xnpu_package_close(&package);
item_fail:
		fprintf(stderr, "regression item %u: %s\n",
			count + 1, strerror(-result));
		goto fail;
	}
	if (ferror(manifest)) {
		result = -EIO;
		goto fail;
	}
	fclose(manifest);
	xnpu_device_close(&device);
	printf("XNPU_REGRESS_PASS count=%u\n", count);
	return 0;

fail:
	fclose(manifest);
	xnpu_device_close(&device);
	return 1;
}
