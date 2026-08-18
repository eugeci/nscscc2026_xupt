/* SPDX-License-Identifier: GPL-2.0 */
#ifndef XNPU_PID1_SUPERVISOR_H
#define XNPU_PID1_SUPERVISOR_H

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static void xnpu_pid1_remain_alive(void)
{
	for (;;)
		sleep(3600);
}

static int xnpu_pid1_supervise(int (*smoke_main)(void))
{
	pid_t smoke_pid;

	if (getpid() != 1)
		return smoke_main();

	setvbuf(stdout, NULL, _IONBF, 0);
	printf("XNPU init supervisor start\n");
	smoke_pid = fork();
	if (smoke_pid < 0) {
		printf("XNPU_INIT_FAIL operation=fork errno=%d (%s)\n",
		       errno, strerror(errno));
		xnpu_pid1_remain_alive();
	}
	if (smoke_pid == 0)
		_exit(smoke_main());

	/*
	 * Linux deliberately panics when PID 1 exits.  Reap every child so
	 * future smoke programs may fork without leaving zombies, and keep the
	 * supervisor alive even if the smoke process exits or is killed.
	 */
	for (;;) {
		int status;
		pid_t child = wait(&status);

		if (child < 0) {
			if (errno == EINTR)
				continue;
			if (errno == ECHILD && smoke_pid < 0)
				xnpu_pid1_remain_alive();
			printf("XNPU_INIT_FAIL operation=wait errno=%d (%s)\n",
			       errno, strerror(errno));
			xnpu_pid1_remain_alive();
		}
		if (child != smoke_pid)
			continue;
		if (WIFEXITED(status))
			printf("XNPU_INIT_CHILD_EXIT status=%d\n",
			       WEXITSTATUS(status));
		else if (WIFSIGNALED(status))
			printf("XNPU_INIT_CHILD_SIGNAL signal=%d\n",
			       WTERMSIG(status));
		else
			printf("XNPU_INIT_CHILD_STOP status=0x%x\n", status);
		smoke_pid = -1;
	}
}

#endif
