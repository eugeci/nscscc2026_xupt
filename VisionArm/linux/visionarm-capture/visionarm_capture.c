/* SPDX-License-Identifier: MIT */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define CAM_BASE 0x1fd0e100U
#define REG_CTRL 0U
#define REG_STATUS 1U
#define REG_FRAME_COUNT 2U
#define REG_FRAME0 5U
#define REG_FRAME1 6U
#define REG_OUTPUT_SIZE 7U
#define REG_STRIDE 9U
#define REG_MAGIC 15U
#define CAM_MAGIC 0x43414d31U
#define EXPECTED_WIDTH 640U
#define EXPECTED_HEIGHT 480U
#define EXPECTED_STRIDE 1280U

struct mapping { void *base; size_t length; volatile uint8_t *ptr; };
struct options {
	const char *prefix;
	unsigned count;
	unsigned interval_ms;
	unsigned buffer_index;
	int self_test;
};

static void sleep_ms(unsigned ms)
{
	struct timespec value = { ms / 1000U, (long)(ms % 1000U) * 1000000L };
	while (nanosleep(&value, &value) && errno == EINTR) {}
}

static int parse_unsigned(const char *text, unsigned *value)
{
	char *end;
	unsigned long parsed = strtoul(text, &end, 0);
	if (!*text || *end || parsed > UINT32_MAX) return -EINVAL;
	*value = (unsigned)parsed;
	return 0;
}

static void usage(FILE *stream)
{
	fputs("usage: visionarm-capture --prefix PATH [--count N] "
	      "[--interval-ms N] [--buffer 0|1]\n"
	      "       visionarm-capture --self-test\n"
	      "Capture uses a short DMA pause so the selected DDR frame is stable.\n",
	      stream);
}

static int parse_options(int argc, char **argv, struct options *options)
{
	int index;
	*options = (struct options) { .count = 1U, .interval_ms = 250U };
	for (index = 1; index < argc; index++) {
		if (!strcmp(argv[index], "--prefix") && ++index < argc)
			options->prefix = argv[index];
		else if (!strcmp(argv[index], "--count") && ++index < argc) {
			if (parse_unsigned(argv[index], &options->count) || !options->count) return -EINVAL;
		} else if (!strcmp(argv[index], "--interval-ms") && ++index < argc) {
			if (parse_unsigned(argv[index], &options->interval_ms)) return -EINVAL;
		} else if (!strcmp(argv[index], "--buffer") && ++index < argc) {
			if (parse_unsigned(argv[index], &options->buffer_index) || options->buffer_index > 1U)
				return -EINVAL;
		} else if (!strcmp(argv[index], "--self-test"))
			options->self_test = 1;
		else return -EINVAL;
	}
	if (!options->self_test && !options->prefix) return -EINVAL;
	return 0;
}

static int map_physical(int fd, uint32_t address, size_t bytes, struct mapping *mapping)
{
	long page_size = sysconf(_SC_PAGESIZE);
	uint32_t page, offset;
	if (page_size <= 0 || (page_size & (page_size - 1)) != 0) return -EINVAL;
	page = address & ~((uint32_t)page_size - 1U);
	offset = address - page;
	mapping->length = offset + bytes;
	mapping->base = mmap(NULL, mapping->length, PROT_READ | PROT_WRITE,
			     MAP_SHARED, fd, (off_t)page);
	if (mapping->base == MAP_FAILED) return -errno;
	mapping->ptr = (volatile uint8_t *)mapping->base + offset;
	return 0;
}

static void unmap_physical(struct mapping *mapping)
{
	if (mapping->base && mapping->base != MAP_FAILED)
		munmap(mapping->base, mapping->length);
}

static int write_all(int fd, const uint8_t *data, size_t bytes)
{
	while (bytes) {
		ssize_t written = write(fd, data, bytes);
		if (written < 0) {
			if (errno == EINTR) continue;
			return -errno;
		}
		data += written;
		bytes -= (size_t)written;
	}
	return 0;
}

