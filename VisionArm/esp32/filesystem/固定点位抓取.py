"""
开环电机驱动模块 - 修正版 
"""
from machine import Pin, PWM 
import time
import utime
import _thread
from arm_reset import arm_reset 
# 电机方向定义
X_DIR = 1  # X轴方向：1表示靠近限位器
Y_DIR = 1  # Y轴方向：1表示靠近限位器
Z_DIR = 0  # Z轴方向：0表示靠近限位器
 
# 初始化使能引脚 
en_pin = Pin(12, Pin.OUT)
en_pin.value(0)   # 默认启用电机(根据实际驱动板逻辑，可能需要设为0)
 
# 初始化各轴引脚 
# X轴 
x_dir_pin = Pin(27, Pin.OUT)
x_step_pin = Pin(14, Pin.OUT)
 
# Y轴 
y_dir_pin = Pin(25, Pin.OUT)
y_step_pin = Pin(26, Pin.OUT)
 
# Z轴 
z_dir_pin = Pin(32, Pin.OUT)
z_step_pin = Pin(33, Pin.OUT)
 
# 初始化舵机 
servo = PWM(Pin(16, Pin.OUT))
servo.freq(50) 
 
# 默认速度 (1-5, 1最快5最慢)
speed = 3
# 速度对应的延迟时间(微秒)
SPEED_DELAY = {
    1: 300,
    2: 1000,
    3: 1500,
    4: 2000,
    5: 2500
}
 
def set_speed(new_speed):
    """设置电机移动速度"""
    global speed
    if 1 <= new_speed <= 5:
        speed = new_speed 
    else:
        print("速度值应在1-5范围内")
 
def move_axis(axis, steps):
    """
    移动单个轴 
    :param axis: 'x', 'y' 或 'z'
    :param steps: 移动步数 (正数表示默认方向，负数表示相反方向)
    """
    if steps == 0:
        return 
        
    # 获取对应轴的引脚 
    if axis.lower()  == 'x':
        dir_pin = x_dir_pin 
        step_pin = x_step_pin 
        default_dir = X_DIR
    elif axis.lower()  == 'y':
        dir_pin = y_dir_pin 
        step_pin = y_step_pin 
        default_dir = Y_DIR
    elif axis.lower()  == 'z':
        dir_pin = z_dir_pin 
        step_pin = z_step_pin 
        default_dir = Z_DIR
    else:
        print(f"无效的轴: {axis}")
        return 
    
    # 设置方向 
    direction = default_dir if steps > 0 else (1 - default_dir)
    dir_pin.value(direction) 
    
    # 启用电机
    en_pin.value(0)   # 根据实际驱动板逻辑，可能需要设为0或1 
    
    # 移动指定步数 
    delay = SPEED_DELAY.get(speed,  1500)
    steps = abs(steps)
    
    for _ in range(steps):
        step_pin.value(1) 
        utime.sleep_us(delay) 
        step_pin.value(0) 
        utime.sleep_us(delay) 
    
    # 禁用电机(如果需要)
    # en_pin.value(1) 
 
def move_xyz(x_steps, y_steps, z_steps):
    """
    按顺序移动XYZ三个轴
    :param x_steps: X轴移动步数 
    :param y_steps: Y轴移动步数
    :param z_steps: Z轴移动步数 
    """
    if x_steps != 0:
        move_axis('x', x_steps)
    if y_steps != 0:
        move_axis('y', y_steps)
    if z_steps != 0:
        move_axis('z', z_steps)
 
