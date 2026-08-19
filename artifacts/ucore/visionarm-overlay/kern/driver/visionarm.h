#ifndef __KERN_DRIVER_VISIONARM_H__
#define __KERN_DRIVER_VISIONARM_H__

#include <defs.h>

#define VISION_MMIO_READ  0
#define VISION_MMIO_WRITE 1

uint32_t visionarm_mmio_read(uint32_t address);
int visionarm_mmio_write(uint32_t address, uint32_t value);
int visionarm_lcd_test_pattern(void);

#endif