static int save_frame(const char *prefix, unsigned index, const uint8_t *data,
		      size_t bytes, uint32_t frame_count, uint32_t status,
		      uint32_t address, unsigned buffer_index)
{
	char raw_path[512], tmp_path[520], meta_path[512];
	FILE *metadata;
	int fd, result;
	if (snprintf(raw_path, sizeof(raw_path), "%s_%04u.rgb565", prefix, index) >= (int)sizeof(raw_path) ||
	    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", raw_path) >= (int)sizeof(tmp_path) ||
	    snprintf(meta_path, sizeof(meta_path), "%s_%04u.ini", prefix, index) >= (int)sizeof(meta_path))
		return -ENAMETOOLONG;
	fd = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) return -errno;
	result = write_all(fd, data, bytes);
	if (close(fd) && !result) result = -errno;
	if (result) { unlink(tmp_path); return result; }
	if (rename(tmp_path, raw_path)) { unlink(tmp_path); return -errno; }
	metadata = fopen(meta_path, "w");
	if (!metadata) return -errno;
	fprintf(metadata,
		"[frame]\nwidth=640\nheight=480\nstride=1280\nformat=rgb565le\n"
		"buffer=%u\nphysical_address=0x%08x\nframe_count=%u\n"
		"camera_status=0x%08x\nstable_dma_pause=1\n",
		buffer_index, address, frame_count, status);
	if (fclose(metadata)) return -errno;
	printf("saved %s frame_count=%u status=0x%08x\n", raw_path, frame_count, status);
	return 0;
}

static int wait_new_frame(volatile uint32_t *registers, uint32_t previous)
{
	unsigned attempt;
	for (attempt = 0; attempt < 80U; attempt++) {
		if (registers[REG_FRAME_COUNT] != previous) return 0;
		sleep_ms(25U);
	}
	return -ETIMEDOUT;
}

static int self_test(void)
{
	unsigned value;
	if (parse_unsigned("17", &value) || value != 17U) return 1;
	if (!parse_unsigned("bad", &value)) return 1;
	puts("VISIONARM_CAPTURE_SELF_TEST_PASS");
	return 0;
}

int main(int argc, char **argv)
{
	struct options options;
	struct mapping registers_map = {0}, frame_map = {0};
	volatile uint32_t *registers;
	uint8_t *snapshot = NULL;
	uint32_t address, original_control = 0;
	unsigned index;
	size_t frame_bytes;
	int memfd = -1, result = 1;

	if (parse_options(argc, argv, &options)) { usage(stderr); return 2; }
	if (options.self_test) return self_test();
	memfd = open("/dev/mem", O_RDWR | O_SYNC);
	if (memfd < 0) { perror("/dev/mem"); goto out; }
	result = map_physical(memfd, CAM_BASE, 0x40U, &registers_map);
	if (result) goto out;
	registers = (volatile uint32_t *)registers_map.ptr;
	if (registers[REG_MAGIC] != CAM_MAGIC ||
	    registers[REG_OUTPUT_SIZE] != ((EXPECTED_HEIGHT << 16) | EXPECTED_WIDTH) ||
	    registers[REG_STRIDE] != EXPECTED_STRIDE) {
		fprintf(stderr, "unsupported camera registers magic=0x%08x size=0x%08x stride=%u\n",
			registers[REG_MAGIC], registers[REG_OUTPUT_SIZE], registers[REG_STRIDE]);
		result = -ENODEV; goto out;
	}
	address = registers[options.buffer_index ? REG_FRAME1 : REG_FRAME0];
	frame_bytes = (size_t)EXPECTED_STRIDE * EXPECTED_HEIGHT;
	result = map_physical(memfd, address, frame_bytes, &frame_map);
	if (result) goto out;
	snapshot = malloc(frame_bytes);
	if (!snapshot) { result = -ENOMEM; goto out; }
	original_control = registers[REG_CTRL];

	for (index = 0; index < options.count; index++) {
		uint32_t before, captured_count, captured_status;
		registers[REG_CTRL] = 1U;
		before = registers[REG_FRAME_COUNT];
		result = wait_new_frame(registers, before);
		if (result) goto restore;
		registers[REG_CTRL] = 0U;
		sleep_ms(50U);
		captured_count = registers[REG_FRAME_COUNT];
		captured_status = registers[REG_STATUS];
		memcpy(snapshot, (const void *)frame_map.ptr, frame_bytes);
		result = save_frame(options.prefix, index, snapshot, frame_bytes,
				    captured_count, captured_status, address,
				    options.buffer_index);
		if (result) goto restore;
		if (index + 1U < options.count) sleep_ms(options.interval_ms);
	}
	result = 0;

restore:
	registers[REG_CTRL] = original_control & 1U;
out:
	if (result < 0) fprintf(stderr, "visionarm-capture: %s\n", strerror(-result));
	free(snapshot);
	unmap_physical(&frame_map);
	unmap_physical(&registers_map);
	if (memfd >= 0) close(memfd);
	return result ? 1 : 0;
}
