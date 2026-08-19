# LA32R Linux automatic initramfs

This target builds a non-interactive static PID 1 for the current board state,
where Linux `ttyS0` output works but RX is unreliable.  It automatically:

1. enumerates `/` and prints `AUTO_LS_PASS`;
2. reads the VisionArm camera and LCD register blocks through `/dev/mem`;
3. requests LCD hardware color bars;
4. starts camera DMA and checks that its activity counter changes;
5. remains alive forever and prints `AUTO_INIT_ALIVE` every 30 seconds.

It is injected into the already board-tested NAND-disabled kernel.  The base
image is copied and never modified.  Build on Windows with:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\linux_auto_init\build.ps1
```

The output is:

```text
artifacts/linux/vmlinux_auto_visionarm_nand_disabled_stripped
```

Copy it into the TFTP root, then boot it with the `a4f` trampoline.  The
archive installs the same PID 1 as both `/init` and `/bin/sh`, so the existing
`linux_handoff_trampoline_a4f` is sufficient:

```text
ifconfig dmfe0 192.168.1.101
load tftp://192.168.1.100/vmlinux_auto_visionarm_nand_disabled_stripped
load tftp://192.168.1.100/linux_handoff_trampoline_a4f
g
```

Do not use the `a5f` trampoline.  A successful run ends with
`VISIONARM_TEST_PASS` and recurring `AUTO_INIT_ALIVE` markers; no serial input
is required.
