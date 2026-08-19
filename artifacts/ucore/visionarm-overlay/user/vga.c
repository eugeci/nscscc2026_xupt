#include <stdio.h>
#include <string.h>
#include <ulib.h>

#define CAM_CTRL   0x1fd0e100u
#define CAM_STATUS 0x1fd0e104u

static void usage(void) {
    cprintf("Usage: vga terminal|camera|status\n");
}

int main(int argc, char **argv) {
    uint32_t value;

    if (argc != 2) {
        usage();
        return 1;
    }
    if (strcmp(argv[1], "terminal") == 0) {
        vision_write(CAM_CTRL, 0);
        cprintf("vga: terminal selected (camera DMA stopped)\n");
        return 0;
    }
    if (strcmp(argv[1], "camera") == 0) {
        vision_write(CAM_CTRL, 1);
        sleep(200);
        value = vision_read(CAM_STATUS);
        cprintf("vga: camera selected, status=0x%08x\n", value);
        return (value & (1u << 6)) ? 0 : 1;
    }
    if (strcmp(argv[1], "status") == 0) {
        value = vision_read(CAM_STATUS);
        cprintf("VGA source: %s (status=0x%08x)\n",
                (value & (1u << 18)) ? "terminal" : "camera", value);
        return 0;
    }
    usage();
    return 1;
}
