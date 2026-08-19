#!/bin/sh

# Minimal interactive PID 1 used to isolate the intermittent normal-init hang.
# Keep this independent of /etc/profile and login-shell job-control setup.
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
echo INIT_CP5_EXEC_INTERACTIVE_SH

# Start a new session and explicitly claim ttyS0 as its controlling terminal.
# Redirection opens the real UART node; setsid -c then applies TIOCSCTTY to
# stdin after becoming a session leader. This keeps Ctrl+C/job control alive.
exec /bin/busybox setsid -c /bin/sh -i </dev/ttyS0 >/dev/ttyS0 2>&1
