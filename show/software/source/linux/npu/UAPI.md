# XNPU Linux UAPI v2

The public definitions are in
`kernel/include/uapi/linux/xnpu.h`.  Every structure uses fixed-width
integer fields and explicit `__u64` userspace pointers, so the layout is stable
for the 32-bit LoongArch target.

## Compatibility

ABI v2 retains all ABI-v1 ioctls:

```text
GET_INFO
RESET
LOAD_DESCRIPTORS
write(19200-byte frame)
RUN
WAIT
```

They remain the ROM/MMIO regression interface.  `GET_INFO.abi_version` now
returns 2.  New software must call `QUERY_CAPS` and check
`XNPU_CAP_AXI_DMA` before using the model operations.  A ROM build reports
no DMA capability and returns `-EOPNOTSUPP` for v2 model ioctls.

## Single-active-model lifecycle

```text
open("/dev/xnpu", O_RDWR)
QUERY_CAPS
LOAD_MODEL
LOAD_INPUT
RUN
WAIT_V2
read(result payload)
...
LOAD_MODEL          replaces the previous model
close
```

Only one process can open the device.  `LOAD_MODEL` is the transaction boundary
for metadata, descriptors and the parameter image.  The driver validates and
copies all userspace data, allocates coherent parameter/scratch/result buffers,
resets idle hardware, programs only DMA API addresses and then publishes the
new model.  Userspace cannot provide a physical address and no DMA/MMIO buffer
is exposed through `mmap`.

The old model remains intact if a userspace copy or new allocation fails.  Once
hardware reset/programming begins, a hardware programming error leaves no
active model; userspace must issue `RESET` or retry `LOAD_MODEL`.

`RESET` and `close()` stop the device and release all model DMA buffers.

## Operations

### `XNPU_IOC_QUERY_CAPS`

Returns ABI/hardware versions, capabilities and hard limits.  Reserved fields
are zero.  Stage-3 limits are:

| Resource | Limit |
| --- | ---: |
| Layers | 32 |
| Parameter image | 1 MiB |
| Scratch | 512 KiB |
| Result | 1 MiB |
| Input | 19,200 B |

The current external pool reorder implementation addresses at most 307,200
scratch bytes; v2 requires at least that much and accepts up to the reported
512 KiB limit.

### `XNPU_IOC_LOAD_MODEL`

The request supplies:

- layer count and a pointer to `layer_count * 8` little-endian descriptor
  words;
- parameter byte count and a pointer to the blocked parameter image;
- requested scratch/result sizes;
- exact input mode and byte count;
- result tensor width, height, channels, layout and dtype.

`flags` and every reserved field must be zero.  Parameter size must be
word-aligned, scratch size must be 16-byte aligned, and descriptor parameter
offsets must remain inside the supplied parameter image.

The input modes are:

- `XNPU_INPUT_FRAME`: exactly 19,200 bytes, used by FaceNet and the current
  padded LeNet contract;
- `XNPU_INPUT_PACKED_PRELOAD`: 1..19,200 bytes, used by TinyVGG.

### `XNPU_IOC_LOAD_INPUT`

Copies exactly the byte count declared by the active model.  The mode must also
match.  Frame input is written to the MMIO frame aperture; packed input is
written through the packed-preload FIFO.  A busy device returns `-EBUSY`.

The legacy `write()` operation is still accepted for a frame-mode model.

### `XNPU_IOC_RUN`

Starts the active model after an input has been loaded.  The optional
`XNPU_RUN_USE_IRQ` flag selects interrupt completion; polling remains
available for bring-up.  The result DMA buffer and result status are cleared
before each run.  A second concurrent run returns `-EBUSY`.

### `XNPU_IOC_WAIT_V2` and `read()`

`WAIT_V2` returns status, cycle count, result status, actual byte count,
checksum and tensor metadata.  It succeeds only after both inference and result
writeback are complete and after the hardware-reported byte count has passed
the allocated-buffer bounds check.

After a successful wait, ordinary `read()` returns the result tensor payload
and advances the file position.  Starting a new run, loading input/model or
resetting the device rewinds/invalidates the previous readable result.

Task-specific bbox decoding, argmax/top-k and labels remain userspace work.

## Error recovery

- `-EINVAL`: malformed metadata, reserved bits, length, shape or descriptor;
- `-ENODATA`: no model/input/result for the requested operation;
- `-EBUSY`: hardware or another run is active;
- `-EOPNOTSUPP`: v2 DMA operation on a ROM build;
- `-ETIMEDOUT`: completion did not arrive; issue `RESET` before reuse;
- `-EIO`: hardware status, DMA response or result bounds failure.

No automatic retry is performed after a timeout because the driver cannot
prove that all AXI transactions have drained without resetting the accelerator.
