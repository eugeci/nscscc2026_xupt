/* SPDX-License-Identifier: MIT */
#define _POSIX_C_SOURCE 200809L
#include "calibration.h"

#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum required_field {
	HAVE_VERSION = 1U << 0, HAVE_VALIDATED = 1U << 1,
	HAVE_WIDTH = 1U << 2, HAVE_HEIGHT = 1U << 3,
	HAVE_CAMERA = 1U << 4, HAVE_DISTORTION = 1U << 5,
	HAVE_HOMOGRAPHY = 1U << 6, HAVE_AXES = 1U << 7,
	HAVE_JACOBIAN = 1U << 8, HAVE_WORK_ZERO = 1U << 9,
	HAVE_INVERT = 1U << 10, HAVE_MAX_STEPS = 1U << 11,
	HAVE_GRASP = 1U << 12, HAVE_TARGET_PIXEL = 1U << 13
};

#define REQUIRED_FIELDS ((1U << 14) - 1U)

static char *trim(char *text)
{
	char *end;
	while (isspace((unsigned char)*text)) text++;
	end = text + strlen(text);
	while (end > text && isspace((unsigned char)end[-1])) end--;
	*end = '\0';
	return text;
}

static int parse_int(const char *text, int *value)
{
	char *end;
	long parsed;
	errno = 0;
	parsed = strtol(text, &end, 0);
	while (isspace((unsigned char)*end)) end++;
	if (errno || !*text || *end || parsed < -2147483647L - 1L || parsed > 2147483647L)
		return -EINVAL;
	*value = (int)parsed;
	return 0;
}

static int parse_doubles(const char *text, double *values, size_t count)
{
	size_t index;
	for (index = 0; index < count; index++) {
		char *end;
		errno = 0;
		values[index] = strtod(text, &end);
		if (errno || end == text || !isfinite(values[index])) return -EINVAL;
		while (isspace((unsigned char)*end)) end++;
		if (index + 1U < count) {
			if (*end != ',') return -EINVAL;
			text = end + 1;
		} else {
			if (*end) return -EINVAL;
		}
	}
	return 0;
}

static int axis_index(char axis)
{
	return axis == 'x' ? 0 : axis == 'y' ? 1 : axis == 'z' ? 2 : -1;
}

static void set_error(char *error, size_t size, const char *message)
{
	if (error && size) snprintf(error, size, "%s", message);
}

static int parse_entry(const char *section, const char *key, const char *value,
		       struct visionarm_calibration *c, unsigned *fields)
{
	int parsed;
	if (!strcmp(section, "meta")) {
		if (!strcmp(key, "version")) { if (parse_int(value, &c->version)) return -EINVAL; *fields |= HAVE_VERSION; }
		else if (!strcmp(key, "validated")) { if (parse_int(value, &c->validated)) return -EINVAL; *fields |= HAVE_VALIDATED; }
		else if (!strcmp(key, "image_width")) { if (parse_int(value, &c->image_width)) return -EINVAL; *fields |= HAVE_WIDTH; }
		else if (!strcmp(key, "image_height")) { if (parse_int(value, &c->image_height)) return -EINVAL; *fields |= HAVE_HEIGHT; }
	} else if (!strcmp(section, "camera")) {
		if (!strcmp(key, "matrix")) { if (parse_doubles(value, c->camera, 9)) return -EINVAL; *fields |= HAVE_CAMERA; }
		else if (!strcmp(key, "distortion")) { if (parse_doubles(value, c->distortion, 5)) return -EINVAL; *fields |= HAVE_DISTORTION; }
	} else if (!strcmp(section, "workspace") && !strcmp(key, "homography")) {
		if (parse_doubles(value, c->homography, 9)) return -EINVAL;
		*fields |= HAVE_HOMOGRAPHY;
	} else if (!strcmp(section, "arm")) {
		if (!strcmp(key, "alignment_axes")) {
			if (strlen(value) != 3U || value[1] != ',' || axis_index(value[0]) < 0 ||
			    axis_index(value[2]) < 0 || value[0] == value[2]) return -EINVAL;
			c->alignment_axes[0] = value[0]; c->alignment_axes[1] = value[2]; *fields |= HAVE_AXES;
		} else if (!strcmp(key, "jacobian")) {
			if (parse_doubles(value, c->jacobian, 4)) return -EINVAL;
			*fields |= HAVE_JACOBIAN;
		} else if (!strcmp(key, "gripper_target_pixel")) {
			double target[2];
			if (parse_doubles(value, target, 2)) return -EINVAL;
			c->gripper_target_u = target[0]; c->gripper_target_v = target[1];
			*fields |= HAVE_TARGET_PIXEL;
		} else if (!strncmp(key, "work_zero_", 10) && (parsed = axis_index(key[10])) >= 0) {
			if (parse_int(value, &c->work_zero[parsed])) return -EINVAL;
			if (c->work_zero[0] >= 0 && c->work_zero[1] >= 0 && c->work_zero[2] >= 0) *fields |= HAVE_WORK_ZERO;
		} else if (!strncmp(key, "invert_", 7) && (parsed = axis_index(key[7])) >= 0) {
			if (parse_int(value, &c->invert_axis[parsed])) return -EINVAL;
			if (c->invert_axis[0] >= 0 && c->invert_axis[1] >= 0 && c->invert_axis[2] >= 0) *fields |= HAVE_INVERT;
		} else if (!strncmp(key, "max_", 4) && strlen(key) == 11U && !strcmp(key + 5, "_steps") &&
			   (parsed = axis_index(key[4])) >= 0) {
			if (parse_int(value, &c->max_steps[parsed])) return -EINVAL;
			if (c->max_steps[0] > 0 && c->max_steps[1] > 0 && c->max_steps[2] > 0) *fields |= HAVE_MAX_STEPS;
		}
	} else if (!strcmp(section, "grasp")) {
		if (!strcmp(key, "align_deadband_px")) { if (parse_int(value, &c->align_deadband_px)) return -EINVAL; }
		else if (!strcmp(key, "stable_frames")) { if (parse_int(value, &c->stable_frames)) return -EINVAL; }
		else if (!strcmp(key, "max_align_moves")) { if (parse_int(value, &c->max_align_moves)) return -EINVAL; }
		if (c->align_deadband_px > 0 && c->stable_frames >= 2 && c->max_align_moves > 0) *fields |= HAVE_GRASP;
	}
	return 0;
}

