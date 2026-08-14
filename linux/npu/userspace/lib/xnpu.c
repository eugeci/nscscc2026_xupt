/* SPDX-License-Identifier: MIT */
#include "xnpu.h"
#include "sha256.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#define XNPU_HEADER_SIZE 256U
#define XNPU_SECTION_ENTRY_SIZE 32U
#define XNPU_HASH_OFFSET 112U
#define XNPU_HASH_SIZE 32U
#define XNPU_ALIGNMENT 16U
#define XNPU_SECTION_REQUIRED (1U << 0)
#define XNPU_SECTION_UTF8 (1U << 1)
#define XNPU_SECTION_JSON (1U << 2)

static const uint8_t xnpu_magic[8] = {
	0x58, 0x4e, 0x50, 0x55, 0x0d, 0x0a, 0x1a, 0x0a,
};

static uint16_t get_le16(const uint8_t *data)
{
	return (uint16_t)data[0] | (uint16_t)data[1] << 8;
}

static uint32_t get_le32(const uint8_t *data)
{
	return (uint32_t)data[0] | (uint32_t)data[1] << 8 |
	       (uint32_t)data[2] << 16 | (uint32_t)data[3] << 24;
}

static uint32_t crc32_ieee(const uint8_t *data, size_t size)
{
	uint32_t value = UINT32_MAX;
	size_t index;

	for (index = 0; index < size; ++index) {
		unsigned int bit;

		value ^= data[index];
		for (bit = 0; bit < 8; ++bit)
			value = (value >> 1) ^
				(0xedb88320U & (0U - (value & 1U)));
	}
	return value ^ UINT32_MAX;
}

static int is_zero(const uint8_t *data, size_t size)
{
	while (size--)
		if (*data++)
			return 0;
	return 1;
}

static int valid_utf8(const uint8_t *data, size_t size)
{
	size_t index = 0;

	while (index < size) {
		uint8_t first = data[index++];
		unsigned int continuation;
		uint32_t codepoint;
		uint32_t minimum;

		if (first < 0x80)
			continue;
		if ((first & 0xe0) == 0xc0) {
			continuation = 1;
			codepoint = first & 0x1f;
			minimum = 0x80;
		} else if ((first & 0xf0) == 0xe0) {
			continuation = 2;
			codepoint = first & 0x0f;
			minimum = 0x800;
		} else if ((first & 0xf8) == 0xf0) {
			continuation = 3;
			codepoint = first & 0x07;
			minimum = 0x10000;
		} else {
			return 0;
		}
		if (continuation > size - index)
			return 0;
		while (continuation--) {
			uint8_t next = data[index++];

			if ((next & 0xc0) != 0x80)
				return 0;
			codepoint = (codepoint << 6) | (next & 0x3f);
		}
		if (codepoint < minimum || codepoint > 0x10ffff ||
		    (codepoint >= 0xd800 && codepoint <= 0xdfff))
			return 0;
	}
	return 1;
}

static void package_sha256(const uint8_t *data, size_t size,
			   uint8_t digest[32])
{
	static const uint8_t zeros[XNPU_HASH_SIZE];
	struct xnpu_sha256 context;

	xnpu_sha256_init(&context);
	xnpu_sha256_update(&context, data, XNPU_HASH_OFFSET);
	xnpu_sha256_update(&context, zeros, sizeof(zeros));
	xnpu_sha256_update(&context, data + XNPU_HASH_OFFSET + XNPU_HASH_SIZE,
			   size - XNPU_HASH_OFFSET - XNPU_HASH_SIZE);
	xnpu_sha256_final(&context, digest);
}

const struct xnpu_section *
xnpu_package_section(const struct xnpu_package *package, uint32_t type)
{
	size_t index;

	if (!package)
		return NULL;
	for (index = 0; index < package->section_count; ++index)
		if (package->sections[index].type == type)
			return &package->sections[index];
	return NULL;
}

const char *xnpu_package_name(const struct xnpu_package *package,
			     size_t *length)
{
	const struct xnpu_section *section =
		xnpu_package_section(package, XNPU_SECTION_NAME);

	if (!section)
		return NULL;
	if (length)
		*length = section->size;
	return (const char *)section->data;
}

