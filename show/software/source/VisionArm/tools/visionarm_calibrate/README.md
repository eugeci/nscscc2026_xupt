# VisionArm PC calibration tools

These tools run on the development computer. They never move hardware by
themselves and keep `meta.validated=0` until explicit validation succeeds.

```sh
python3 convert_rgb565.py frame_0000.rgb565 frame_0000.png
python3 calibrate_camera.py --images 'checkerboard/*.png' \
  --columns 9 --rows 6 --square-mm 20 --output calibration.ini
python3 calibrate_workspace.py --points workspace.csv --config calibration.ini
python3 calibrate_arm.py --samples arm.csv --axes x,z \
  --work-zero 1000,2000,1500 --max-steps 8000,9000,10000 \
  --target-pixel 315,238 --config calibration.ini
python3 validate_calibration.py calibration.ini --mark-valid
```

`workspace.csv` columns are `u,v,x_mm,y_mm`. Arm samples use
`d<axis>_steps,d<axis>_steps,u0,v0,u1,v1`; for `--axes x,z` the first two
columns are `dx_steps,dz_steps`. Signed motion follows the UART command map:
positive X/Y/Z means command `1/3/5`, and negative means `2/4/6`.

`calibrate_arm.py` only fits recorded CSV data; it never sends motor commands.
Automatic motion/capture orchestration is intentionally deferred until the
real axis directions and the ESP32-to-FPGA acknowledgement path are verified.

Run offline tests with:

```sh
python3 -m unittest discover -s tests -v
```
