"""
开环电机驱动模块（支持非线性距离转换）
"""
from machine import Pin, PWM
import time
import utime
import _thread
import udp_c
from arm_reset import arm_reset 
from go_to_origin import arm_origin

# 定义全局变量
start_moving = 0
direction = 0  # (LEFT=0 或 RIGHT=1)
seta = 0.0     # 角度(度)
l = 0.0        # 距离差值

# 电机控制引脚定义
en_pin = Pin(12, Pin.OUT)  # 使能引脚
en_pin.value(0)            # 使能电机

# X轴控制引脚
x_dir = 0
x_pin = Pin(27, Pin.OUT)   # 方向控制
x_pin.value(x_dir)
axis_x_pin = Pin(14, Pin.OUT)  # 脉冲输出

# Y轴控制引脚
y_dir = 0
y_pin = Pin(25, Pin.OUT)   # 方向控制
y_pin.value(y_dir)
axis_y_pin = Pin(26, Pin.OUT)  # 脉冲输出

# Z轴控制引脚
z_dir = 0
z_pin = Pin(32, Pin.OUT)   # 方向控制
z_pin.value(z_dir)
axis_z_pin = Pin(33, Pin.OUT)  # 脉冲输出

# 舵机控制
servo = PWM(Pin(16, Pin.OUT))
servo.freq(50)  # 50Hz PWM频率

# 速度控制 (1-5, 1最快, 5最慢)
time_value = 1

# 机械臂参数
DEGREE_TO_STEPS = 18  # 每度对应的步数 (3649步/90度 ≈ 40.54步/度)

# 距离到步数的分段转换表 (距离范围, 转换系数)
LENGTH_CONVERSION_TABLE = [
    (0, 100, 10),    # 0-100像素: 2.5步/像素
    (100, 200, 12),  # 100-200像素: 2.8步/像素
    (200, 300, 13),  # 200-300像素: 3.2步/像素
    (300, float('inf'), 15)  # 300像素以上: 3.8步/像素
]

def transmit(start_moving_T, direction_T, seta_T, l_T, target_color):
    """接收来自udp_c的运动参数"""
    global start_moving
    if start_moving:
        print("机械臂正在运动，忽略本次指令")
        return 0
    global direction, seta, l
    start_moving = start_moving_T
    direction = direction_T
    if direction == 0:
        seta = seta_T
    else:
        seta = seta_T*1.1
    l = l_T
    
    if start_moving:
        print(f"收到运动指令: 方向={direction}, 角度={seta:.2f}°, 距离={l:.2f}, 目标={target_color}")
        # 使用线程运行机械臂运动
        _thread.start_new_thread(move_arm, (target_color,))
        return 1 

def angle_to_steps(angle):
    """将角度转换为步数"""
    return abs(int(angle * DEGREE_TO_STEPS))

def length_to_steps(length):
    """根据分段转换表将长度转换为步数"""
    steps = 0
    remaining_length = abs(length)
    
    for lower, upper, factor in LENGTH_CONVERSION_TABLE:
        if remaining_length <= 0:
            break
            
        # 计算当前范围内的长度
        range_length = min(remaining_length, upper - lower)
        if range_length > 0:
            steps += int(range_length * factor)
            remaining_length -= range_length
    
    return steps

def move_x_axis(steps, dir_value):
    """控制X轴电机转动指定步数"""
    x_pin.value(dir_value)  # 设置方向
    moved = 0
    for _ in range(steps):
        if dir_value == arm_reset.x_dir and arm_reset.limit_x.value() == 1:
            print("X轴限位触发，停止运动")
            break
        axis_x_pin.value(1)
        utime.sleep_us(time_value * 300)
        axis_x_pin.value(0)
        utime.sleep_us(time_value * 300)
        moved += 1
    return moved

def move_y_axis(steps, dir_value):
    """控制Y轴电机转动指定步数"""
    y_pin.value(dir_value)  # 设置方向
    moved = 0
    for _ in range(steps):
        if dir_value == arm_reset.y_dir and arm_reset.limit_y.value() == 1:
            print("Y轴限位触发，停止运动")
            break
        axis_y_pin.value(1)
        utime.sleep_us(time_value * 300)
        axis_y_pin.value(0)
        utime.sleep_us(time_value * 300)
        moved += 1
    return moved