static int validate_header(struct xnpu_package *package)
{
	const uint8_t *data = package->data;
	struct xnpu_package_info *info = &package->info;
	uint32_t file_size;

	if (memcmp(data, xnpu_magic, sizeof(xnpu_magic)) ||
	    get_le16(data + 8) != XNPU_PACKAGE_VERSION ||
	    get_le16(data + 10) != XNPU_HEADER_SIZE)
		return -EPROTO;
	if (get_le32(data + 12) != 0 || !is_zero(data + 144, 112))
		return -EPROTO;
	info->hardware_abi = get_le32(data + 16);
	info->model_id = get_le32(data + 20);
	info->task = get_le32(data + 24);
	info->layer_count = get_le32(data + 28);
	file_size = get_le32(data + 32);
	package->section_count = get_le32(data + 36);
	if (file_size != package->size ||
	    get_le32(data + 40) != XNPU_HEADER_SIZE ||
	    get_le32(data + 44) != XNPU_SECTION_ENTRY_SIZE ||
	    package->section_count == 0 ||
	    package->section_count > XNPU_MAX_SECTIONS ||
	    package->section_count >
		    (package->size - XNPU_HEADER_SIZE) / XNPU_SECTION_ENTRY_SIZE)
		return -EPROTO;
	info->input_mode = get_le32(data + 48);
	info->input.width = get_le32(data + 52);
	info->input.height = get_le32(data + 56);
	info->input.channels = get_le32(data + 60);
	info->input.layout = get_le32(data + 64);
	info->input.dtype = get_le32(data + 68);
	info->input.bytes = get_le32(data + 72);
	info->output.width = get_le32(data + 76);
	info->output.height = get_le32(data + 80);
	info->output.channels = get_le32(data + 84);
	info->output.layout = get_le32(data + 88);
	info->output.dtype = get_le32(data + 92);
	info->output.bytes = get_le32(data + 96);
	info->parameter_bytes = get_le32(data + 100);
	info->scratch_bytes = get_le32(data + 104);
	info->required_caps = get_le32(data + 108);
	memcpy(info->package_sha256, data + XNPU_HASH_OFFSET, XNPU_HASH_SIZE);
	if (info->hardware_abi != XNPU_PACKAGE_HARDWARE_ABI ||
	    (info->task != XNPU_TASK_BBOX &&
	     info->task != XNPU_TASK_CLASSIFICATION) ||
	    info->input_mode > XNPU_INPUT_PACKED_PRELOAD ||
	    info->input.layout > XNPU_LAYOUT_NCHW ||
	    info->output.layout > XNPU_LAYOUT_NCHW ||
	    info->input.dtype > XNPU_DTYPE_S32 ||
	    info->output.dtype > XNPU_DTYPE_S32 ||
	    !info->layer_count || !info->input.bytes || !info->output.bytes)
		return -EPROTO;
	return 0;
}

static int validate_sections(struct xnpu_package *package)
{
	const size_t table_end = XNPU_HEADER_SIZE +
		package->section_count * XNPU_SECTION_ENTRY_SIZE;
	uint32_t last_type = 0;
	size_t index;

	for (index = 0; index < package->section_count; ++index) {
		const uint8_t *entry = package->data + XNPU_HEADER_SIZE +
			index * XNPU_SECTION_ENTRY_SIZE;
		struct xnpu_section *section = &package->sections[index];
		uint32_t offset;
		uint32_t length;
		size_t prior;

		section->type = get_le32(entry);
		section->flags = get_le32(entry + 4);
		offset = get_le32(entry + 8);
		length = get_le32(entry + 12);
		section->crc32 = get_le32(entry + 16);
		if (!is_zero(entry + 20, 12) || section->type <= last_type ||
		    section->flags &
			    ~(XNPU_SECTION_REQUIRED | XNPU_SECTION_UTF8 |
			      XNPU_SECTION_JSON))
			return -EPROTO;
		last_type = section->type;
		if (section->type > XNPU_SECTION_METADATA &&
		    section->flags & XNPU_SECTION_REQUIRED)
			return -ENOTSUP;
		if (offset & (XNPU_ALIGNMENT - 1U) ||
		    offset < ((table_end + XNPU_ALIGNMENT - 1U) &
			      ~(XNPU_ALIGNMENT - 1U)) ||
		    offset > package->size || length > package->size - offset)
			return -EPROTO;
		section->data = package->data + offset;
		section->size = length;
		for (prior = 0; prior < index; ++prior) {
			const struct xnpu_section *other =
				&package->sections[prior];
			size_t other_offset =
				(size_t)(other->data - package->data);

			if (offset < other_offset + other->size &&
			    other_offset < (size_t)offset + length)
				return -EPROTO;
		}
		if (crc32_ieee(section->data, section->size) != section->crc32)
			return -EBADMSG;
		if (section->flags & XNPU_SECTION_UTF8 &&
		    !valid_utf8(section->data, section->size))
			return -EILSEQ;
	}
	return 0;
}

