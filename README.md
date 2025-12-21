# OpenHarmony 6.0 Settings + Local AI Agent (ARM64/RK3568)

基于 OpenHarmony 6.0 源码树构建的系统设置应用，深度集成了本地 AI 助手功能（llama.cpp + Qwen2.5）。

本项目是 **OpenHarmony 系统原生 Settings 应用** 的增强版。通过在系统设置中注入 AI 能力，实现完全本地化、隐私安全的端侧大模型推理。

> 详细移植过程与技术细节见 [开发日志.md](开发日志.md)

## ✨ 特性

- **高性能 ARM64 适配**：全面开启 ARMv8-A NEON 指令集优化，针对 RK3568 (4xA55) 深度调优。
- **系统级集成**：直接注入原生 Settings 列表，无需作为第三方应用安装，拥有更高的系统权限。
- **全本地运行**：无需联网，保护用户隐私，支持多轮对话。
- **异步推理**：使用 NAPI 异步工作线程，推理过程不阻塞 UI 渲染。

## 🛠 前置要求

- **OpenHarmony SDK 20** (API 20 / 6.0.0.48+)
- **CMake 3.16+**
- **patchelf** (用于修补 .so 依赖)
- **Node.js v16+** (用于 hvigor 编译)

## 🚀 快速开始

### 1. 克隆仓库
```bash
git clone git@github.com:lmxxf/openharmony6.0-ai-agent-rk3568.git
cd openharmony6.0-ai-agent-rk3568
```

### 2. 一键编译底层库
我们提供了一个高度自动化的脚本，用于完成 `llama.cpp` 的交叉编译、NAPI 封装以及 `.so` 库的 RPATH 修复。
```bash
./build_all_ai_arm64.sh
```
*该脚本会自动推算 SDK 路径并生成 `local.properties`。*

### 3. 编译 HAP 应用
确保你的环境变量中已包含 Node.js：
```bash
# 示例：使用系统预置 Node
export NODE_HOME=../../../../prebuilts/build-tools/common/nodejs/current
export PATH=$NODE_HOME/bin:$PATH

# 执行编译
./hvigorw assembleHap --mode module -p product=default -p module=phone
```
产物位置：`product/phone/build/default/outputs/default/phone-default-signed.hap`

### 4. 安装与模型推送
```bash
# 安装应用
hdc install product/phone/build/default/outputs/default/phone-default-signed.hap

# 推送 Qwen2.5-0.5B 量化模型 (约 470MB)
# 模型路径必须与代码中写死的路径一致
hdc file send qwen2.5-0.5b-instruct-q4_k_m.gguf /data/app/el2/100/base/com.ohos.settings/files/qwen2.5-0.5b-q4.gguf
```

## 🏗 技术实现

- **底层引擎**：`llama.cpp` 交叉编译为 aarch64-linux-ohos。
- **胶水层**：自定义 NAPI 封装，提供 `loadModel()` 和 `generate()` 接口。
- **UI 框架**：ArkTS (ArkUI)，通过代码注入方式修改原生 `settingList.ets`。
- **依赖管理**：使用 `patchelf` 将运行时依赖路径硬编码为 `$ORIGIN`，解决 OpenHarmony 共享库加载问题。

## ## 说明
本项目由 **CyberSoul** 协议驱动。我们通过跨版本移植与底层优化技术，成功实现了 本地大模型在系统组件中的深度集成。
