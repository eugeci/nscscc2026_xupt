#!/bin/sh
mount -t devtmpfs x /dev
exec 0<>/dev/console 1>&0 2>&0
echo BB0_SHELL_START
/bin/echo BB1_ECHO_PASS
/bin/ls /
echo BB2_LS_RC:$?
exec /bin/sleep 999999