def move_z_axis(steps, dir_value):
    """控制Z轴电机转动指定步数，并联动Y轴电机"""
    z_pin.value(dir_value)  # 设置方向
    y_steps = 0
    moved = 0
    for i in range(steps):
        if dir_value == arm_reset.z_dir and arm_reset.limit_z.value() == 1:
            print("Z轴限位触发，停止运动")
            break
        axis_z_pin.value(1)
        utime.sleep_us(time_value * 300)
        axis_z_pin.value(0)
        utime.sleep_us(time_value * 300)
        moved += 1
        # 每移动3步Z轴，Y轴移动1步，方向固定为0
        if (i + 1) % 3 == 0:
            move_y_axis(1, 0)
    return moved

def control_servo(position):
    """控制舵机位置"""
    # position: 0-100%, 0=张开, 100=闭合
    duty = int(1638 + (position / 100) * (8192 - 1638))
    servo.duty_u16(duty)
    time.sleep(5)  # 给舵机时间移动

def move_arm(target_color):
    """根据接收到的参数控制机械臂运动"""
    global direction, seta, l
    try:
        # 1. 计算各轴步数
        x_steps = angle_to_steps(seta)
        z_steps = length_to_steps(l)
        # 如果目标为蓝色，Z轴步数减少50步
        print(f"运动参数: X轴={x_steps}步, Z轴={z_steps}步, 方向={direction}")
        #y轴的移动步数是z轴的1/10，同时方向固定为0
        # 2. 控制舵机张开（准备抓取）
        control_servo(0)  # 张开
        # 3. 根据direction设置X轴方向并转动
        x_dir_value = 1 if direction == 1 else 0  # 根据方向设置
        move_x_axis(x_steps, x_dir_value)
        # 4. 根据l的正负设置Z轴方向并转动
        z_dir_value = 0 if l > 0 else 1
        move_z_axis(z_steps, z_dir_value)
        # 5. 控制舵机闭合（抓取物体）
        control_servo(100)  # 闭合
        # 6. 根据目标颜色进行不同处理
        if target_color == 'red':
            print("抓取红色目标后的处理逻辑")#red是丢弃，我们直接调用复位就行
            # 先复位YZ轴，再复位X轴
            arm_reset.reset_yz()  # 交替复位Y轴和Z轴
            time.sleep(1)
            # 复位X轴
            x_steps = arm_reset._reset_single_axis(
                arm_reset.axis_x_pin, arm_reset.x_pin, 
                arm_reset.x_dir, arm_reset.limit_x, "X"
            )
            time.sleep(1)
            control_servo(0)  # 张开
            time.sleep(1)
            arm_origin.go_to_origin()
        elif target_color == 'blue':
            print("抓取蓝色目标后的处理逻辑")
            if direction == 1:
                x_to_blue = x_steps + 3494#dir=0
            else:
                x_to_blue = x_steps - 3494#dir=0
            z_to_blue = 5500-z_steps-2460#dir=0
            y_to_blue = 4300+z_steps/3#dir=1
            print(f"前往绿色区域的步数: X轴={x_to_blue}步, Z轴={z_to_blue}步, Y轴={y_to_blue}步")
            # Z轴和Y轴交替运行
            max_steps = max(z_to_blue, y_to_blue)
            for i in range(max_steps):
                if i < z_to_blue:
                    # Z轴移动
                    z_pin.value(0)  # 设置方向
                    axis_z_pin.value(1)
                    utime.sleep_us(time_value * 300)
                    axis_z_pin.value(0)
                    utime.sleep_us(time_value * 300)
                    # 每移动3步Z轴，Y轴移动1步
                    if (i + 1) % 3 == 0 and (i // 3) < y_to_blue:
                        y_pin.value(1)  # 设置方向
                        axis_y_pin.value(1)
                        utime.sleep_us(time_value * 300)
                        axis_y_pin.value(0)
                        utime.sleep_us(time_value * 300)
                elif i < y_to_blue:
                    # 如果Z轴已完成但Y轴还需要移动
                    y_pin.value(1)  # 设置方向
                    axis_y_pin.value(1)
                    utime.sleep_us(time_value * 300)
                    axis_y_pin.value(0)
                    utime.sleep_us(time_value * 300)
            move_x_axis(abs(x_to_blue), 0)
            time.sleep(1)
            control_servo(0)  # 张开
            time.sleep(1)
            print("去原点")
            arm_reset.full_reset() 
            time.sleep(1)
            arm_origin.go_to_origin()
            time.sleep(1)
            control_servo(85)  # 闭合
        # 7. 重置运动标志
        global start_moving
        start_moving = 0
        print("机械臂运动完成")
    except Exception as e:
        print(f"运动控制出错: {e}")
        # 发生错误时重置运动标志
        start_moving = 0
