#include <stdio.h>
#include <string.h>
#include <ulib.h>

#define CAM_CTRL        0x1fd0e100u
#define CAM_STATUS      0x1fd0e104u
#define CAM_ACTIVITY    0x1fd0e108u
#define CAM_S2MM        0x1fd0e10cu
#define CAM_MM2S        0x1fd0e110u
#define CAM_FRAME0      0x1fd0e114u
#define CAM_FRAME1      0x1fd0e118u
#define CAM_OUTPUT_SIZE 0x1fd0e11cu
#define CAM_INPUT_SIZE  0x1fd0e120u
#define CAM_STRIDE      0x1fd0e124u
#define CAM_MAGIC       0x1fd0e13cu

static const char *yesno(uint32_t value, int bit) {
    return (value & (1u << bit)) ? "yes" : "no";
}

static void usage(void) {
    cprintf("Usage: cam on|off|status|info|test\n");
}

static void status(void) {
    uint32_t control = vision_read(CAM_CTRL);
    uint32_t value = vision_read(CAM_STATUS);
    uint32_t activity = vision_read(CAM_ACTIVITY);

    cprintf("Camera control : 0x%08x\n", control);
    cprintf("Camera status  : 0x%08x\n", value);
    cprintf("Video activity : 0x%08x\n", activity);
    cprintf("Sensor ID OK   : %s\n", yesno(value, 0));
    cprintf("SCCB init done : %s\n", yesno(value, 1));
    cprintf("SCCB error     : %s\n", yesno(value, 2));
    cprintf("PCLK/VS/HREF   : %s/%s/%s\n", yesno(value, 3),
            yesno(value, 4), yesno(value, 5));
    cprintf("DMA enabled    : %s\n", yesno(value, 6));
    cprintf("VDMA init done : %s\n", yesno(value, 7));
    cprintf("VDMA error     : %s\n", yesno(value, 8));
    cprintf("FIFO full/ovf  : %s/%s\n", yesno(value, 9), yesno(value, 10));
    cprintf("S2MM frame     : %s\n", yesno(value, 11));
    cprintf("MM2S data/SOF  : %s/%s\n", yesno(value, 13), yesno(value, 14));
    cprintf("VGA underflow  : %s\n", yesno(value, 15));
    cprintf("Software enable: %s\n", yesno(value, 17));
    cprintf("VGA terminal   : %s\n", yesno(value, 18));
}

static void info(void) {
    cprintf("Version magic  : 0x%08x (expected 0x43414d31)\n",
            vision_read(CAM_MAGIC));
    cprintf("Sensor input   : 0x%08x\n", vision_read(CAM_INPUT_SIZE));
    cprintf("DDR/VGA output : 0x%08x\n", vision_read(CAM_OUTPUT_SIZE));
    cprintf("Line stride    : 0x%08x\n", vision_read(CAM_STRIDE));
    cprintf("Frame buffer 0 : 0x%08x\n", vision_read(CAM_FRAME0));
    cprintf("Frame buffer 1 : 0x%08x\n", vision_read(CAM_FRAME1));
    cprintf("VDMA S2MM      : 0x%08x\n", vision_read(CAM_S2MM));
    cprintf("VDMA MM2S      : 0x%08x\n", vision_read(CAM_MM2S));
}

int main(int argc, char **argv) {
    uint32_t value;
    uint32_t first;
    uint32_t second;
    int failures = 0;

    if (argc != 2) {
        usage();
        return 1;
    }
    if (strcmp(argv[1], "on") == 0) {
        vision_write(CAM_CTRL, 1);
        sleep(200);
        value = vision_read(CAM_STATUS);
        cprintf("cam: camera DMA start requested, status=0x%08x\n", value);
        return (value & (1u << 6)) ? 0 : 1;
    }
    if (strcmp(argv[1], "off") == 0) {
        vision_write(CAM_CTRL, 0);
        cprintf("cam: DMA stopped; VGA terminal selected\n");
        return 0;
    }
    if (strcmp(argv[1], "status") == 0) {
        status();
        return 0;
    }
    if (strcmp(argv[1], "info") == 0) {
        info();
        return 0;
    }
    if (strcmp(argv[1], "test") == 0) {
        value = vision_read(CAM_MAGIC);
        if (value != 0x43414d31u) {
            cprintf("FAIL: camera magic=0x%08x\n", value);
            failures++;
        }
        value = vision_read(CAM_STATUS);
        if ((value & 0x3bu) != 0x3bu) {
            cprintf("FAIL: sensor status=0x%08x\n", value);
            failures++;
        }
        first = vision_read(CAM_ACTIVITY);
        sleep(500);
        second = vision_read(CAM_ACTIVITY);
        cprintf("Activity: 0x%08x -> 0x%08x\n", first, second);
        if (second == first) {
            failures++;
        }
        cprintf(failures ? "CAMERA_TEST_FAIL\n" : "CAMERA_TEST_PASS\n");
        return failures ? 1 : 0;
    }
    usage();
    return 1;
}
