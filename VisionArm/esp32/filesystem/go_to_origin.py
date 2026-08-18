# go_to_origin.py  
from machine import Pin 
import utime 
 
class ArmOrigin:
    def __init__(self):
        # 初始化所有引脚 
        self._init_pins()
        
        # 运动参数 
        self.time_value  = 1  # 速度 (1最快，5最慢)
        self.yz_step_interval  = 10  # Y/Z交替步数 
        
        # 原点步数（根据你的实测数据）
        self.origin_steps  = {
            'x': 3800,  # X轴到原点需3649步 
            'y': 4419,  # Y轴 
            'z': 5081   # Z轴 
        }
        
        # 运动方向（根据你的描述）
        self.dir_to_origin  = {
            'x': 0,  # X轴方向（你提供的代码中是0）
            'y': 0,  # Y轴方向 
            'z': 1   # Z轴方向 
        }
 
    def _init_pins(self):
        """初始化电机引脚"""
        # 使能引脚 
        self.en_pin  = Pin(12, Pin.OUT)
        
        # 电机方向引脚 
        self.x_pin = Pin(27, Pin.OUT)
        self.y_pin = Pin(25, Pin.OUT)
        self.z_pin = Pin(32, Pin.OUT)
        
        # 电机步进引脚 
        self.axis_x_pin  = Pin(14, Pin.OUT)
        self.axis_y_pin  = Pin(26, Pin.OUT)
        self.axis_z_pin  = Pin(33, Pin.OUT)
 
    def unlock_motors(self):
        """解锁电机（允许手动调整）"""
        self.en_pin.value(1) 
        print("电机已解锁")
        return self 
 
    def lock_motors(self):
        """锁定电机（准备程序控制）"""
        self.en_pin.value(0) 
        print("电机已锁定")
        return self 
 
    def _move_x(self):
        """X轴单独运动到原点"""
        self.x_pin.value(self.dir_to_origin['x']) 
        print("X轴运动中...")
        
        for _ in range(self.origin_steps['x']): 
            self.axis_x_pin.value(1) 
            utime.sleep_us(self.time_value  * 200)
            self.axis_x_pin.value(0) 
            utime.sleep_us(self.time_value  * 200)
        
        print(f"X轴到达原点 (共{self.origin_steps['x']} 步)")
 
    def _move_yz_alternating(self):
        """Y轴和Z轴交替运动到原点"""
        self.y_pin.value(self.dir_to_origin['y']) 
        self.z_pin.value(self.dir_to_origin['z']) 
        print("Y/Z轴交替运动中...")
        
        y_steps = 0 
        z_steps = 0 
        
        while y_steps < self.origin_steps['y']  or z_steps < self.origin_steps['z']: 
            # Y轴运动（如果还没走完）
            if y_steps < self.origin_steps['y']: 
                for _ in range(min(self.yz_step_interval,  self.origin_steps['y']  - y_steps)):
                    self.axis_y_pin.value(1) 
                    utime.sleep_us(self.time_value  * 200)
                    self.axis_y_pin.value(0) 
                    utime.sleep_us(self.time_value  * 200)
                    y_steps += 1 
            
            # Z轴运动（如果还没走完）
            if z_steps < self.origin_steps['z']: 
                for _ in range(min(self.yz_step_interval,  self.origin_steps['z']  - z_steps)):
                    self.axis_z_pin.value(1) 
                    utime.sleep_us(self.time_value  * 200)
                    self.axis_z_pin.value(0) 
                    utime.sleep_us(self.time_value  * 200)
                    z_steps += 1 
        
        print(f"Y轴到达原点 (共{y_steps}步), Z轴到达原点 (共{z_steps}步)")
 
    def go_to_origin(self):
        """运动到原点（X单独，Y/Z交替）"""
        try:
            self.lock_motors() 
            self._move_x()          # X轴单独运动 
            self._move_yz_alternating()  # Y/Z轴交替运动 
            print("机械臂已到达原点位置！")
            return True 
        except Exception as e:
            print(f"运动出错: {e}")
            self.unlock_motors() 
            return False 
 
    def set_speed(self, level):
        """设置速度 (1-5)"""
        self.time_value  = level 
        print(f"速度设置为: {level}")
        return self 
 
    def set_yz_interval(self, steps):
        """设置Y/Z交替步数"""
        self.yz_step_interval  = steps 
        print(f"Y/Z交替步数设置为: {steps}") 
        return self 
 
# 全局实例 
arm_origin = ArmOrigin()
 
# 使用示例 
if __name__ == "__main__":
    arm_origin.set_speed(2).set_yz_interval(30).go_to_origin() 

