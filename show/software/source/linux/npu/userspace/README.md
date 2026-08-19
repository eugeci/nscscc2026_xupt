# XNPU native userspace

This directory implements the dependency-free C runtime for XNPU deployment
packages:

- `libxnpu.a`: strict package validation and the Linux UAPI lifecycle;
- `xnpu-inspect`: package contract, section CRC and package SHA display;
- `xnpu-run`: load one package/input, infer and optionally check checksum,
  top-1 or bbox bytes;
- `xnpu-regress`: keep one device open and execute a tab-separated model
  switching manifest.

The parser decodes fields explicitly as little-endian rather than mapping a C
structure over untrusted input. It verifies bounds, alignment, section
ordering/overlap, required sections, CRC32, package SHA-256, descriptor and
parameter lengths. Before `LOAD_MODEL`, the device layer also checks hardware
ABI, required capabilities and driver limits. The kernel still copies and
validates every UAPI payload; package validation is not a replacement for the
driver trust boundary.

## Host build and parser tests

```sh
make -C linux/npu/userspace \
  PACKAGES_DIR="$PWD/chiplab/IP/NPU/models/packages" all test
```

The test accepts all four committed packages and rejects bad magic, bad
package hash, a misaligned section, bad section CRC and truncation.

## LA32 static build

```sh
toolchain="$PWD/chiplab/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin/loongarch32r-linux-gnusf-"
make -C linux/npu/userspace \
  BUILD_DIR="$PWD/linux/npu/.work/userspace-la32" \
  CC="${toolchain}gcc" AR="${toolchain}ar" LDFLAGS=-static all
```

`NPU_INIT=stage4 ./linux/npu/build.sh` performs this cross-build automatically
and builds the dedicated package-path smoke as `/init`.

## Library lifecycle

```text
xnpu_package_open
xnpu_device_open
xnpu_device_load_model
xnpu_device_infer       (LOAD_INPUT -> RUN -> WAIT_V2 -> read)
xnpu_device_close
xnpu_package_close
```

The package object owns its file buffer, so it must stay alive until
`xnpu_device_load_model` returns. An input buffer must stay alive until
`xnpu_device_infer` returns.

Example:

```sh
xnpu-run \
  --expect-checksum 0x685184b3 \
  --expect-bbox 58,132,81,104,137 \
  /models/facenet_lbp_v1.xnpu /fixtures/facenet_seed42.bin
```

The regression manifest format is:

```text
package<TAB>input<TAB>checksum<TAB>kind<TAB>expected
```

`kind` is `top1` with one decimal class or `bbox` with five comma-separated
bytes. The checked-in `models/packages/regression.tsv` covers two FaceNet
fixtures and one fixture for each classification target. Running that whole
manifest on RTL is a Stage-5 validation step.
