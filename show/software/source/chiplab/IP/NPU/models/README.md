# XUPT-NPU model assets

This directory is the Stage-1 migration of the verified model assets from
`../la32r_xupt_soc_a735t` commit
`d47c32ce69301322c98e79d80691b3e197e5932a`.

`catalog.json` is the canonical inventory for the four compiler targets.  It
records the hardware input/output contract, runtime byte counts, fixture
expectations and SHA-256 values.  The hashes cover the checked-in text
artifacts exactly; `parameter_image.bytes` is the decoded binary byte count,
not the size of the ASCII HEX file.

The migrated tree contains:

- `../configs/`: compiler target configurations adapted to Chiplab-local
  output paths;
- `../scripts/`: the Python numerical/reference compiler backend;
- `../params/`: quantization metadata and blocked parameter images;
- `../sim/`: descriptor and microcode HEX;
- `descriptors/`: generated C descriptor headers;
- `fixtures/`: generated C input fixtures and expected outputs.
- `packages/`: deterministic, target-ready `.xnpu` files plus the regression
  manifest;
- `fixtures/bin/`: standalone binary inputs/expected values used by regression.

The FaceNet checkpoint is available as `../params/fpga_face_net.pth`.  The
LeNet and TinyVGG checkpoints/datasets were external dependencies of the old
workspace and are deliberately not fabricated here.  They are only needed to
repeat training/calibration.  A backend-only rebuild reuses the checked-in
quantization metadata and parameter image:

```sh
cd chiplab/IP/NPU
python3 scripts/compile_model.py \
  --config configs/npu_vgg_s1_v1.json \
  --skip-quant --skip-verify
```

The historical `npu_compile_manifest.json` files are retained as provenance
from the upstream workspace; some include the old developer path in diagnostic
records.  Neither RTL nor Linux consumes those manifests.  New compiler runs
use the Chiplab-local paths from `configs/`.

Stage 4 adds the format specified in [`XNPU_FORMAT.md`](XNPU_FORMAT.md). Build
and verify all checked-in packages with only the Python standard library:

```sh
python3 chiplab/IP/NPU/scripts/xnpu_pack.py
python3 chiplab/IP/NPU/scripts/test_xnpu_package.py -v
python3 chiplab/IP/NPU/scripts/xnpu_inspect.py \
  chiplab/IP/NPU/models/packages/facenet_lbp_v1.xnpu
```

The packer checks every source HEX/fixture hash recorded by the catalog. It
emits little-endian descriptor/parameter sections, canonical metadata and
separate fixture binaries. A second run must be byte-identical.

No checkpoint, Python package, dataset or compiler script enters the target
system. Linux uses the checked-in packages through `libxnpu`; Python is needed
only to rebuild packages after changing a compiled model. A future native
`xnpu-cc` backend remains a separate deliverable.
