# Configurable PMON-to-Linux handoff trampoline

PMON loads the trampoline last, so `g` enters it at `0xa0100000`.  It repairs
the Linux argument registers and jumps to the selected kernel ELF entry.
The entry must match the `Entry address is ...` line printed by PMON; using a
trampoline built for another kernel entry can result in no Linux output.

Example for the UART trigger=1 kernel:

```sh
make clean
make ENTRY=0xa07c4d78 BOOTPARAM_ENV=0xa4f00040
```

Copy `obj/linux_handoff_trampoline.elf` to the TFTP root as
`linux_handoff_trampoline_a4f_rxtrig1`, then boot:

```text
load tftp://192.168.1.100/vmlinux_nand_disabled_rxtrig1_stripped
load tftp://192.168.1.100/linux_handoff_trampoline_a4f_rxtrig1
g
```
