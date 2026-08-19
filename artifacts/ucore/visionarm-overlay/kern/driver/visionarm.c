#include <defs.h>
#include <visionarm.h>

#define VISION_UNCACHED_BASE 0x80000000u

#define ARM_UART             0x1fd0e010u

#define CAM_CTRL             0x1fd0e100u
#define CAM_LAST_LINEAR      0x1fd0e124u
#define CAM_MAGIC            0x1fd0e13cu

#define LCD_CTRL             0x1fd0e140u
#define LCD_FB               0x1fd0e144u
#define LCD_STATUS           0x1fd0e148u
#define LCD_LAST             0x1fd0e150u

#define LCD_FRAME_PHYS       0x07800000u
#define LCD_WIDTH            800u
#define LCD_HEIGHT           480u

static inline void
visionarm_dbar(void) {
    /* dbar 0; kept as an instruction word for the older LA32R assembler. */
    asm volatile(".word 0x38720000" ::: "memory");
}

static bool
visionarm_register_valid(uint32_t address) {
    if ((address & 3u) != 0) {
        return 0;
    }
    if (address == ARM_UART || address == CAM_MAGIC) {
        return 1;
    }
    if (address >= CAM_CTRL && address <= CAM_LAST_LINEAR) {
        return 1;
    }
    if (address >= LCD_CTRL && address <= LCD_LAST) {
        return 1;
    }
    return 0;
}

static inline volatile uint32_t *
visionarm_register(uint32_t address) {
    return (volatile uint32_t *)(VISION_UNCACHED_BASE | address);
}

uint32_t
visionarm_mmio_read(uint32_t address) {
    if (!visionarm_register_valid(address)) {
        return 0xffffffffu;
    }
    visionarm_dbar();
    return *visionarm_register(address);
}

int
visionarm_mmio_write(uint32_t address, uint32_t value) {
    if (!visionarm_register_valid(address)) {
        return -1;
    }
    *visionarm_register(address) = value;
    visionarm_dbar();
    return 0;
}

static uint32_t
visionarm_test_pixel(uint32_t x, uint32_t y) {
    static const uint32_t bars[8] = {
        0xffff, 0xffe0, 0x07ff, 0x07e0,
        0xf81f, 0xf800, 0x001f, 0x0000,
    };
    uint32_t pixel = bars[x / 100u];

    /* White crosshair makes line order and full-frame refresh obvious. */
    if (x == LCD_WIDTH / 2u || y == LCD_HEIGHT / 2u) {
        pixel = 0xffff;
    }
    return pixel;
}

int
visionarm_lcd_test_pattern(void) {
    volatile uint32_t *frame =
        (volatile uint32_t *)(VISION_UNCACHED_BASE | LCD_FRAME_PHYS);
    uint32_t x, y;
    uint32_t old_control;
    uint32_t toggle;

    /* LCD and camera share the DDR MM2S path. Stop camera before filling it. */
    visionarm_mmio_write(CAM_CTRL, 0);

    for (y = 0; y < LCD_HEIGHT; y++) {
        for (x = 0; x < LCD_WIDTH; x += 2) {
            uint32_t low = visionarm_test_pixel(x, y);
            uint32_t high = visionarm_test_pixel(x + 1, y);
            *frame++ = low | (high << 16);
        }
    }
    visionarm_dbar();

    visionarm_mmio_write(LCD_FB, LCD_FRAME_PHYS);
    old_control = visionarm_mmio_read(LCD_CTRL);
    toggle = (old_control ^ 0x100u) & 0x100u;
    return visionarm_mmio_write(LCD_CTRL, toggle | 1u);
}
