import socket
import network
import time
import uselect
import math
import motor_c

# WiFi配置
WIFI_SSID = 'iQOO'
WIFI_PASSWORD = '1234567890'
SERVER_PORT = 1234

# 全局变量
red_x = 0     # 红色目标X坐标 (xb)
red_y = 0     # 红色目标Y坐标 (yb)
green_x = 0   # 绿色夹爪X坐标 (xa)
green_y = 0   # 绿色夹爪Y坐标 (ya)
blue_x = 0    # 蓝色目标X坐标 (xb2)
blue_y = 0    # 蓝色目标Y坐标 (yb2)
start_moving = 0
s = None      # 套接字全局变量

# 机械臂参数
ROTATION_RADIUS = 50.0    # 旋转半径
IMAGE_CENTER_X = 320.0    # 图像中心点X坐标
IMAGE_CENTER_Y = 480.0    # 图像中心点Y坐标

# 方向常量
LEFT = 0
RIGHT = 1

def re_start():
    global start_moving
    start_moving = 0

def connect_wifi():
    wlan = network.WLAN(network.STA_IF)
    wlan.active(True)
    if not wlan.isconnected():
        print('正在连接WiFi...')
        wlan.connect(WIFI_SSID, WIFI_PASSWORD)
        while not wlan.isconnected():
            time.sleep(0.5)
    print('网络配置:', wlan.ifconfig())

def parse_coordinates(data):
    """解析接收到的坐标数据 (格式: "Rxxx,xxx Cxxx,xxx Bxxx,xxx")"""
    global red_x, red_y, green_x, green_y, blue_x, blue_y, start_moving
    try:
        # 分割红色目标、绿色夹爪和蓝色目标坐标
        parts = data.split()
        
        for part in parts:
            if part.startswith('R'):  # 红色目标坐标
                coords = part[1:].split(',')
                if len(coords) == 2:
                    red_x = int(coords[0])
                    red_y = int(coords[1])
                    print(f"红色目标坐标: X={red_x}, Y={red_y}")
            elif part.startswith('C'):  # 绿色夹爪坐标
                coords = part[1:].split(',')
                if len(coords) == 2:
                    green_x = int(coords[0])
                    green_y = int(coords[1])
                    print(f"绿色夹爪坐标: X={green_x}, Y={green_y}")
            elif part.startswith('B'):  # 蓝色目标坐标
                coords = part[1:].split(',')
                if len(coords) == 2:
                    blue_x = int(coords[0])
                    blue_y = int(coords[1])
                    print(f"蓝色目标坐标: X={blue_x}, Y={blue_y}")
        
        # 当同时接收到红色、绿色和蓝色坐标时，启动运动
        if 'R' in data and 'C' in data and 'B' in data:
            start_moving = 1
            print("接收到完整坐标，开始运动")
        else:
            print("坐标不完整，等待更多数据")
            
    except Exception as e:
        print("数据解析错误:", e)

def calculate_arm_movement(xb, yb, xa, ya):
    """
    计算机械臂运动参数
    
    参数:
    xb, yb - 目标点在图像中的坐标
    xa, ya - 机械臂当前位置
    
    返回:
    direction - 转动方向标志 (LEFT=0 或 RIGHT=1)
    seta - 计算得到的角度(度)
    l - 计算得到的距离差值
    """
    # 判断转动方向
    if xb >= IMAGE_CENTER_X:
        direction = RIGHT  # 右转
    else:
        direction = LEFT   # 左转
    
    # 计算相对坐标差
    dx = abs(xb - IMAGE_CENTER_X)
    dy = abs(IMAGE_CENTER_Y - yb)
    
    # 计算seta角度
    if dy == 0:  # 防止除以零
        seta_rad = math.pi / 2  # 90度
    else:
        seta_rad = math.atan(dx / dy)
    seta_deg = math.degrees(seta_rad)
    
    # 计算中间参数
    half_seta = seta_rad / 2
    sin_half = math.sin(half_seta)
    cos_half = math.cos(half_seta)
    sin_seta = math.sin(seta_rad)
    cos_seta = math.cos(seta_rad)
    
    # 计算A和B
    A = 2 * ROTATION_RADIUS * sin_half * sin_seta
    B = 2 * ROTATION_RADIUS * sin_half * cos_seta
    
    # 根据方向决定加减B
    xap = xa + B if direction == RIGHT else xa - B
    yap = ya + A
    
    # 计算距离l
    dist_before = math.sqrt((xb - IMAGE_CENTER_X)**2 + (IMAGE_CENTER_Y - yb)**2)
    dist_after = math.sqrt((xap - IMAGE_CENTER_X)**2 + (IMAGE_CENTER_Y - yap)**2)
    l = dist_before - dist_after
    
    return direction, seta_deg, l

