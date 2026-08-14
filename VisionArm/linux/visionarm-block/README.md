# VisionArm block demo

`visionarm-block` implements the first safe closed-loop stage: RGB565 color
proposal, XNPU classification of the candidate, and optional one-step X/Y
alignment. Observation is the default; motion requires both `--model` and
`--control`. Z approach and gripping stay disabled until physical calibration.

```sh
make test
visionarm-block --color red --loops 100
visionarm-block --color red --model /models/blocks_v1.xnpu --class 0 --loops 100
# Run only after `arm home` and direction calibration:
visionarm-block --color red --model /models/blocks_v1.xnpu --class 0 --control
```

The model must be a packed-preload classification package with a 34x34x3 CHW
u8 input, matching the existing TinyVGG lowering. Use `--invert-x` or
`--invert-y` if an image error drives the arm away from the target.

The complete Chinese deployment, calibration, safety and acceptance guide is
`VisionArm/docs/XNPU积木识别闭环演示与标定指南.md`.
