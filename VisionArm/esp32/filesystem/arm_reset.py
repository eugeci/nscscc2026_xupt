# arm_reset.py    
import utime 
from config import *
 
class ArmReset:
    def __init__(self):
        # 从config.py   导入所有配置 
        self._init_settings()
        
        # 速度设置 (1快5慢)
        self.time_value  = 1
        # YZ轴交替步进时的步数 
        self.yz_step_interval  = 10 
        
    def _init_settings(self):
        """从config.py   初始化设置"""
        # 电机方向设置 
        self.x_dir = DIR_TO_LIMIT['x']
        self.y_dir = DIR_TO_LIMIT['y']
        self.z_dir = DIR_TO_LIMIT['z']
        
        # 使能引脚 
        self.en_pin  = EN_PIN 
        
        # 电机控制引脚 
        self.x_pin = X_DIR_PIN 
        self.y_pin = Y_DIR_PIN 
        self.z_pin = Z_DIR_PIN 
        
        self.axis_x_pin  = X_STEP_PIN 
        self.axis_y_pin  = Y_STEP_PIN 
        self.axis_z_pin  = Z_STEP_PIN 
        
        # 限位器引脚 
        self.limit_x  = X_LIMIT_PIN 
        self.limit_y  = Y_LIMIT_PIN 
        self.limit_z  = Z_LIMIT_PIN 
    
    def unlock_motors(self):
        """解锁电机，允许手动调整"""
        self.en_pin.value(1)   
        print("电机已解锁，可以手动调整机械臂位置")
        return self  # 返回self以支持链式调用 
    
    def lock_motors(self):
        """锁定电机，准备程序控制"""
        self.en_pin.value(0)   
        print("电机已锁定，准备程序控制")
        return self 
    
    def _reset_single_axis(self, axis_pin, dir_pin, direction, limit_pin, axis_name):
        """内部方法：复位单个轴"""
        dir_pin.value(direction)   
        print(f"开始复位{axis_name}轴...")
        
        steps = 0 
        while limit_pin.value()  == 0:
            axis_pin.value(1)   
            utime.sleep_us(self.time_value  * 200)
            axis_pin.value(0)   
            utime.sleep_us(self.time_value  * 200)
            steps += 1 
            
        print(f"{axis_name}轴已复位到限位位置 (共{steps}步)")
        return steps 
    
    def _reset_yz_alternating(self):
        """内部方法：交替复位Y轴和Z轴"""
        self.y_pin.value(self.y_dir)   
        self.z_pin.value(self.z_dir)   
        print("开始交替复位Y轴和Z轴...")
        
        y_limit_reached = False 
        z_limit_reached = False 
        y_steps = 0 
        z_steps = 0 
        
        while not (y_limit_reached and z_limit_reached):
            # 运动Y轴 
            if not y_limit_reached:
                for _ in range(self.yz_step_interval):   
                    if self.limit_y.value()  == 1:
                        y_limit_reached = True 
                        print("Y轴已到达限位位置")
                        break 
                    self.axis_y_pin.value(1)   
                    utime.sleep_us(self.time_value  * 200)
                    self.axis_y_pin.value(0)   
                    utime.sleep_us(self.time_value  * 200)
                    y_steps += 1 
            
            # 运动Z轴 
            if not z_limit_reached:
                for _ in range(self.yz_step_interval):   
                    if self.limit_z.value()  == 1:
                        z_limit_reached = True 
                        print("Z轴已到达限位位置")
                        break 
                    self.axis_z_pin.value(1)   
                    utime.sleep_us(self.time_value  * 200)
                    self.axis_z_pin.value(0)   
                    utime.sleep_us(self.time_value  * 200)
                    z_steps += 1 
        
        print(f"Y轴和Z轴交替复位完成 (Y轴:{y_steps}步, Z轴:{z_steps}步)")
        return y_steps, z_steps 
    
    def reset_yz(self):
        """专门复位YZ两个轴，使用交替运动方式"""
        try:
            self.lock_motors()   
            print("开始YZ轴复位程序...")
            
            # 交替复位Y轴和Z轴 
            y_steps, z_steps = self._reset_yz_alternating()
            
            print(f"YZ轴复位完成！Y轴:{y_steps}步, Z轴:{z_steps}步")
            return True 
        
        except Exception as e:
            print(f"YZ轴复位过程中发生错误: {e}")
            self.unlock_motors()   
            return False
    
    def full_reset(self):
        """执行完整的机械臂复位流程"""
        try:
            self.lock_motors()   
            print("开始机械臂复位程序...")
            
            # 复位X轴 
            x_steps = self._reset_single_axis(
                self.axis_x_pin,  self.x_pin, 
                self.x_dir, self.limit_x,  "X"
            )
            
            # 交替复位Y轴和Z轴 
            y_steps, z_steps = self._reset_yz_alternating()
            
            print(f"机械臂复位完成！X轴:{x_steps}步, Y轴:{y_steps}步, Z轴:{z_steps}步")
            return True 
        
        except Exception as e:
            print(f"复位过程中发生错误: {e}")
            self.unlock_motors()   
            return False 
    
    def set_speed(self, speed_level):
        """设置运动速度 (1-5, 1最快)"""
        if 1 <= speed_level <= 5:
            self.time_value  = speed_level 
            print(f"速度已设置为: {speed_level}")
        else:
            print("速度设置无效，请输入1-5之间的值")
        return self 
    
    def set_yz_step_interval(self, steps):
        """设置YZ轴交替运动的步数"""
        self.yz_step_interval  = steps 
        print(f"YZ轴交替步数已设置为: {steps}步")
        return self 
 
# 创建全局实例，方便直接导入使用 
arm_reset = ArmReset()
 
if __name__ == '__main__':
    arm_reset.full_reset() 