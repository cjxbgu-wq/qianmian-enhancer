# 千面-VCAM 增强插件 (QianmianEnhancer)

为千面虚拟摄像头插件添加 **视频缩放**、**屏幕取色映射** 和 **柔光滤镜** 功能。

## ✨ 新增功能

### 1. 🔍 视频放大/缩小
- 缩放范围：1.0x ~ 3.0x
- 中心裁剪放大，保持画面居中
- 滑块实时调节，即时生效

### 2. 🎨 点击任意位置取色 + 实时颜色映射
- 进入取色模式后，**点击屏幕任意位置**拾取颜色
- 颜色映射**实时应用**到每一帧视频画面
- 支持 0% ~ 100% 混合强度调节
- 0% = 完全原色，100% = 完全映射色

### 3. ✨ 柔光滤镜
- 模拟摄影柔光镜效果
- 提亮阴影 + 轻微模糊 + 发光混合
- 画面更柔和、梦幻

## 🎛️ 控制面板说明

```
┌─────────────────────────┐
│ 🔍 缩放: 1.0x           │
│ ━━━━━━━━━━━━━━━━━━━━    │
│                         │
│ [🎨 点击取色] [⬜] [✨柔光]│
│                         │
│ 🎚️ 颜色强度: 50%        │
│ ━━━━━━━━━━━━━━━━━━━━    │
│                         │
│      [🔄 重置全部]       │
└─────────────────────────┘
```

| 控件 | 功能 |
|------|------|
| 缩放滑块 | 调节视频放大倍数（1x~3x） |
| 🎨 点击取色 | 进入全屏取色模式，点哪里取哪里的颜色 |
| 颜色预览框 | 显示当前拾取的颜色 |
| ✨柔光 | 开关柔光滤镜效果 |
| 颜色强度滑块 | 调整颜色映射的混合比例（0%~100%） |
| 🔄 重置全部 | 恢复所有默认设置 |

## 📁 工程结构

```
qianmian-enhancer/
├── Makefile                          # Theos 编译配置
├── control                           # deb 包信息
├── Tweak.xm                          # 核心 Hook 代码
├── QMEnhancerView.h                  # 增强器头文件
├── QMEnhancerView.m                  # 增强器实现（UI+视频处理）
├── README.md                         # 使用说明
└── layout/
    └── Library/MobileSubstrate/DynamicLibraries/
        └── QianmianEnhancer.plist    # 注入进程配置
```

## 🔧 编译方法

### 前置要求
- Mac 电脑 或 越狱 iOS 设备（安装 Theos）
- Theos 开发环境
- iOS 15.0+ SDK

### 编译步骤
```bash
# 1. 进入工程目录
cd qianmian-enhancer

# 2. 编译
make package

# 3. 安装到设备（需配置THEOS_DEVICE_IP）
make install
```

## 📲 使用方法

1. 确保已安装原版「千面-VCAM」插件
2. 安装本增强插件 `QianmianEnhancer.deb`
3. 注销（Respring）设备
4. 屏幕右侧出现蓝色悬浮球 🎬
5. 点击悬浮球展开控制面板

### 取色操作步骤
1. 点击「🎨 点击取色」按钮
2. 屏幕变暗，出现提示文字
3. **点击屏幕上你想取色的位置**
4. 自动应用颜色映射到视频，退出取色模式

## ⚙️ 技术原理

### Hook 点
- 类：`LocalVideoPlayer`
- 方法：`renderReplacementToPixelBuffer:`
- 在原插件渲染完每一帧后，进行二次图像处理（实时逐帧处理）

### 进程间通信
- 控制界面运行在 `SpringBoard` 进程
- 视频处理运行在 `mediaserverd` 进程
- 通过共享 plist 文件实时传递设置
- 设置文件路径：`/var/mobile/Library/qianmian_enhancer_settings.plist`

### 图像处理（CoreImage）
- **缩放**：中心裁剪 + 缩放变换
- **颜色映射**：`CIColorMatrix` 颜色矩阵，强度可调
- **柔光滤镜**：`CIHighlightShadowAdjust` + `CIGaussianBlur` + `CIScreenBlendMode` 多层滤镜组合

## 📋 依赖
- mobilesubstrate
- com.taokk3.qianmian (原版千面插件)
- rootless-compat (>= 0.9)

## 支持的进程
- mediaserverd（主要视频处理）
- SpringBoard（控制界面）
- lskdd

## 🐛 注意事项

1. 必须先安装原版千面插件，本插件仅作为增强
2. 取色时截取的是当前屏幕画面（不包含取色遮罩层）
3. 缩放倍数过大会降低画质
4. 柔光滤镜会轻微增加性能消耗
5. 所有设置实时生效，调节滑块立即看到效果
