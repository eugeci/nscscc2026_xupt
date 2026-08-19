# Linux generated artifacts

Large Linux kernel images are generated locally and are not committed. Build the automatic
VisionArm diagnostic image with:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\linux_auto_init\build.ps1
```

The verified local output on 2026-08-19 was:

```text
4ED30A6E435E64B8DFBA03213F33ACD75402C83520C3F62738CFDD02B2873167  vmlinux_auto_visionarm_nand_disabled_stripped
```

See `tools/linux_auto_init/README.md` for TFTP and PMON commands.

## UART RX trigger=1 A/B image

The Linux 5.14 diagnostic image with the generic 16550A RX FIFO trigger forced
from eight bytes to one byte is generated in the Ubuntu build environment and
is not committed as a large binary.  The source-only patch is:

```text
linux/patches/0003-8250-force-16550a-rx-trigger-1-for-ab-test.patch
```

Verified build output on 2026-08-19:

```text
58779f0f98f3d23c4ac8d230dae78ea3bc5ee953bb807c40ffde5810d7b43d82  vmlinux_nand_disabled_rxtrig1_stripped
size: 9854900 bytes
release: 5.14.0-rc2-uart-rxtrig1
entry: 0xa07c4d78
```

The image was copied to `D:\openla500_run_linux\tftp-root`. Its ELF entry is
`0xa07c4d78`, while the older `linux_handoff_trampoline_a4f` hard-codes
`0xa07b06e0`; using that old trampoline stops before any Linux output. Use the
matching generated trampoline instead:

```text
7b8d27da5aaa0dec0f596f70fa1b43c2dceb2ef7c0fd724ba3efde29e69b0910  linux_handoff_trampoline_a4f_rxtrig1_init
```

An earlier entry-matched trampoline used `rdinit=/bin/sh`; this reached Linux
but printed `unable to open an initial console`, then the shell exited and
caused `Attempted to kill init`.  That run only validates the kernel entry and
must not be counted as an RX result.  The `_init` trampoline runs the archive's
`/init` first so it can mount devtmpfs.

If input starts working with the matching trampoline, the fault is narrowed
to the UART receiver-timeout/trigger behavior rather than the Linux TTY, MMU,
DDR, or initramfs.

## UART timer-polling A/B image

The follow-up image removes the interrupt property only from the board UART at
`0x1fe001e0`, causing the OF 8250 driver to register it as IRQ 0 and select the
existing `serial8250_timeout()` polling path.  It contains both diagnostic
patches `0003` and `0004`:

```text
release: 5.14.0-rc2-uart-poll
entry:   0xa07c4d78
size:    9854868 bytes
sha256:  f8be53c2463790c24c358a8c4bd363a5d777e3a8fe6993c3e5a1fe53ffa6d663
file:    vmlinux_nand_disabled_uartpoll_stripped
```

Use `linux_handoff_trampoline_a4f_uartpoll_init`, which is the same verified
`0xa07c4d78`/`rdinit=/init` handoff binary as the trigger-one test.

Board testing verified `ttyS0 ... (irq = 0)`, but also exposed a repeated raw
IRQ18 storm (`irq 18: nobody cared` / `Disabling IRQ #18`).  The standard 8250
no-IRQ mode still enables UART IER bits so that its timer can service pending
IIR causes; on this SoC the physical UART interrupt remains wired to CPU IRQ18.
Consequently this first polling build is a useful interrupt-routing diagnostic,
not yet a clean user-input workaround.  A corrected polling build must either
mask the parent CPU interrupt while leaving the UART IER active, or set IER=0
and poll LSR/RBR directly instead of relying on IIR.
