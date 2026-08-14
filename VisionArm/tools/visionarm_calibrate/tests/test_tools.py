import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from calibrate_arm import fit_jacobian
from calibrate_workspace import fit_homography
from convert_rgb565 import decode_rgb565
from calibration_io import new_config
from validate_calibration import validate


class CalibrationToolsTest(unittest.TestCase):
    def test_rgb565_primary_colors(self):
        words = np.asarray([0xF800, 0x07E0, 0x001F], dtype="<u2")
        image = decode_rgb565(words.tobytes(), 3, 1, 6)
        self.assertEqual(image[0].tolist(), [[0, 0, 255], [0, 255, 0], [255, 0, 0]])

    def test_homography(self):
        image = np.asarray([[0, 0], [100, 0], [100, 50], [0, 50], [40, 20]], np.float64)
        table = image * np.asarray([2.0, 3.0]) + np.asarray([10.0, -5.0])
        matrix, errors = fit_homography(image, table)
        self.assertLess(float(errors.max()), 1e-6)
        self.assertAlmostEqual(matrix[0, 0] / matrix[2, 2], 2.0, places=6)

    def test_arm_jacobian(self):
        motions = np.asarray([[100, 0], [0, 100], [-100, 0], [0, -100], [100, 100]], np.float64)
        expected = np.asarray([[0.2, 0.05], [-0.1, 0.3]], np.float64)
        pixels = motions @ expected.T
        fitted, errors, condition = fit_jacobian(motions, pixels)
        np.testing.assert_allclose(fitted, expected, atol=1e-12)
        self.assertLess(float(errors.max()), 1e-10)
        self.assertLess(condition, 2.0)

    def test_complete_config_validation(self):
        cfg = new_config()
        cfg["camera"] = {
            "matrix": "100,0,320,0,100,240,0,0,1",
            "distortion": "0,0,0,0,0", "rms_px": "0.2",
        }
        cfg["workspace"] = {
            "homography": "1,0,0,0,1,0,0,0,1", "max_error_mm": "0.5",
        }
        cfg["arm"] = {
            "alignment_axes": "x,z", "jacobian": "0.2,0,0,0.3",
            "gripper_target_pixel": "320,240",
            "max_error_px": "1", "jacobian_condition": "1.5",
            "work_zero_x": "100", "work_zero_y": "200", "work_zero_z": "300",
            "invert_x": "0", "invert_y": "0", "invert_z": "0",
            "max_x_steps": "1000", "max_y_steps": "1000", "max_z_steps": "1000",
        }
        self.assertEqual(validate(cfg, 1.0, 3.0, 5.0, 20.0), [])


if __name__ == "__main__":
    unittest.main()
