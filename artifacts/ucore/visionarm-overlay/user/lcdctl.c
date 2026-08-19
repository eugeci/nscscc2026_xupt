#include <stdio.h>
#include <string.h>
#include <ulib.h>

#define LCD_CTRL   0x1fd0e140u
#define LCD_FB     0x1fd0e144u
#define LCD_STATUS 0x1fd0e148u
#define LCD_SIZE   0x1fd0e14cu
#define LCD_MAGIC  0x1fd0e150u

static void usage(void) {
    cprintf("Usage: lcdctl status|show|bars|switch|off\n");
}

static void status(void) {
    uint32_t value = vision_read(LCD_STATUS);
    cprintf("LCD ctrl   : 0x%08x\n", vision_read(LCD_CTRL));
    cprintf("LCD fb     : 0x%08x\n", vision_read(LCD_FB));
    cprintf("LCD status : 0x%08x\n", value);
    cprintf("LCD size   : 0x%08x\n", vision_read(LCD_SIZE));
    cprintf("LCD magic  : 0x%08x\n", vision_read(LCD_MAGIC));
    cprintf("initialized: %u\n", (value >> 0) & 1u);
    cprintf("panel busy : %u\n", (value >> 1) & 1u);
    cprintf("panel done : %u\n", (value >> 2) & 1u);
    cprintf("DDR wait   : %u\n", (value >> 3) & 1u);
    cprintf("reader busy: %u\n", (value >> 4) & 1u);
    cprintf("reader done: %u\n", (value >> 5) & 1u);
    cprintf("AXI error  : %u\n", (value >> 6) & 1u);
    cprintf("DDR owner  : %u\n", (value >> 7) & 1u);
}

int main(int argc, char **argv) {
    uint32_t value = 0;
    int count;

    if (argc != 2) {
        usage();
        return 1;
    }
    if (strcmp(argv[1], "status") == 0) {
        status();
        return 0;
    }
    if (strcmp(argv[1], "bars") == 0) {
        vision_write(LCD_CTRL, 2);
        cprintf("lcdctl: hardware color bars\n");
        return 0;
    }
    if (strcmp(argv[1], "switch") == 0) {
        vision_write(LCD_CTRL, 0);
        cprintf("lcdctl: SW18/SW19 control restored\n");
        return 0;
    }
    if (strcmp(argv[1], "off") == 0) {
        vision_write(LCD_CTRL, 3);
        cprintf("lcdctl: panel backlight off\n");
        return 0;
    }
    if (strcmp(argv[1], "show") == 0) {
        cprintf("lcdctl: stopping camera and generating RGB565 test card...\n");
        if (vision_lcd_test() != 0) {
            cprintf("lcdctl: frame setup failed\n");
            return 1;
        }
        for (count = 0; count < 40; count++) {
            sleep(50);
            value = vision_read(LCD_STATUS);
            if (value & 0x40u) {
                cprintf("lcdctl: AXI read error, status=0x%08x\n", value);
                return 1;
            }
            if (value & 0x04u) {
                cprintf("lcdctl: test card displayed\n");
                return 0;
            }
        }
        cprintf("lcdctl: display timeout, status=0x%08x\n", value);
        return 1;
    }
    usage();
    return 1;
}
