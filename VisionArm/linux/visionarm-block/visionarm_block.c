/* SPDX-License-Identifier: MIT */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include "xnpu.h"
#include "calibration.h"

#define CAM_BASE 0x1fd0e100U
#define CAM_CTRL 0U
#define CAM_ACTIVITY 2U
#define CAM_FRAME0 5U
#define UART_ADDR 0x1fd0e010U
#define WIDTH 640
#define HEIGHT 480
#define STRIDE 1280
#define FRAME_BYTES (STRIDE * HEIGHT)
#define INPUT_BYTES (3U * 34U * 34U)

enum color { RED, GREEN, BLUE };
struct box { int x0, y0, x1, y1; unsigned count; };
struct map { void *base; size_t length; volatile uint8_t *ptr; };
struct opts {
	enum color color; const char *model; const char *calibration;
	unsigned class_id, loops;
	bool control, invert_x, invert_y, self_test, check_calibration;
};

static void msleep(unsigned ms)
{
	struct timespec t = { ms / 1000U, (long)(ms % 1000U) * 1000000L };
	while (nanosleep(&t, &t) && errno == EINTR) {}
}

static int map_phys(int fd, uint32_t address, size_t bytes, struct map *m)
{
	long ps = sysconf(_SC_PAGESIZE);
	uint32_t page, offset;
	if (ps <= 0) return -EINVAL;
	page = address & ~((uint32_t)ps - 1U); offset = address - page;
	m->length = offset + bytes;
	m->base = mmap(NULL, m->length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, page);
	if (m->base == MAP_FAILED) return -errno;
	m->ptr = (volatile uint8_t *)m->base + offset;
	return 0;
}

static void unmap_phys(struct map *m)
{
	if (m->base && m->base != MAP_FAILED) munmap(m->base, m->length);
}

static void rgb(uint16_t p, uint8_t *r, uint8_t *g, uint8_t *b)
{
	unsigned rv = (p >> 11) & 31U, gv = (p >> 5) & 63U, bv = p & 31U;
	*r = (uint8_t)((rv << 3) | (rv >> 2));
	*g = (uint8_t)((gv << 2) | (gv >> 4));
	*b = (uint8_t)((bv << 3) | (bv >> 2));
}

static bool match(enum color c, uint8_t r, uint8_t g, uint8_t b)
{
	if (c == RED) return r >= 80U && r >= g + 35U && r >= b + 35U;
	if (c == GREEN) return g >= 70U && g >= r + 25U && g >= b + 25U;
	return b >= 70U && b >= r + 30U && b >= g + 30U;
}

static bool locate(const volatile uint8_t *frame, enum color c, struct box *out)
{
	struct box b = { WIDTH, HEIGHT, -1, -1, 0U };
	int x, y;
	for (y = 0; y < HEIGHT; y += 2) for (x = 0; x < WIDTH; x += 2) {
		size_t o = (size_t)y * STRIDE + (size_t)x * 2U;
		uint16_t p = (uint16_t)frame[o] | ((uint16_t)frame[o + 1U] << 8);
		uint8_t r, g, bl; rgb(p, &r, &g, &bl);
		if (!match(c, r, g, bl)) continue;
		if (x < b.x0) b.x0 = x;
		if (x > b.x1) b.x1 = x;
		if (y < b.y0) b.y0 = y;
		if (y > b.y1) b.y1 = y;
		b.count++;
	}
	if (b.count < 120U || b.x1 <= b.x0 || b.y1 <= b.y0) return false;
	*out = b; return true;
}

static void crop_chw(const volatile uint8_t *frame, const struct box *b,
			 uint8_t output[INPUT_BYTES])
{
	int x, y, c; memset(output, 128, INPUT_BYTES);
	for (y = 0; y < 32; y++) for (x = 0; x < 32; x++) {
		int sx = b->x0 + x * (b->x1 - b->x0 + 1) / 32;
		int sy = b->y0 + y * (b->y1 - b->y0 + 1) / 32;
		size_t o = (size_t)sy * STRIDE + (size_t)sx * 2U;
		uint16_t p = (uint16_t)frame[o] | ((uint16_t)frame[o + 1U] << 8);
		uint8_t v[3]; rgb(p, &v[0], &v[1], &v[2]);
		for (c = 0; c < 3; c++) output[c * 34 * 34 + (y + 1) * 34 + x + 1] = v[c];
	}
}

