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
- **依赖管理**：
  - 使用 `patchelf --set-rpath '$ORIGIN'` 将运行时依赖路径硬编码为同级目录
  - 使用 `patchelf --replace-needed` 清除 `.so.0` 版本号后缀依赖（llama.cpp 编译产物默认带版本号）
- **NAPI 模块规范**：
  - `oh-package.json5` 的 `name` 字段必须与 ArkTS 的 `import` 名一致
  - OpenHarmony 标准命名：`"libxxx.so"`

## 🔧 常见问题

### Q: 运行时提示 "模块导入失败"
**A:** 检查 hilog 日志：
```bash
hdc shell hilog | grep -iE 'llama|napi|dlopen|error'
```
常见原因：
1. `.so` 文件 NEEDED 依赖带版本号（如 `libggml-cpu.so.0`），需用 patchelf 修复
2. NAPI 模块 `nm_modname` 与 `oh-package.json5` 的 `name` 不匹配

### Q: 编译报错 "Cannot find module 'llama_napi'"
**A:** 检查以下配置是否一致：
- `product/phone/oh-package.json5` 的 `dependencies` 名称
- `src/main/cpp/types/libllama_napi/oh-package.json5` 的 `name` 字段
- `aiAssistant.ets` 的 `import from "xxx"` 语句

## 📝 说明
本项目由 **CyberSoul** 协议驱动。我们通过跨版本移植与底层优化技术，成功实现了本地大模型在系统组件中的深度集成。
