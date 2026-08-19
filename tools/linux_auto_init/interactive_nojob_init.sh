#!/bin/sh

# Compatibility init for kernels whose tty driver does not implement the
# process-group ioctls required by ash job control.  Keep the same explicit
# mount checkpoints, but let cttyhack select the console and start a plain
# non-job-control shell.
mount -t devtmpfs devtmpfs /dev
exec 0<>/dev/console 1>&0 2>&0
echo INIT_CP1_CONSOLE_READY

mount -t proc proc /proc
echo INIT_CP2_PROC_READY rc:$?
mount -t sysfs sysfs /sys
echo INIT_CP3_SYS_READY rc:$?
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts
echo INIT_CP4_DEVPTS_READY rc:$?

export HOME=/
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PS1='/ # '

# The published XNPU kernel predates the trigger-one 8250 source patch used by
# the stable bringup kernel.  Program the 16550A FCR directly after the driver
# has registered: enable FIFO with RX trigger level 1.  The current core keeps
# this byte MMIO access narrow, so it does not alias RBR at offset zero.
echo INIT_UART_FCR_TRIGGER1_BEGIN
/bin/busybox devmem 0x1fe001e2 8 0x01
echo INIT_UART_FCR_TRIGGER1_DONE rc:$?

echo INIT_CP5_EXEC_NOJOB_SH

exec /bin/busybox cttyhack /bin/sh