def handle_hello_message(data_str, addr):
    """处理上位机发送的HELLO消息"""
    if data_str.strip() == "HELLO":
        try:
            response = "ARMOK"
            s.sendto(response.encode('utf-8'), addr)
            print(f"收到HELLO消息，回复ARMOK到 {addr}")
        except Exception as e:
            print(f"回复ARMOK失败: {e}")

def start_server():
    global s
    connect_wifi()
    
    # 创建UDP套接字
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(('0.0.0.0', SERVER_PORT))
    
    poller = uselect.poll()
    poller.register(s, uselect.POLLIN)
    
    print("ESP32坐标接收器已启动，等待数据...")
    
    try:
        while True:
            res = poller.poll(1000)  # 超时1秒
            if res:
                try:
                    data, addr = s.recvfrom(1024)
                    data_str = data.decode('utf-8').strip()
                    
                    # 检查是否是HELLO消息
                    if data_str == "HELLO":
                        handle_hello_message(data_str, addr)
                        continue
                    
                    # 检查是否为单轴手动控制指令
                    if data_str in ["1", "2", "3", "4", "5", "6"]:
                        if data_str == "1":
                            print("X轴正转100步")
                            motor_c.move_x_axis(100, 1)
                        elif data_str == "2":
                            print("X轴反转100步")
                            motor_c.move_x_axis(100, 0)
                        elif data_str == "3":
                            print("Y轴正转100步")
                            motor_c.move_y_axis(100, 1)
                        elif data_str == "4":
                            print("Y轴反转100步")
                            motor_c.move_y_axis(100, 0)
                        elif data_str == "5":
                            print("Z轴正转100步")
                            motor_c.move_z_axis(100, 1)
                        elif data_str == "6":
                            print("Z轴反转100步")
                            motor_c.move_z_axis(100, 0)
                        continue

                    # 处理坐标数据
                    parse_coordinates(data_str)
                    
                    # 接收到完整坐标后计算运动参数并控制电机
                    if start_moving:
                        # 计算红色目标的运动参数
                        red_direction, red_seta, red_l = calculate_arm_movement(red_x, red_y, green_x, green_y)
                        print(f"红色目标计算结果: 方向={red_direction}, seta={red_seta:.2f}°, l={red_l:.2f}")
                        
                        # 调用电机控制函数执行红色目标
                        print("开始执行红色目标抓取...")
                        while True:
                            result = motor_c.transmit(1, red_direction, red_seta, red_l, 'red')
                            if result == 1:
                                break  # 成功发送红色方向指令，跳出循环
                            time.sleep(0.5)   
                        
                        # 等待红色目标运动完成
                        print("等待红色目标运动完成...")
                        while motor_c.start_moving:
                            time.sleep(0.1)
                        print("红色目标运动完成")
                        
                        # 短暂延时确保机械臂稳定
                        time.sleep(2)
                        
                        # 计算蓝色目标的运动参数
                        blue_direction, blue_seta, blue_l = calculate_arm_movement(blue_x, blue_y, green_x, green_y)
                        print(f"蓝色目标计算结果: 方向={blue_direction}, seta={blue_seta:.2f}°, l={blue_l:.2f}")
                        
                        # 调用电机控制函数执行蓝色目标
                        print("开始执行蓝色目标抓取...")
                        while True:
                            result = motor_c.transmit(1, blue_direction, blue_seta, blue_l, 'blue')
                            if result == 1:
                                break  # 成功发送蓝色方向指令，跳出循环
                            time.sleep(0.5) 
                        
                        # 等待蓝色目标运动完成
                        print("等待蓝色目标运动完成...")
                        while motor_c.start_moving:
                            time.sleep(0.1)
                        print("蓝色目标运动完成")
                        
                        # 所有运动完成后重置标志
                        re_start()
                        print("所有目标抓取完成")
                        
                except Exception as e:
                    print("接收错误:", e)
                    time.sleep(1)
    except KeyboardInterrupt:
        print("\n正在关闭服务器...")
    finally:
        if s:
            s.close()
        print("服务器已关闭")

if __name__ == "__main__":
    start_server()