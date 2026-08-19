/* SPDX-License-Identifier: MIT */
#ifndef XNPU_H
#define XNPU_H

#include <stddef.h>
#include <stdint.h>

#include <linux/xnpu.h>

#ifdef __cplusplus
extern "C" {
#endif

#define XNPU_PACKAGE_VERSION 1U
#define XNPU_PACKAGE_HARDWARE_ABI 2U
#define XNPU_MAX_SECTIONS 32U

#define XNPU_SECTION_DESCRIPTORS 1U
#define XNPU_SECTION_PARAMETERS 2U
#define XNPU_SECTION_NAME 3U
#define XNPU_SECTION_LABELS 4U
#define XNPU_SECTION_METADATA 5U

#define XNPU_TASK_BBOX 1U
#define XNPU_TASK_CLASSIFICATION 2U

struct xnpu_tensor_contract {
	uint32_t width;
	uint32_t height;
	uint32_t channels;
	uint32_t layout;
	uint32_t dtype;
	uint32_t bytes;
};

struct xnpu_package_info {
	uint32_t hardware_abi;
	uint32_t model_id;
	uint32_t task;
	uint32_t layer_count;
	uint32_t input_mode;
	struct xnpu_tensor_contract input;
	struct xnpu_tensor_contract output;
	uint32_t parameter_bytes;
	uint32_t scratch_bytes;
	uint32_t required_caps;
	uint8_t package_sha256[32];
};

struct xnpu_section {
	uint32_t type;
	uint32_t flags;
	uint32_t crc32;
	const uint8_t *data;
	size_t size;
};

/*
 * The members are public to permit static allocation.  Applications should
 * inspect package.info and use xnpu_package_section(), not modify the object.
 */
struct xnpu_package {
	const uint8_t *data;
	size_t size;
	uint8_t *owned_data;
	struct xnpu_package_info info;
	struct xnpu_section sections[XNPU_MAX_SECTIONS];
	size_t section_count;
};

struct xnpu_device {
	int fd;
	struct xnpu_info info;
	struct xnpu_caps caps;
};

int xnpu_package_init(struct xnpu_package *package,
		      const void *data, size_t size);
int xnpu_package_open(struct xnpu_package *package, const char *path);
void xnpu_package_close(struct xnpu_package *package);
const struct xnpu_section *
xnpu_package_section(const struct xnpu_package *package, uint32_t type);
const char *xnpu_package_name(const struct xnpu_package *package,
			     size_t *length);

int xnpu_device_open(struct xnpu_device *device, const char *path);
void xnpu_device_close(struct xnpu_device *device);
int xnpu_device_load_model(struct xnpu_device *device,
			   const struct xnpu_package *package);
int xnpu_device_infer(struct xnpu_device *device,
		      const struct xnpu_package *package,
		      const void *input, size_t input_size,
		      uint32_t timeout_ms, int use_irq,
		      void *output, size_t output_capacity,
		      struct xnpu_result_v2 *result);

int xnpu_read_file(const char *path, uint8_t **data, size_t *size);
uint32_t xnpu_top1_u8(const uint8_t *scores, size_t count);
void xnpu_sha256_hex(const uint8_t digest[32], char output[65]);

#ifdef __cplusplus
}
#endif

#endif /* XNPU_H */
