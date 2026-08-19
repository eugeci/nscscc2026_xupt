#ifndef LINUX_BOOTARGS
#define LINUX_BOOTARGS "console=ttyS0,115200 rdinit=/bin/sh print-fatal-signals=1 -- -i"
#endif

#ifndef LINUX_ENTRY
#define LINUX_ENTRY 0xa07b06e0
#endif

#ifndef BOOTPARAM_ENV
#define BOOTPARAM_ENV 0xa4f00040
#endif

    .section .text.start, "ax", @progbits
    .align  4
    .globl  _start
    .type   _start, @function
_start:
    /* PMON created argv/envp blocks, but its context restore can deliver zero
     * in r4-r7. Reconstruct the tuple before entering the loaded kernel.
     */
    li.w    $r4, 2
    la.local $r5, trampoline_argv
    li.w    $r6, BOOTPARAM_ENV
    li.w    $r7, 0

    dbar    0
    ibar    0
    li.w    $r12, LINUX_ENTRY
    jirl    $r0, $r12, 0
    .size   _start, .-_start

    .align  2
trampoline_argv:
    .word   trampoline_arg0
    .word   trampoline_arg1
trampoline_arg0:
    .asciz  "vmlinux"
trampoline_arg1:
    .asciz  LINUX_BOOTARGS
