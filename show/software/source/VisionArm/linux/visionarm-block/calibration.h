/* SPDX-License-Identifier: MIT */
#ifndef VISIONARM_CALIBRATION_H
#define VISIONARM_CALIBRATION_H

#include <stddef.h>

struct visionarm_calibration {
	int version;
	int validated;
	int image_width;
	int image_height;
	double camera[9];
	double distortion[5];
	double homography[9];
	char alignment_axes[2];
	double jacobian[4];
	double gripper_target_u;
	double gripper_target_v;
	int work_zero[3];
	int invert_axis[3];
	int max_steps[3];
	int align_deadband_px;
	int stable_frames;
	int max_align_moves;
};

int visionarm_calibration_load(const char *path,
			       struct visionarm_calibration *calibration,
			       char *error, size_t error_size);
int visionarm_pixel_to_table(const struct visionarm_calibration *calibration,
			     double u, double v, double *x_mm, double *y_mm);
int visionarm_alignment_command(const struct visionarm_calibration *calibration,
				double current_u, double current_v,
				double target_u, double target_v,
				double *axis0_steps, double *axis1_steps);
int visionarm_calibration_self_test(void);

#endif
