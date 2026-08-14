# VisionArm frame capture

`visionarm-capture` saves stable 640x480 RGB565LE frames and an INI sidecar
containing the camera frame counter and status.  Because the current FPGA
registers do not expose the active VDMA write-buffer index, capture briefly
pauses camera DMA before copying the selected frame.

```sh
mkdir -p /tmp/calibration
visionarm-capture --prefix /tmp/calibration/checkerboard --count 20
```

Use `--buffer 1` to inspect the second ping-pong buffer.  Confirm both buffers
on hardware before choosing one for a calibration session.
