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

The image was copied to `D:\openla500_run_linux\tftp-root`.  Boot it with the
`linux_handoff_trampoline_a4f` trampoline.  If input starts working, the fault
is narrowed to the UART receiver-timeout/trigger behavior rather than the
Linux TTY, MMU, DDR, or initramfs.
