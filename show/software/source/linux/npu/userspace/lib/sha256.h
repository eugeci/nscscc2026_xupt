/* SPDX-License-Identifier: MIT */
#ifndef XNPU_SHA256_H
#define XNPU_SHA256_H

#include <stddef.h>
#include <stdint.h>

struct xnpu_sha256 {
	uint32_t state[8];
	uint64_t bits;
	uint8_t block[64];
	size_t used;
};

void xnpu_sha256_init(struct xnpu_sha256 *context);
void xnpu_sha256_update(struct xnpu_sha256 *context,
			const void *data, size_t size);
void xnpu_sha256_final(struct xnpu_sha256 *context, uint8_t digest[32]);

#endif