int xnpu_package_init(struct xnpu_package *package,
		      const void *data, size_t size)
{
	const struct xnpu_section *descriptors;
	const struct xnpu_section *parameters;
	const struct xnpu_section *name;
	uint8_t digest[32];
	int result;

	if (!package || !data || size < XNPU_HEADER_SIZE)
		return -EINVAL;
	memset(package, 0, sizeof(*package));
	package->data = data;
	package->size = size;
	result = validate_header(package);
	if (result)
		goto fail;
	result = validate_sections(package);
	if (result)
		goto fail;
	descriptors = xnpu_package_section(package, XNPU_SECTION_DESCRIPTORS);
	parameters = xnpu_package_section(package, XNPU_SECTION_PARAMETERS);
	name = xnpu_package_section(package, XNPU_SECTION_NAME);
	if (!descriptors || !parameters || !name ||
	    !(descriptors->flags & XNPU_SECTION_REQUIRED) ||
	    !(parameters->flags & XNPU_SECTION_REQUIRED) ||
	    !(name->flags & XNPU_SECTION_REQUIRED) ||
	    descriptors->size != (size_t)package->info.layer_count * 32U ||
	    parameters->size != package->info.parameter_bytes ||
	    !name->size || memchr(name->data, '\0', name->size))
		goto protocol_fail;
	package_sha256(package->data, package->size, digest);
	if (memcmp(digest, package->info.package_sha256, sizeof(digest))) {
		result = -EBADMSG;
		goto fail;
	}
	return 0;

protocol_fail:
	result = -EPROTO;
fail:
	memset(package, 0, sizeof(*package));
	return result;
}

int xnpu_read_file(const char *path, uint8_t **data, size_t *size)
{
	struct stat status;
	uint8_t *buffer;
	size_t received = 0;
	int fd;

	if (!path || !data || !size)
		return -EINVAL;
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return -errno;
	if (fstat(fd, &status) < 0) {
		int result = -errno;

		close(fd);
		return result;
	}
	if (status.st_size <= 0 || (uintmax_t)status.st_size > SIZE_MAX) {
		close(fd);
		return -EFBIG;
	}
	buffer = malloc((size_t)status.st_size);
	if (!buffer) {
		close(fd);
		return -ENOMEM;
	}
	while (received < (size_t)status.st_size) {
		ssize_t count = read(fd, buffer + received,
				     (size_t)status.st_size - received);

		if (count < 0) {
			int result = -errno;

			close(fd);
			free(buffer);
			return result;
		}
		if (!count) {
			close(fd);
			free(buffer);
			return -EIO;
		}
		received += (size_t)count;
	}
	close(fd);
	*data = buffer;
	*size = received;
	return 0;
}

int xnpu_package_open(struct xnpu_package *package, const char *path)
{
	uint8_t *data;
	size_t size;
	int result;

	result = xnpu_read_file(path, &data, &size);
	if (result)
		return result;
	result = xnpu_package_init(package, data, size);
	if (result) {
		free(data);
		return result;
	}
	package->owned_data = data;
	return 0;
}

void xnpu_package_close(struct xnpu_package *package)
{
	if (!package)
		return;
	free(package->owned_data);
	memset(package, 0, sizeof(*package));
}

int xnpu_device_open(struct xnpu_device *device, const char *path)
{
	if (!device)
		return -EINVAL;
	memset(device, 0, sizeof(*device));
	device->fd = open(path ? path : "/dev/xnpu", O_RDWR);
	if (device->fd < 0)
		return -errno;
	if (ioctl(device->fd, XNPU_IOC_GET_INFO, &device->info) < 0 ||
	    ioctl(device->fd, XNPU_IOC_QUERY_CAPS, &device->caps) < 0) {
		int result = -errno;

		xnpu_device_close(device);
		return result;
	}
	if (device->info.abi_version != XNPU_ABI_VERSION ||
	    device->caps.abi_version != XNPU_ABI_VERSION) {
		xnpu_device_close(device);
		return -EPROTONOSUPPORT;
	}
	return 0;
}

void xnpu_device_close(struct xnpu_device *device)
{
	if (!device)
		return;
	if (device->fd >= 0)
		close(device->fd);
	memset(device, 0, sizeof(*device));
	device->fd = -1;
}

