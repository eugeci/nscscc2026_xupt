// SPDX-License-Identifier: GPL-2.0
/*
 * Non-interactive PID 1 for LA32R Linux board bring-up.
 *
 * The current RTL can transmit through ttyS0 but Linux RX is not reliable.
 * Keep the validation independent of console input: enumerate the initramfs,
 * exercise the VisionArm camera/LCD MMIO registers through /dev/mem, then
 * remain alive forever so Linux never panics because PID 1 exited.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define VISIONARM_PAGE_BASE 0x1fd0e000UL
#define VISIONARM_PAGE_SIZE 0x1000UL

#define CAM_CTRL_OFFSET     0x100U
#define CAM_STATUS_OFFSET   0x104U
#define CAM_ACTIVITY_OFFSET 0x108U
#define CAM_FRAME0_OFFSET   0x114U
#define CAM_FRAME1_OFFSET   0x118U
#define CAM_OUTPUT_OFFSET   0x11cU
#define CAM_INPUT_OFFSET    0x120U
#define CAM_STRIDE_OFFSET   0x124U
#define CAM_MAGIC_OFFSET    0x13cU

#define LCD_CTRL_OFFSET     0x140U
#define LCD_FB_OFFSET       0x144U
#define LCD_STATUS_OFFSET   0x148U
#define LCD_SIZE_OFFSET     0x14cU
#define LCD_MAGIC_OFFSET    0x150U

#define CAM_MAGIC_EXPECTED  0x43414d31U

static volatile uint32_t *visionarm_reg(void *page, unsigned int offset)
{
	return (volatile uint32_t *)((unsigned char *)page + offset);
}

static uint32_t read_reg(void *page, unsigned int offset)
{
	uint32_t value = *visionarm_reg(page, offset);

	__sync_synchronize();
	return value;
}

static void write_reg(void *page, unsigned int offset, uint32_t value)
{
	*visionarm_reg(page, offset) = value;
	__sync_synchronize();
	(void)*visionarm_reg(page, offset);
}

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
	(void)mkdir("/proc", 0555);
	(void)mkdir("/sys", 0555);
	(void)mount("proc", "/proc", "proc", 0, NULL);
	(void)mount("sysfs", "/sys", "sysfs", 0, NULL);
}

static void list_root(void)
{
	DIR *directory;
	struct dirent *entry;
	unsigned int count = 0;

	puts("AUTO_LS_BEGIN path=/");
	directory = opendir("/");
	if (directory == NULL) {
		printf("AUTO_LS_FAIL errno=%d (%s)\n", errno, strerror(errno));
		return;
	}

	while ((entry = readdir(directory)) != NULL) {
		printf("  %s\n", entry->d_name);
		count++;
	}
	(void)closedir(directory);
	printf("AUTO_LS_PASS entries=%u\n", count);
}

static void run_visionarm_test(void)
{
	int memory_fd;
	void *page;
	uint32_t cam_magic;
	uint32_t cam_status;
	uint32_t activity_before;
	uint32_t activity_after;
	uint32_t lcd_magic;
	uint32_t lcd_status;
	uint32_t lcd_size;

	puts("VISIONARM_TEST_BEGIN");
	memory_fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (memory_fd < 0) {
		printf("VISIONARM_TEST_FAIL open=/dev/mem errno=%d (%s)\n",
		       errno, strerror(errno));
		return;
	}

	page = mmap(NULL, VISIONARM_PAGE_SIZE, PROT_READ | PROT_WRITE,
		    MAP_SHARED, memory_fd, (off_t)VISIONARM_PAGE_BASE);
	if (page == MAP_FAILED) {
		printf("VISIONARM_TEST_FAIL mmap errno=%d (%s)\n",
		       errno, strerror(errno));
		(void)close(memory_fd);
		return;
	}

	cam_magic = read_reg(page, CAM_MAGIC_OFFSET);
	printf("CAM_INFO magic=0x%08x input=0x%08x output=0x%08x "
	       "stride=0x%08x fb0=0x%08x fb1=0x%08x\n",
	       cam_magic,
	       read_reg(page, CAM_INPUT_OFFSET),
	       read_reg(page, CAM_OUTPUT_OFFSET),
	       read_reg(page, CAM_STRIDE_OFFSET),
	       read_reg(page, CAM_FRAME0_OFFSET),
	       read_reg(page, CAM_FRAME1_OFFSET));
	if (cam_magic == CAM_MAGIC_EXPECTED)
		puts("CAM_MAGIC_PASS");
	else
		printf("CAM_MAGIC_FAIL expected=0x%08x\n", CAM_MAGIC_EXPECTED);

	/* Ask the LCD hardware to display its built-in RGB test bars. */
	lcd_magic = read_reg(page, LCD_MAGIC_OFFSET);
	lcd_size = read_reg(page, LCD_SIZE_OFFSET);
	printf("LCD_INFO magic=0x%08x size=0x%08x fb=0x%08x\n",
	       lcd_magic, lcd_size, read_reg(page, LCD_FB_OFFSET));
	write_reg(page, LCD_CTRL_OFFSET, 2U);
	usleep(250000);
	lcd_status = read_reg(page, LCD_STATUS_OFFSET);
	printf("LCD_BARS_REQUESTED ctrl=0x%08x status=0x%08x\n",
	       read_reg(page, LCD_CTRL_OFFSET), lcd_status);

	/* Start camera DMA and require observable activity, not just a write ACK. */
	activity_before = read_reg(page, CAM_ACTIVITY_OFFSET);
	write_reg(page, CAM_CTRL_OFFSET, 1U);
	sleep(2);
	cam_status = read_reg(page, CAM_STATUS_OFFSET);
	activity_after = read_reg(page, CAM_ACTIVITY_OFFSET);
	printf("CAM_RUN status=0x%08x activity=0x%08x->0x%08x\n",
	       cam_status, activity_before, activity_after);
	if ((cam_status & (1U << 6)) != 0U &&
	    activity_after != activity_before)
		puts("CAM_ACTIVITY_PASS");
	else
		puts("CAM_ACTIVITY_FAIL");

	if (cam_magic == CAM_MAGIC_EXPECTED &&
	    (cam_status & (1U << 6)) != 0U &&
	    activity_after != activity_before)
		puts("VISIONARM_TEST_PASS");
	else
		puts("VISIONARM_TEST_FAIL");

	(void)munmap(page, VISIONARM_PAGE_SIZE);
	(void)close(memory_fd);
}

int main(void)
{
	unsigned int heartbeat = 0;

	attach_console();
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
	mount_pseudo_filesystems();

	puts("============================================================");
	puts("LA32R Linux automatic initramfs test");
	printf("AUTO_INIT_START pid=%ld no-console-input-required\n",
	       (long)getpid());
	list_root();
	run_visionarm_test();
	puts("AUTO_INIT_DONE; PID 1 will remain alive forever");
	puts("============================================================");

	for (;;) {
		sleep(30);
		heartbeat++;
		printf("AUTO_INIT_ALIVE heartbeat=%u\n", heartbeat);
	}
}