def move_xyz_simultaneous(x_steps, y_steps, z_steps):
    """
    同时移动XYZ三个轴(实验性功能)
    """
    # 设置各轴方向 
    x_dir_pin.value(X_DIR  if x_steps >= 0 else (1 - X_DIR))
    y_dir_pin.value(Y_DIR  if y_steps >= 0 else (1 - Y_DIR))
    z_dir_pin.value(Z_DIR  if z_steps >= 0 else (1 - Z_DIR))
    
    x_steps = abs(x_steps)
    y_steps = abs(y_steps)
    z_steps = abs(z_steps)
    
    max_steps = max(x_steps, y_steps, z_steps)
    if max_steps == 0:
        return
    
    delay = SPEED_DELAY.get(speed,  1500)
    
    # 启用电机 
    en_pin.value(0) 
    
    for i in range(max_steps):
        if i < x_steps:
            x_step_pin.value(1) 
        if i < y_steps:
            y_step_pin.value(1) 
        if i < z_steps:
            z_step_pin.value(1) 
        
        utime.sleep_us(delay) 
        
        x_step_pin.value(0) 
        y_step_pin.value(0) 
        z_step_pin.value(0) 
        
        utime.sleep_us(delay) 
    
    # 禁用电机(如果需要)
    # en_pin.value(1) 
 
def move_servo(position):
    """控制舵机位置"""
    if position == 'open':
        servo.duty_u16(4096) 
    elif position == 'close':
        servo.duty_u16(8191) 
    time.sleep(0.1) 
 
# 测试函数 
def test_movement():
    print("测试X轴正转100步")
    move_axis('x', 100)
    time.sleep(5) 
    
    print("测试X轴反转100步")
    move_axis('x', -100)
    time.sleep(5) 
    
    print("测试Y轴正转100步")
    move_axis('y', 100)
    time.sleep(5) 
    
    print("测试Y轴反转100步")
    move_axis('y', -100)
    time.sleep(5) 
    
    print("测试Z轴正转100步")
    move_axis('z', 100)
    time.sleep(5) 
    
    print("测试Z轴反转100步")
    move_axis('z', -100)
    time.sleep(5) 
    
    print("测试顺序移动XYZ轴")
    move_xyz(200, 150, 100)
    time.sleep(5) 
    
    print("测试同时移动XYZ轴")
    move_xyz_simultaneous(-100, -50, 50)
    time.sleep(5) 
    
    print("测试舵机控制")
    move_servo('open')
    time.sleep(10) 
    move_servo('close')
#点位1：X轴:5419步, Y轴:5426步, Z轴:2655步(3)
#2 X轴:2980步, Y轴:5488步, Z轴:2780步(1)
#3 X轴:4329步, Y轴:4847步, Z轴:3870步()2
#去对面 x all 7272步
#复位后朝下，更好放置：Y轴:2170步, Z轴:2843步
if __name__ == "__main__":
    # 设置速度为3
    arm_reset.full_reset()
    set_speed(1)
    move_servo('open')
    time.sleep(3)
    move_axis('x', -2980)
    move_xyz_simultaneous(0,-5488,-2780)
    time.sleep(1)
    move_servo('close')
    time.sleep(6)
    move_xyz_simultaneous(0,3000,1000)
    arm_reset.full_reset()
    move_xyz_simultaneous(0,-2170,-2850)
    time.sleep(1)
    move_servo('open')
    time.sleep(2)
    ############
    arm_reset.full_reset()
    set_speed(1)
    move_servo('open')
    time.sleep(3)
    move_axis('x', -4329)
    move_xyz_simultaneous(0,-4847,-3870)
    time.sleep(1)
    move_servo('close')
    time.sleep(6)
    arm_reset.reset_yz()
    move_axis('x', -7272+4329)
    move_xyz_simultaneous(0,-2170,-2850)
    time.sleep(1)
    move_servo('open')
    time.sleep(3)
    ################
    #arm_reset.full_reset()
    arm_reset.reset_yz()
    set_speed(1)
    move_servo('open')
    time.sleep(3)
    move_axis('x', 7272-5430)
    move_xyz_simultaneous(0,-5560,-2900)
    time.sleep(1)
    move_servo('close')
    time.sleep(6)
    move_xyz_simultaneous(0,3000,1000)
    arm_reset.full_reset()
    move_xyz_simultaneous(0,-2170,-2850)
    time.sleep(1)
    move_servo('open')
    time.sleep(3)
    ###
    
    """
    move_servo('open')
    print("zhangkai")
    time.sleep(2)
    move_servo('close')
    print("heqi")
    """