int xnpu_device_load_model(struct xnpu_device *device,
			   const struct xnpu_package *package)
{
	const struct xnpu_section *descriptors;
	const struct xnpu_section *parameters;
	struct xnpu_model model;

	if (!device || device->fd < 0 || !package)
		return -EINVAL;
	if (device->caps.hardware_abi != package->info.hardware_abi ||
	    (package->info.required_caps & ~device->caps.capabilities))
		return -ENOTSUP;
	if (package->info.layer_count > device->caps.max_layers ||
	    package->info.parameter_bytes > device->caps.max_parameter_bytes ||
	    package->info.scratch_bytes > device->caps.max_scratch_bytes ||
	    package->info.output.bytes > device->caps.max_result_bytes ||
	    package->info.input.bytes > device->caps.max_input_bytes)
		return -E2BIG;
	descriptors = xnpu_package_section(package, XNPU_SECTION_DESCRIPTORS);
	parameters = xnpu_package_section(package, XNPU_SECTION_PARAMETERS);
	if (!descriptors || !parameters)
		return -EPROTO;
	memset(&model, 0, sizeof(model));
	model.layer_count = package->info.layer_count;
	model.input_mode = package->info.input_mode;
	model.input_bytes = package->info.input.bytes;
	model.parameter_bytes = package->info.parameter_bytes;
	model.scratch_bytes = package->info.scratch_bytes;
	model.result_bytes = package->info.output.bytes;
	model.result_width = package->info.output.width;
	model.result_height = package->info.output.height;
	model.result_channels = package->info.output.channels;
	model.result_layout = package->info.output.layout;
	model.result_dtype = package->info.output.dtype;
	model.descriptors = (uint64_t)(uintptr_t)descriptors->data;
	model.parameters = (uint64_t)(uintptr_t)parameters->data;
	if (ioctl(device->fd, XNPU_IOC_LOAD_MODEL, &model) < 0)
		return -errno;
	return 0;
}

int xnpu_device_infer(struct xnpu_device *device,
		      const struct xnpu_package *package,
		      const void *input, size_t input_size,
		      uint32_t timeout_ms, int use_irq,
		      void *output, size_t output_capacity,
		      struct xnpu_result_v2 *result)
{
	struct xnpu_result_v2 local_result;
	struct xnpu_input input_request;
	struct xnpu_run run;
	size_t received = 0;

	if (!device || device->fd < 0 || !package || !input || !output ||
	    input_size != package->info.input.bytes ||
	    output_capacity < package->info.output.bytes)
		return -EINVAL;
	memset(&input_request, 0, sizeof(input_request));
	input_request.mode = package->info.input_mode;
	input_request.bytes = package->info.input.bytes;
	input_request.data = (uint64_t)(uintptr_t)input;
	if (ioctl(device->fd, XNPU_IOC_LOAD_INPUT, &input_request) < 0)
		return -errno;
	memset(&run, 0, sizeof(run));
	if (use_irq && device->info.has_irq)
		run.flags = XNPU_RUN_USE_IRQ;
	if (ioctl(device->fd, XNPU_IOC_RUN, &run) < 0)
		return -errno;
	memset(&local_result, 0, sizeof(local_result));
	local_result.timeout_ms = timeout_ms;
	if (ioctl(device->fd, XNPU_IOC_WAIT_V2, &local_result) < 0)
		return -errno;
	if (local_result.result_bytes != package->info.output.bytes ||
	    local_result.result_width != package->info.output.width ||
	    local_result.result_height != package->info.output.height ||
	    local_result.result_channels != package->info.output.channels ||
	    local_result.result_layout != package->info.output.layout ||
	    local_result.result_dtype != package->info.output.dtype)
		return -EPROTO;
	while (received < package->info.output.bytes) {
		ssize_t count = read(device->fd, (uint8_t *)output + received,
				     package->info.output.bytes - received);

		if (count < 0)
			return -errno;
		if (!count)
			return -EIO;
		received += (size_t)count;
	}
	if (result)
		*result = local_result;
	return 0;
}

uint32_t xnpu_top1_u8(const uint8_t *scores, size_t count)
{
	size_t best = 0;
	size_t index;

	for (index = 1; index < count; ++index)
		if (scores[index] > scores[best])
			best = index;
	return (uint32_t)best;
}

void xnpu_sha256_hex(const uint8_t digest[32], char output[65])
{
	static const char digits[] = "0123456789abcdef";
	unsigned int index;

	for (index = 0; index < 32; ++index) {
		output[index * 2] = digits[digest[index] >> 4];
		output[index * 2 + 1] = digits[digest[index] & 15];
	}
	output[64] = '\0';
}
