// SPDX-License-Identifier: GPL-2.0
/*
 * Non-interactive fork/exec boundary probe for LA32R Linux.
 *
 * The same static ELF is installed as /init and /bin/sh.  PID 1 runs three
 * increasingly demanding child-process stages; the exec stage re-enters this
 * binary through /bin/sh --exec-probe, creating a fresh userspace image.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define STAGE_TIMEOUT_SECONDS 8U
#define STAGE_POLL_MILLISECONDS 100U
#define STAGE_POLL_COUNT \
	((STAGE_TIMEOUT_SECONDS * 1000U) / STAGE_POLL_MILLISECONDS)
#define STAGE1_EXIT_CODE      41
#define STAGE2_EXIT_CODE      42
#define STAGE3_EXIT_CODE      43

static volatile unsigned char fork_cow_data[8192];
static volatile unsigned char exec_bss_pages[12288];
static const char exec_rodata[] = "LA32R_EXEC_RODATA_OK";

static void attach_console(void)
{
	int fd = open("/dev/console", O_RDWR | O_NOCTTY);

	if (fd < 0)
		return;
	(void)dup2(fd, STDIN_FILENO);
	(void)dup2(fd, STDOUT_FILENO);
	(void)dup2(fd, STDERR_FILENO);
	if (fd > STDERR_FILENO)
		(void)close(fd);
}

static void mount_pseudo_filesystems(void)
{
	(void)mount("proc", "/proc", "proc", 0, NULL);
	(void)mount("sysfs", "/sys", "sysfs", 0, NULL);
}

static int wait_for_stage(pid_t child, const char *stage, int expected_exit)
{
	int status = 0;
	pid_t result = 0;
	unsigned int poll;
	const struct timespec delay = {
		.tv_sec = 0,
		.tv_nsec = STAGE_POLL_MILLISECONDS * 1000000L,
	};

	for (poll = 0; poll < STAGE_POLL_COUNT; poll++) {
		result = waitpid(child, &status, WNOHANG);
		if (result == child)
			break;
		if (result < 0 && errno != EINTR) {
			printf("%s_WAIT_FAIL errno=%d (%s)\n", stage, errno,
			       strerror(errno));
			return -1;
		}
		if (result == 0)
			(void)nanosleep(&delay, NULL);
	}

	if (result != child) {
		printf("%s_TIMEOUT seconds=%u child=%ld\n", stage,
		       STAGE_TIMEOUT_SECONDS, (long)child);
		(void)kill(child, SIGKILL);
		while (waitpid(child, &status, 0) < 0 && errno == EINTR)
			;
		return -1;
	}

	if (!WIFEXITED(status)) {
		if (WIFSIGNALED(status))
			printf("%s_SIGNAL signal=%d\n", stage, WTERMSIG(status));
		else
			printf("%s_BAD_STATUS raw=0x%x\n", stage, status);
		return -1;
	}
	if (WEXITSTATUS(status) != expected_exit) {
		printf("%s_BAD_EXIT actual=%d expected=%d\n", stage,
		       WEXITSTATUS(status), expected_exit);
		return -1;
	}
	printf("%s_PASS child=%ld exit=%d\n", stage, (long)child,
	       WEXITSTATUS(status));
	return 0;
}

static int run_stage1(void)
{
	pid_t child;

	puts("STAGE1_FORK_EXIT_BEGIN");
	child = fork();
	if (child < 0) {
		printf("STAGE1_FORK_FAIL errno=%d (%s)\n", errno,
		       strerror(errno));
		return -1;
	}
	if (child == 0)
		_exit(STAGE1_EXIT_CODE);
	return wait_for_stage(child, "STAGE1_FORK_EXIT", STAGE1_EXIT_CODE);
}

static int run_stage2(void)
{
	pid_t child;

	puts("STAGE2_CHILD_WRITE_COW_BEGIN");
	child = fork();
	if (child < 0) {
		printf("STAGE2_FORK_FAIL errno=%d (%s)\n", errno,
		       strerror(errno));
		return -1;
	}
	if (child == 0) {
		volatile uint32_t stack_words[64];
		unsigned int index;
		static const char marker[] =
			"STAGE2_CHILD_WRITE_COW_MARKER\n";

		for (index = 0; index < 64U; index++)
			stack_words[index] = 0x5a000000U | index;
		fork_cow_data[0] = 0x41U;
		fork_cow_data[4096] = 0x42U;
		fork_cow_data[8191] = 0x43U;
		if (stack_words[63] != 0x5a00003fU)
			_exit(120);
		(void)write(STDOUT_FILENO, marker, sizeof(marker) - 1U);
		_exit(STAGE2_EXIT_CODE);
	}
	return wait_for_stage(child, "STAGE2_CHILD_WRITE_COW",
			      STAGE2_EXIT_CODE);
}

static int run_stage3(void)
{
	pid_t child;

	puts("STAGE3_EXECVE_BEGIN path=/bin/sh");
	child = fork();
	if (child < 0) {
		printf("STAGE3_FORK_FAIL errno=%d (%s)\n", errno,
		       strerror(errno));
		return -1;
	}
	if (child == 0) {
		char *const arguments[] = {
			(char *)"/bin/sh", (char *)"--exec-probe", NULL
		};
		char *const environment[] = {
			(char *)"PATH=/bin", (char *)"PROBE=la32r", NULL
		};

		execve("/bin/sh", arguments, environment);
		printf("STAGE3_EXECVE_SYSCALL_FAIL errno=%d (%s)\n", errno,
		       strerror(errno));
		_exit(127);
	}
	return wait_for_stage(child, "STAGE3_EXECVE", STAGE3_EXIT_CODE);
}

static int exec_child_main(void)
{
	volatile uint32_t stack_words[128];
	unsigned int index;

	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
	printf("STAGE3_EXEC_CHILD_START pid=%ld ppid=%ld\n", (long)getpid(),
	       (long)getppid());
	printf("STAGE3_EXEC_MAP text=%p rodata=%p bss=%p stack=%p\n",
	       (void *)&exec_child_main, (const void *)exec_rodata,
	       (void *)exec_bss_pages, (void *)stack_words);

	for (index = 0; index < 128U; index++)
		stack_words[index] = 0xa5000000U | index;
	exec_bss_pages[0] = 0x11U;
	exec_bss_pages[4096] = 0x22U;
	exec_bss_pages[8192] = 0x33U;
	exec_bss_pages[12287] = 0x44U;
	if (strcmp(exec_rodata, "LA32R_EXEC_RODATA_OK") != 0 ||
	    stack_words[127] != 0xa500007fU ||
	    exec_bss_pages[0] != 0x11U ||
	    exec_bss_pages[12287] != 0x44U) {
		puts("STAGE3_EXEC_PAGE_TOUCH_FAIL");
		return 121;
	}
	puts("STAGE3_EXEC_TEXT_RODATA_BSS_STACK_PASS");
	puts("STAGE3_EXEC_CHILD_EXIT");
	return STAGE3_EXIT_CODE;
}

static void preserve_pid1(const char *result)
{
	unsigned int heartbeat = 0;

	printf("%s; PID 1 remains alive\n", result);
	for (;;) {
		sleep(30);
		heartbeat++;
		printf("FORK_EXEC_PROBE_ALIVE heartbeat=%u result=%s\n",
		       heartbeat, result);
	}
}

int main(int argc, char **argv)
{
	attach_console();
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);

	if (argc > 1 && strcmp(argv[1], "--exec-probe") == 0)
		return exec_child_main();

	mount_pseudo_filesystems();
	puts("============================================================");
	puts("LA32R Linux fork/exec boundary diagnostic");
	printf("FORK_EXEC_PROBE_START pid=%ld\n", (long)getpid());

	if (run_stage1() != 0)
		preserve_pid1("FORK_EXEC_PROBE_FAIL_STAGE1");
	if (run_stage2() != 0)
		preserve_pid1("FORK_EXEC_PROBE_FAIL_STAGE2");
	if (run_stage3() != 0)
		preserve_pid1("FORK_EXEC_PROBE_FAIL_STAGE3");

	puts("FORK_EXEC_PROBE_PASS");
	puts("============================================================");
	preserve_pid1("FORK_EXEC_PROBE_DONE");
	return 0;
}
