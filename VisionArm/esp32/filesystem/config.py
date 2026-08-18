"""
代码名称：config.py  
代码用处：将多个模块需要复用的io口保存，减少代码长度与冗余 
"""
from machine import Pin 
 
# 使能引脚 
EN_PIN = Pin(12, Pin.OUT)
 
# X轴配置 
X_DIR_PIN = Pin(27, Pin.OUT)
X_STEP_PIN = Pin(14, Pin.OUT)
X_LIMIT_PIN = Pin(36, Pin.IN)  # 新增X轴限位器 
 
# Y轴配置 
Y_DIR_PIN = Pin(25, Pin.OUT)
Y_STEP_PIN = Pin(26, Pin.OUT)
Y_LIMIT_PIN = Pin(39, Pin.IN)  # 新增Y轴限位器 
 
# Z轴配置 
Z_DIR_PIN = Pin(32, Pin.OUT)
Z_STEP_PIN = Pin(33, Pin.OUT)
Z_LIMIT_PIN = Pin(34, Pin.IN)  # 新增Z轴限位器 
 
# 方向常量 (根据实际测试结果)
DIR_TO_LIMIT = {
    'x': 1,  # X轴向1方向运动靠近限位器 
    'y': 1,  # Y轴向1方向运动靠近限位器 
    'z': 0   # Z轴向0方向运动靠近限位器 
}