static int infer(struct xnpu_device *dev, const struct xnpu_package *pkg,
		 const uint8_t input[INPUT_BYTES], unsigned *top, unsigned *margin)
{
	uint8_t output[256]; struct xnpu_result_v2 result; size_t i;
	unsigned best = 0, second = 0; int rc;
	memset(&result, 0, sizeof(result));
	rc = xnpu_device_infer(dev, pkg, input, INPUT_BYTES, 2000U, 1,
			       output, sizeof(output), &result);
	if (rc) return rc;
	if (!result.result_bytes || result.result_bytes > sizeof(output)) return -EIO;
	for (i = 1; i < result.result_bytes; i++) {
		if (output[i] > output[best]) { second = best; best = (unsigned)i; }
		else if (second == best || output[i] > output[second]) second = (unsigned)i;
	}
	*top = best; *margin = (unsigned)output[best] - output[second]; return 0;
}

static void usage(FILE *f)
{
	fputs("usage: visionarm-block [--color red|green|blue] [--model FILE] "
	      "[--class N] [--calibration FILE] [--loops N] [--control] "
	      "[--invert-x] [--invert-y]\n"
	      "       visionarm-block --calibration FILE --check-calibration\n", f);
}

static int parse(int argc, char **argv, struct opts *o)
{
	int i; char *end; memset(o, 0, sizeof(*o));
	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--color") && ++i < argc) {
			if (!strcmp(argv[i], "red")) o->color = RED;
			else if (!strcmp(argv[i], "green")) o->color = GREEN;
			else if (!strcmp(argv[i], "blue")) o->color = BLUE; else return -1;
		} else if (!strcmp(argv[i], "--model") && ++i < argc) o->model = argv[i];
		else if (!strcmp(argv[i], "--calibration") && ++i < argc) o->calibration = argv[i];
		else if ((!strcmp(argv[i], "--class") || !strcmp(argv[i], "--loops")) && i + 1 < argc) {
			bool is_class = !strcmp(argv[i], "--class"); unsigned long n = strtoul(argv[++i], &end, 0);
			if (*end) return -1;
			if (is_class) o->class_id = (unsigned)n;
			else o->loops = (unsigned)n;
		} else if (!strcmp(argv[i], "--control")) o->control = true;
		else if (!strcmp(argv[i], "--invert-x")) o->invert_x = true;
		else if (!strcmp(argv[i], "--invert-y")) o->invert_y = true;
		else if (!strcmp(argv[i], "--self-test")) o->self_test = true;
		else if (!strcmp(argv[i], "--check-calibration")) o->check_calibration = true;
		else return -1;
	}
	return 0;
}

static int self_test(void)
{
	uint8_t *f = calloc(1, FRAME_BYTES); struct box b; int x, y, ok;
	if (!f) return 1;
	for (y = 100; y < 220; y++) for (x = 200; x < 360; x++) {
		size_t p = (size_t)y * STRIDE + x * 2U; f[p] = 0; f[p + 1] = 0xf8;
	}
	ok = locate(f, RED, &b) && b.x0 == 200 && b.y0 == 100 && b.x1 == 358 && b.y1 == 218;
	ok = ok && !visionarm_calibration_self_test();
	free(f); puts(ok ? "VISIONARM_BLOCK_SELF_TEST_PASS" : "VISIONARM_BLOCK_SELF_TEST_FAIL");
	return !ok;
}

