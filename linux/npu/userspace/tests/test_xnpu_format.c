/* SPDX-License-Identifier: MIT */
#include "xnpu.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int expect_invalid(const char *name, uint8_t *data, size_t size,
			  int expected)
{
	struct xnpu_package package;
	int result = xnpu_package_init(&package, data, size);

	if (result != expected) {
		fprintf(stderr, "%s: got %d, expected %d\n",
			name, result, expected);
		return 1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	struct xnpu_package reference;
	uint8_t *data;
	uint8_t *copy;
	size_t size;
	int failures = 0;
	int index;
	int result;

	if (argc < 2) {
		fprintf(stderr, "usage: test_xnpu_format PACKAGE...\n");
		return 2;
	}
	for (index = 1; index < argc; ++index) {
		struct xnpu_package package;

		result = xnpu_package_open(&package, argv[index]);
		if (result) {
			fprintf(stderr, "%s: %s\n", argv[index],
				strerror(-result));
			++failures;
			continue;
		}
		printf("valid package: %s model=%u sections=%zu\n",
		       argv[index], package.info.model_id,
		       package.section_count);
		xnpu_package_close(&package);
	}
	result = xnpu_read_file(argv[1], &data, &size);
	if (result)
		return 1;
	result = xnpu_package_init(&reference, data, size);
	if (result)
		return 1;
	copy = malloc(size);
	if (!copy)
		return 1;

	memcpy(copy, data, size);
	copy[0] ^= 1;
	failures += expect_invalid("bad magic", copy, size, -EPROTO);

	memcpy(copy, data, size);
	copy[112] ^= 1;
	failures += expect_invalid("bad package hash", copy, size, -EBADMSG);

	memcpy(copy, data, size);
	copy[264] |= 1;
	failures += expect_invalid("misaligned section", copy, size, -EPROTO);

	memcpy(copy, data, size);
	copy[reference.sections[1].data - data] ^= 1;
	failures += expect_invalid("bad section CRC", copy, size, -EBADMSG);

	failures += expect_invalid("truncated file", data, size - 1, -EPROTO);
	free(copy);
	free(data);
	if (failures)
		return 1;
	printf("XNPU_FORMAT_TEST_PASS packages=%d negative_cases=5\n", argc - 1);
	return 0;
}