int visionarm_calibration_load(const char *path, struct visionarm_calibration *c,
			       char *error, size_t error_size)
{
	char line[1024], section[32] = "";
	unsigned fields = 0U, line_number = 0U;
	FILE *stream;
	memset(c, 0, sizeof(*c));
	c->work_zero[0] = c->work_zero[1] = c->work_zero[2] = -1;
	c->invert_axis[0] = c->invert_axis[1] = c->invert_axis[2] = -1;
	stream = fopen(path, "r");
	if (!stream) { set_error(error, error_size, strerror(errno)); return -errno; }
	while (fgets(line, sizeof(line), stream)) {
		char *text = trim(line), *separator, *closing;
		line_number++;
		if (!*text || *text == '#' || *text == ';') continue;
		if (*text == '[') {
			closing = strchr(text, ']');
			if (!closing || closing[1]) goto malformed;
			*closing = '\0';
			if (strlen(text + 1) >= sizeof(section)) goto malformed;
			strcpy(section, text + 1);
			continue;
		}
		separator = strchr(text, '=');
		if (!separator || !*section) goto malformed;
		*separator = '\0';
		if (parse_entry(section, trim(text), trim(separator + 1), c, &fields)) goto malformed;
	}
	if (ferror(stream)) { fclose(stream); set_error(error, error_size, "read error"); return -EIO; }
	fclose(stream);
	if (fields != REQUIRED_FIELDS) { set_error(error, error_size, "missing required calibration fields"); return -EINVAL; }
	if (c->version != 1 || !c->validated || c->image_width != 640 || c->image_height != 480) {
		set_error(error, error_size, "calibration is not validated for 640x480 version 1"); return -EPERM;
	}
	if (c->gripper_target_u < 0.0 || c->gripper_target_u >= c->image_width ||
	    c->gripper_target_v < 0.0 || c->gripper_target_v >= c->image_height) {
		set_error(error, error_size, "gripper target pixel is outside the image"); return -ERANGE;
	}
	if (fabs(c->camera[0] * c->camera[4] * c->camera[8]) < 1e-12 ||
	    fabs(c->homography[0] * (c->homography[4] * c->homography[8] - c->homography[5] * c->homography[7]) -
		 c->homography[1] * (c->homography[3] * c->homography[8] - c->homography[5] * c->homography[6]) +
		 c->homography[2] * (c->homography[3] * c->homography[7] - c->homography[4] * c->homography[6])) < 1e-12 ||
	    fabs(c->jacobian[0] * c->jacobian[3] - c->jacobian[1] * c->jacobian[2]) < 1e-12) {
		set_error(error, error_size, "singular calibration matrix"); return -EINVAL;
	}
	return 0;
malformed:
	fclose(stream);
	if (error && error_size) snprintf(error, error_size, "invalid calibration line %u", line_number);
	return -EINVAL;
}