int main(int argc, char **argv)
{
	struct opts o; struct map regs = {0}, fb = {0}, uart = {0};
	struct xnpu_package pkg; struct xnpu_device dev; volatile uint32_t *cam;
	struct visionarm_calibration calibration;
	char calibration_error[160];
	int fd = -1, rc = 1; unsigned frame = 0, stable = 0, moves = 0;
	bool npu = false, calibrated = false;
	memset(&pkg, 0, sizeof(pkg)); memset(&dev, 0, sizeof(dev)); dev.fd = -1;
	if (parse(argc, argv, &o)) { usage(stderr); return 2; }
	if (o.self_test) return self_test();
	if (o.check_calibration && !o.calibration) {
		fputs("--check-calibration requires --calibration\n", stderr);
		return 2;
	}
	if (o.calibration) {
		rc = visionarm_calibration_load(o.calibration, &calibration,
						calibration_error, sizeof(calibration_error));
		if (rc) {
			fprintf(stderr, "calibration: %s\n", calibration_error);
			return 2;
		}
		if (o.invert_x) calibration.invert_axis[0] = !calibration.invert_axis[0];
		if (o.invert_y) calibration.invert_axis[1] = !calibration.invert_axis[1];
		calibrated = true;
	}
	if (o.check_calibration) {
		printf("CALIBRATION_CHECK_PASS axes=%c,%c work_zero=%d,%d,%d\n",
		       calibration.alignment_axes[0], calibration.alignment_axes[1],
		       calibration.work_zero[0], calibration.work_zero[1], calibration.work_zero[2]);
		return 0;
	}
	if (o.control && (!o.model || !calibrated)) {
		fputs("--control requires --model and a validated --calibration file\n", stderr);
		return 2;
	}
	if (o.model) {
		rc = xnpu_package_open(&pkg, o.model); if (rc) goto done;
		if (pkg.info.task != XNPU_TASK_CLASSIFICATION || pkg.info.input_mode != XNPU_INPUT_PACKED_PRELOAD ||
		    pkg.info.input.width != 34U || pkg.info.input.height != 34U || pkg.info.input.channels != 3U ||
		    pkg.info.input.layout != XNPU_LAYOUT_NCHW || pkg.info.input.bytes != INPUT_BYTES) {
			fputs("model must use packed 34x34x3 NCHW u8 input\n", stderr); rc = 2; goto done;
		}
		rc = xnpu_device_open(&dev, "/dev/xnpu"); if (rc) goto done;
		rc = xnpu_device_load_model(&dev, &pkg); if (rc) goto done; npu = true;
	}
	fd = open("/dev/mem", O_RDWR | O_SYNC); if (fd < 0) { perror("/dev/mem"); goto done; }
	if (map_phys(fd, CAM_BASE, 0x40, &regs)) goto done;
	cam = (volatile uint32_t *)regs.ptr;
	if (map_phys(fd, cam[CAM_FRAME0], FRAME_BYTES, &fb)) goto done;
	if (o.control && map_phys(fd, UART_ADDR, 4, &uart)) goto done;
	cam[CAM_CTRL] = 1; msleep(1000); puts(o.control ? "mode=CONTROL" : "mode=OBSERVE");
	while (!o.loops || frame < o.loops) {
		struct box b; uint32_t activity = cam[CAM_ACTIVITY]; unsigned wait;
		for (wait = 0; wait < 20 && cam[CAM_ACTIVITY] == activity; wait++) msleep(25);
		if (!locate(fb.ptr, o.color, &b)) { stable = 0; printf("frame=%u target=none\n", frame++); continue; }
		if (npu) {
			uint8_t input[INPUT_BYTES]; unsigned top, margin; crop_chw(fb.ptr, &b, input);
			rc = infer(&dev, &pkg, input, &top, &margin); if (rc) goto done;
			stable = top == o.class_id && margin >= 8U ? stable + 1U : 0U;
			printf("frame=%u bbox=%d,%d,%d,%d class=%u margin=%u stable=%u\n",
			       frame, b.x0, b.y0, b.x1, b.y1, top, margin, stable);
		} else printf("frame=%u bbox=%d,%d,%d,%d pixels=%u npu=disabled\n",
			      frame, b.x0, b.y0, b.x1, b.y1, b.count);
		if (calibrated) {
			double table_x, table_y;
			if (!visionarm_pixel_to_table(&calibration, (b.x0 + b.x1) / 2.0,
						  (b.y0 + b.y1) / 2.0, &table_x, &table_y))
				printf("table_mm=%.3f,%.3f\n", table_x, table_y);
		}
		if (o.control && stable >= (unsigned)calibration.stable_frames) {
			double step0, step1;
			int command = visionarm_alignment_command(&calibration,
					(b.x0 + b.x1) / 2.0, (b.y0 + b.y1) / 2.0,
					calibration.gripper_target_u,
					calibration.gripper_target_v, &step0, &step1);
			uint8_t cmd = command > 0 ? (uint8_t)command : 0U;
			if (command < 0) { fputs("ERROR invalid calibration transform\n", stderr); rc = 1; goto done; }
			if (!cmd) puts("state=ALIGNED");
			else if (moves++ >= (unsigned)calibration.max_align_moves) {
				fputs("ERROR max_moves\n", stderr); rc = 1; goto done;
			} else {
				*(volatile uint32_t *)uart.ptr = cmd;
				printf("state=ALIGN command=%c estimated_steps=%.1f,%.1f\n",
				       cmd, step0, step1);
				msleep(400);
			}
			stable = 0;
		}
		frame++; msleep(250);
	}
	rc = 0;
done:
	if (rc < 0) fprintf(stderr, "visionarm-block: %s\n", strerror(-rc));
	if (dev.fd >= 0) xnpu_device_close(&dev);
	xnpu_package_close(&pkg);
	unmap_phys(&uart); unmap_phys(&fb); unmap_phys(&regs); if (fd >= 0) close(fd);
	return rc ? 1 : 0;
}
