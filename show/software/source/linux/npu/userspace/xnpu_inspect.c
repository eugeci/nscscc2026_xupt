/* SPDX-License-Identifier: MIT */
#include "xnpu.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

static const char *task_name(uint32_t task)
{
	return task == XNPU_TASK_BBOX ? "bbox" : "classification";
}

int main(int argc, char **argv)
{
	struct xnpu_package package;
	char digest[65];
	const char *name;
	size_t name_length;
	size_t index;
	int result;

	if (argc != 2) {
		fprintf(stderr, "usage: xnpu-inspect MODEL.xnpu\n");
		return 2;
	}
	result = xnpu_package_open(&package, argv[1]);
	if (result) {
		fprintf(stderr, "%s: %s\n", argv[1], strerror(-result));
		return 1;
	}
	name = xnpu_package_name(&package, &name_length);
	xnpu_sha256_hex(package.info.package_sha256, digest);
	printf("name=%.*s model_id=%u task=%s hardware_abi=%u layers=%u\n",
	       (int)name_length, name, package.info.model_id,
	       task_name(package.info.task), package.info.hardware_abi,
	       package.info.layer_count);
	printf("input=%ux%ux%u mode=%u layout=%u dtype=%u bytes=%u\n",
	       package.info.input.width, package.info.input.height,
	       package.info.input.channels, package.info.input_mode,
	       package.info.input.layout, package.info.input.dtype,
	       package.info.input.bytes);
	printf("output=%ux%ux%u layout=%u dtype=%u bytes=%u\n",
	       package.info.output.width, package.info.output.height,
	       package.info.output.channels, package.info.output.layout,
	       package.info.output.dtype, package.info.output.bytes);
	printf("parameters=%u scratch=%u required_caps=0x%08x\n",
	       package.info.parameter_bytes, package.info.scratch_bytes,
	       package.info.required_caps);
	printf("package_sha256=%s\n", digest);
	for (index = 0; index < package.section_count; ++index)
		printf("section=%u flags=0x%x bytes=%zu crc32=0x%08x\n",
		       package.sections[index].type,
		       package.sections[index].flags,
		       package.sections[index].size,
		       package.sections[index].crc32);
	xnpu_package_close(&package);
	return 0;
}