static void undistort_pixel(const struct visionarm_calibration *c, double u, double v,
			    double *undistorted_u, double *undistorted_v)
{
	double fx = c->camera[0], fy = c->camera[4], cx = c->camera[2], cy = c->camera[5];
	double xd = (u - cx) / fx, yd = (v - cy) / fy, x = xd, y = yd;
	double k1 = c->distortion[0], k2 = c->distortion[1];
	double p1 = c->distortion[2], p2 = c->distortion[3], k3 = c->distortion[4];
	int iteration;
	for (iteration = 0; iteration < 6; iteration++) {
		double r2 = x * x + y * y, radial = 1.0 + k1 * r2 + k2 * r2 * r2 + k3 * r2 * r2 * r2;
		double dx = 2.0 * p1 * x * y + p2 * (r2 + 2.0 * x * x);
		double dy = p1 * (r2 + 2.0 * y * y) + 2.0 * p2 * x * y;
		if (fabs(radial) < 1e-12) break;
		x = (xd - dx) / radial; y = (yd - dy) / radial;
	}
	*undistorted_u = fx * x + c->camera[1] * y + cx;
	*undistorted_v = fy * y + cy;
}

int visionarm_pixel_to_table(const struct visionarm_calibration *c,
			     double u, double v, double *x_mm, double *y_mm)
{
	double uu, vv, denominator;
	undistort_pixel(c, u, v, &uu, &vv);
	denominator = c->homography[6] * uu + c->homography[7] * vv + c->homography[8];
	if (fabs(denominator) < 1e-12) return -ERANGE;
	*x_mm = (c->homography[0] * uu + c->homography[1] * vv + c->homography[2]) / denominator;
	*y_mm = (c->homography[3] * uu + c->homography[4] * vv + c->homography[5]) / denominator;
	return isfinite(*x_mm) && isfinite(*y_mm) ? 0 : -ERANGE;
}

static int command_for_axis(char axis, double steps, int invert)
{
	int positive = steps >= 0.0;
	if (invert) positive = !positive;
	if (axis == 'x') return positive ? '1' : '2';
	if (axis == 'y') return positive ? '3' : '4';
	return positive ? '5' : '6';
}

int visionarm_alignment_command(const struct visionarm_calibration *c,
				double current_u, double current_v,
				double target_u, double target_v,
				double *axis0_steps, double *axis1_steps)
{
	double du = target_u - current_u, dv = target_v - current_v;
	double determinant = c->jacobian[0] * c->jacobian[3] - c->jacobian[1] * c->jacobian[2];
	int index0 = axis_index(c->alignment_axes[0]), index1 = axis_index(c->alignment_axes[1]);
	if (fabs(du) <= c->align_deadband_px && fabs(dv) <= c->align_deadband_px) {
		*axis0_steps = *axis1_steps = 0.0; return 0;
	}
	if (fabs(determinant) < 1e-12 || index0 < 0 || index1 < 0) return -EINVAL;
	*axis0_steps = (c->jacobian[3] * du - c->jacobian[1] * dv) / determinant;
	*axis1_steps = (-c->jacobian[2] * du + c->jacobian[0] * dv) / determinant;
	if (fabs(*axis0_steps) >= fabs(*axis1_steps))
		return command_for_axis(c->alignment_axes[0], *axis0_steps, c->invert_axis[index0]);
	return command_for_axis(c->alignment_axes[1], *axis1_steps, c->invert_axis[index1]);
}

int visionarm_calibration_self_test(void)
{
	struct visionarm_calibration c;
	double x, y, s0, s1;
	int command;
	memset(&c, 0, sizeof(c));
	c.camera[0] = c.camera[4] = c.camera[8] = 1.0;
	c.homography[0] = 2.0; c.homography[2] = 10.0;
	c.homography[4] = 3.0; c.homography[5] = -5.0; c.homography[8] = 1.0;
	c.alignment_axes[0] = 'x'; c.alignment_axes[1] = 'z';
	c.gripper_target_u = 320.0; c.gripper_target_v = 240.0;
	c.jacobian[0] = 0.2; c.jacobian[1] = 0.0; c.jacobian[2] = 0.0; c.jacobian[3] = 0.3;
	c.align_deadband_px = 5;
	if (visionarm_pixel_to_table(&c, 4.0, 5.0, &x, &y) || fabs(x - 18.0) > 1e-9 || fabs(y - 10.0) > 1e-9)
		return 1;
	command = visionarm_alignment_command(&c, 100.0, 100.0, 140.0, 103.0, &s0, &s1);
	if (command != '1' || fabs(s0 - 200.0) > 1e-9 || fabs(s1 - 10.0) > 1e-9) return 1;
	return 0;
}
