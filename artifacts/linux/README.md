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
