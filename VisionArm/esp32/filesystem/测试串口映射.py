from machine import UART, Pin, Timer
import time
import utime

# 初始化UART2 (RX=GPIO13, TX=GPIO15)
uart2 = UART(2, baudrate=115200, rx=13, tx=15)

# 定时发送计数器
send_count = 0

# 定时器回调函数（每2秒触发）
def send_hello(timer):
    global send_count
    message = "hello " + str(send_count) + "\n"
    uart2.write(message) 
    print("[SEND] " + message.strip()) 
    send_count += 1

# 初始化硬件定时器（周期2秒）
timer = Timer(0)
timer.init(period=2000,  mode=Timer.PERIODIC, callback=send_hello)

print("UART2回环测试开始 (RX=GPIO13, TX=GPIO15)")
print("请用杜邦线连接GPIO13和GPIO15")
print("----------------------------------")

# 主循环检测接收数据
while True:
    if uart2.any():   # 检查接收缓冲区
        received = uart2.read().decode().strip() 
        print("[RECV] " + received)
    time.sleep(0.1)   # 防止CPU占用过高