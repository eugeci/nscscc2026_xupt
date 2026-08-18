# uCore LoongArch32 镜像

镜像基于 `cyyself/ucore-loongarch32`，修复了 `fence_i()` 的 CACOP 地址约束问题。

- `ucore-kernel-initrd-fence-fix.bin`：正常下板镜像
- `ucore-kernel-initrd-fence-fix-diag.bin`：针对 `ls` 首次/二次执行输出缓存维护前后数据的诊断镜像

SHA256：

```text
c4a624c3a78911de4ab884adb930f8431aad8d83e9c46f25ca15d648db0c86c5  ucore-kernel-initrd-fence-fix-diag.bin
0feb0181c1364b90202ac049c3f1778ac648cb3886aceecaa774cfbcaf5be6df  ucore-kernel-initrd-fence-fix.bin
```
