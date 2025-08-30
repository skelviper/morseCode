Morse 电键读取器（PowerShell）
===============================

[English](README.md) | [简体中文](README.zh-CN.md)

简介
- 使用 Windows PowerShell + 内嵌 C#（WinMM waveIn）从电脑麦克风/线路输入读取电键信号。
- 控制台实时显示滚动历史（类似 btop 的条形波形），并进行摩尔斯电码解码。
- 也支持键盘空格键作为电键输入（无需任何音频硬件）。

功能
- 实时电平条（快速衰减，可调灵敏度）
- 滚动式 ASCII 波形/柱状图（btop 风格）
- 基于“边沿”的电键状态检测（适配 AC 耦合麦克风）
- 实时摩尔斯解码（按 WPM 计时，字间/词间间隔识别）
- 设备枚举与选择（WinMM，无外部依赖）

快速开始
- 本次会话允许运行脚本：
  `Set-ExecutionPolicy -Scope Process Bypass -Force`
- 列出输入设备：
  `./listen-key.ps1 -ListDevices`
- 默认设备 + 滚动波形 + 解码：
  `./listen-key.ps1 -Scope -KeyIndicator`
- 指定设备（示例：0）：
  `./listen-key.ps1 -DeviceId 0 -Scope -KeyIndicator`
- 仅用键盘空格键作为电键：
  `./listen-key.ps1 -UseSpacebar -Scope -KeyIndicator`

常用参数
- `-Scope`：开启滚动历史视图
- `-ScopeHeight <int>`：示波高度（默认 16）
- `-ScopeGain <0..1>`：示波放大（默认 0.5，只影响显示）
- `-ScopeStyle bars|wave`：柱状或点线（默认 bars）
- `-PeakHalfLifeMs <int>`：电平条衰减半衰期（默认 80ms）
- `-KeyIndicator`：显示电键状态（UP/DOWN）
- `-UseSpacebar`：使用空格键作为输入，绕过音频采集
- `-Wpm <int>`：速度（默认 20；点长 = 1200/Wpm 毫秒）
- 边沿检测（仅音频模式）：
  - `-EdgeThresholdPct <int>`：脉冲阈值（默认 12）
  - `-RefractoryMs <int>`：最小翻转间隔（默认 40ms）

硬件与信号说明
- 电脑麦克风口通常是 AC 耦合：电键闭合/断开是直流阶跃，只在变化瞬间产生脉冲。脚本通过“高通 + 去抖 + 翻转逻辑”稳定得到电键状态。
- 若仅想体验解码或没有合适的接线，可用 `-UseSpacebar` 直接用空格键操作。
- 没反应时请检查：选择了正确设备、系统麦克风权限、录音电平/增益。

故障排查
- 电平条不动：用 `-ListDevices` 选中模拟麦克风输入，提升系统录音电平/麦克风增益，并轻敲麦克风/插头测试。
- 画面重复/换行：脚本会根据窗口大小重绘并裁剪状态行，建议在 Windows Terminal 或经典控制台中运行。
- 误触发或丢边沿（音频模式）：调高/降低 `-EdgeThresholdPct`，或增大 `-RefractoryMs`。

开发说明
- 通过 `Add-Type` 编译内嵌 C#（WinMM waveIn）。
- 为避免类型缓存，类名使用 `WaveInCaptureV4`。

许可
- MIT（如需请补充 LICENSE 文件）。

