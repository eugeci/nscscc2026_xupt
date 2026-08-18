from machine import Pin
import time


limit_x = Pin(36, Pin.IN)
limit_y = Pin(39, Pin.IN)
limit_z = Pin(34, Pin.IN)

while True:
    if limit_x.value() == 0:
        print("x轴限位器，没有触碰")
    else:
        print("x轴限位器，已触碰")
    
    if limit_y.value() == 0:
        print("y轴限位器，没有触碰")
    else:
        print("y轴限位器，已触碰")
    
    if limit_z.value() == 0:
        print("z轴限位器，没有触碰")
    else:
        print("z轴限位器，已触碰")
        
    print("-------------------------------------")

    time.sleep(1)
