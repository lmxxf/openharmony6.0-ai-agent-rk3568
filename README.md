# OpenHarmony 6.0 Settings + AI Agent (ARM64)

基于 OpenHarmony 6.0 源码树构建的系统设置应用，深度集成 AI 助手功能，支持**本地推理**（llama.cpp + Qwen3）和**云端推理**（DeepSeek API）双模式。

本项目是 **OpenHarmony 系统原生 Settings 应用** 的增强版。通过在系统设置中注入 AI 能力，实现灵活的端云协同智能体验。

> 详细移植过程与技术细节见 [开发日志.md](开发日志.md)

## ✨ 特性

- **双模式推理**：
  - 🏠 **本地模式**：llama.cpp + Qwen3-0.6B，离线可用，保护隐私
  - ☁️ **云端模式**：DeepSeek API，快速响应，流式输出
- **UI-Agent（Demo）**：在 Settings App 内一句话执行“蓝牙/亮度/日期时间”（不依赖无障碍、不跨应用）
- **通用 ARM64 适配**：支持所有 ARMv8-A 架构设备（RK3568、展锐 P7885 等），开启 NEON 指令集优化
- **系统级集成**：直接注入原生 Settings 列表，无需作为第三方应用安装，拥有更高的系统权限
- **异步推理**：使用 NAPI 异步工作线程（本地）或 HTTP 流式请求（云端），推理过程不阻塞 UI
- **多模型切换**：本地模式支持 Qwen2.5-0.5B 和 Qwen3-0.6B 一键切换

## 📊 性能参考

| 芯片 | CPU 架构 | 推理速度 (Qwen3-0.6B Q4) |
|------|---------|---------------------------|
| RK3568 | 4x A55 @2.0GHz | ~0.5 tokens/s |
| 展锐 P7885 | 4x A76 + 4x A55 | ~2-3 tokens/s |

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

# 下载模型（二选一）
# 方案A: Qwen2.5-0.5B (470MB) - 参数少，推理略快
wget https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf -O qwen2.5-0.5b-q4.gguf

# 方案B: Qwen3-0.6B (381MB) - 性能更强，约等于 Qwen2.5-1.5B
# 推荐从 ModelScope 下载（国内更快）: https://modelscope.cn/models/unsloth/Qwen3-0.6B-GGUF
wget https://modelscope.cn/models/unsloth/Qwen3-0.6B-GGUF/resolve/master/Qwen3-0.6B-IQ4_NL.gguf -O qwen3-0.6b-q4.gguf

# 推送模型到设备（两个都推送，应用内可切换）
hdc shell mkdir -p /data/app/el2/100/base/com.ohos.settings/files/
hdc file send qwen2.5-0.5b-q4.gguf /data/app/el2/100/base/com.ohos.settings/files/qwen2.5-0.5b-q4.gguf
hdc file send qwen3-0.6b-q4.gguf /data/app/el2/100/base/com.ohos.settings/files/qwen3-0.6b-q4.gguf
hdc shell chown 20010018:20010018 /data/app/el2/100/base/com.ohos.settings/files/*.gguf
```

**关于 OpenHarmony 沙箱路径的说明：**

你会发现代码里用的路径和 hdc 推送的路径不一样：
- 代码里用: `/data/storage/el2/base/files/qwen2.5-0.5b-q4.gguf`
- hdc 推送用: `/data/app/el2/100/base/com.ohos.settings/files/qwen2.5-0.5b-q4.gguf`

这是因为 OpenHarmony 使用**应用沙箱机制**，每个应用只能看到自己的虚拟文件系统：

| 路径组成 | 含义 |
|---------|------|
| `/data/storage/` | 应用看到的虚拟根路径 |
| `/data/app/` | 系统实际的物理路径 |
| `el1` | Encryption Level 1 - 设备级加密，开机即可访问 |
| `el2` | Encryption Level 2 - 用户级加密，解锁后才能访问 |
| `100` | 用户 ID，主用户固定为 100（多用户时会有 101、102...） |
| `base` | 应用基础数据目录（还有 database、cache 等） |
| `com.ohos.settings` | 应用包名 |
| `files` | 应用的文件存储目录 |

**权限说明：**
- `20010018` 是 Settings 应用的 UID（20010000 + 应用序号）
- 必须 `chown` 修改文件所有者，否则应用无法读取 root 创建的文件

**OpenHarmony vs Android 路径对比：**

| Android | OpenHarmony | 说明 |
|---------|-------------|------|
| `/data/data/包名/` | `/data/app/el2/100/base/包名/` | OH 多了 el2、100 层级 |
| `/data/user/0/包名/` | 同上 | Android 的 0 对应 OH 的 100 |
| DE (Device Encrypted) | el1 | 设备加密存储 |
| CE (Credential Encrypted) | el2 | 用户解锁后可访问 |
| UID 10000+ | UID 20010000+ | 应用 UID 基数不同 |
| `Context.getFilesDir()` | `/data/storage/el2/base/files/` | 虚拟路径映射 |

OpenHarmony 的沙箱设计基本照搬 Android，但路径更长、文档更少、调试更痛苦。

### 5. 配置云端 API（可选）

如果要使用云端 DeepSeek 模式，需要配置 API Key：

```bash
# 复制示例配置
cp product/phone/src/main/resources/rawfile/api_config.json.example \
   product/phone/src/main/resources/rawfile/api_config.json

# 编辑配置，填入你的 DeepSeek API Key
# {
#   "deepseek_api_key": "sk-your-api-key-here",
#   "deepseek_api_url": "https://api.deepseek.com/v1/chat/completions",
#   "deepseek_model": "deepseek-chat"
# }
```

> 注意：`api_config.json` 已被 `.gitignore` 忽略，不会提交到仓库

### 6. 使用 AI 助手

打开设置应用 → 点击"AI 助手"入口：
- **默认云端模式**：直接开始对话（需联网 + 已配置 API Key）
- **切换本地模式**：点击顶部"云端"按钮 → 选择"本地推理"（需已推送模型文件）

#### 6.1 UI-Agent（Demo）指令

在聊天输入框直接输入指令；命中关键词会**直接执行**并跳转到对应页面（未命中则正常聊天）：

- 蓝牙：`打开蓝牙` / `关闭蓝牙` / `切换蓝牙`（或 `蓝牙开关`）
- 亮度：`亮度 35%` / `亮度35` / `设置亮度 80`
- 日期时间：`切到24小时制` / `切到12小时制`

## 🔄 跨设备部署

编译产物 `phone-default-signed.hap` 是通用 ARM64 二进制，可直接安装到任何运行 OpenHarmony 6.0 的 ARM64 设备上：

```bash
# 连接新设备（如 P7885 开发板）
hdc list targets

# 安装 HAP（无需重新编译）
hdc -t <device_id> install product/phone/build/default/outputs/default/phone-default-signed.hap

# 推送模型文件
hdc -t <device_id> file send Qwen3-0.6B-IQ4_NL.gguf /data/app/el2/100/base/com.ohos.settings/files/qwen3-0.6b-q4.gguf
hdc -t <device_id> shell chown 20010018:20010018 /data/app/el2/100/base/com.ohos.settings/files/qwen3-0.6b-q4.gguf
```

**注意**：不同设备的推理速度取决于 CPU 性能，P7885 (A76 大核) 比 RK3568 (A55) 快约 4-6 倍。

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

---

## 🔨 从源码编译（完整流程）

如果需要修改 llama.cpp 或 NAPI 封装，按以下步骤从源码编译。

### 0. OpenHarmony 源码树路径约定

本项目假设你有完整的 OpenHarmony 6.0 源码树，以下是关键路径（相对于源码根目录）：

| 组件 | 相对路径 |
|------|----------|
| **OpenHarmony SDK** | `out/sdk/packages/ohos-sdk/linux/20/` 或 `prebuilts/ohos-sdk/linux/` |
| **Clang 工具链** | `prebuilts/clang/ohos/linux-x86_64/llvm/` |
| **Node.js 18** | `prebuilts/build-tools/common/nodejs/node-v18.20.1-linux-x64/` |
| **本项目位置** | `applications/standard/openharmony6.0-ai-agent-rk3568/` |

**编译前设置 Node.js（系统 Node 22+ 与 hvigor 不兼容）：**
```bash
export PATH=/path/to/oh6/source/prebuilts/build-tools/common/nodejs/node-v18.20.1-linux-x64/bin:$PATH
```

**创建 local.properties（指定 SDK 路径）：**
```bash
echo "sdk.dir=/path/to/oh6/source/out/sdk/packages/ohos-sdk/linux" > local.properties
```

### 1. 下载 llama.cpp 源码
```bash
git clone --depth 1 https://github.com/ggerganov/llama.cpp.git llama_cpp_src
```

### 2. 编译 llama.cpp (ARM64)
```bash
cd llama_cpp_src
# 使用项目提供的编译脚本（自动配置交叉编译）
# 或参考 ohos_arm64.cmake 手动配置 CMake
```

### 3. 编译 NAPI 封装

**方式一：使用脚本**
```bash
./build_napi_arm64.sh
```

**方式二：手动编译（需要 llama.cpp 头文件）**
```bash
SDK_BASE="/path/to/oh6/source/prebuilts/ohos-sdk/linux"
OHOS_SDK_ROOT="$SDK_BASE/20"
OHOS_CLANG_ROOT="/path/to/oh6/source/prebuilts/clang/ohos/linux-x86_64/llvm"
SYSROOT="$OHOS_SDK_ROOT/native/sysroot"
TARGET="aarch64-linux-ohos"
LIBS_DIR="product/phone/libs/arm64-v8a"

"$OHOS_CLANG_ROOT/bin/clang++" \
    --target=$TARGET --sysroot="$SYSROOT" -fPIC -shared -std=c++17 -O2 \
    -I"llama_cpp_src/include" -I"llama_cpp_src/ggml/include" \
    -I"$SYSROOT/usr/include" -I"$SYSROOT/usr/include/napi" \
    -L"$LIBS_DIR" -L"$SYSROOT/usr/lib/$TARGET" \
    -lllama -lggml -lggml-base -lggml-cpu -lace_napi.z -lhilog_ndk.z \
    -Wl,-rpath,'$ORIGIN' -o "$LIBS_DIR/libllama_napi.so" \
    product/phone/src/main/cpp/llama_napi.cpp
```

该脚本会自动完成：
1. 复制 llama.cpp 编译产物到 `libs/arm64-v8a/`
2. 用 patchelf 修复 SONAME、NEEDED、RUNPATH（去除 `.so.0` 版本号）
3. 编译 `libllama_napi.so`

**patchelf 修复原理**（供参考）：

| 修改项 | 说明 | 举例 |
|--------|------|------|
| SONAME | .so 内部记录的"我叫什么" | `libllama.so.0` → `libllama.so` |
| NEEDED | .so 内部记录的"我依赖谁" | 依赖 `libggml.so.0` → 依赖 `libggml.so` |
| RUNPATH | .so 内部记录的"去哪找依赖" | 编译机路径 → `$ORIGIN`（同目录） |

### 4. 编译 HAP
```bash
rm -rf product/phone/build .hvigor  # 清缓存
./hvigorw assembleHap
```

---

## 📁 目录结构
```
settings/
├── llama_cpp/                    # llama.cpp 源码和编译配置
│   └── build_arm64/              # ARM64 编译产物
├── product/phone/
│   ├── src/main/cpp/             # NAPI 封装（本地推理）
│   │   ├── llama_napi.cpp        # NAPI 实现
│   │   └── types/libllama_napi/  # 类型声明
│   ├── src/main/ets/
│   │   ├── pages/
│   │   │   ├── settingList.ets   # 主列表（含 AI 入口）
│   │   │   └── aiAssistant.ets   # AI 聊天页面（本地+云端双模式）
│   │   └── res/image/
│   │       └── ic_ai.svg         # AI 助手图标
│   ├── src/main/resources/rawfile/
│   │   ├── api_config.json       # DeepSeek API 配置（gitignore）
│   │   └── api_config.json.example  # 配置示例
│   └── libs/arm64-v8a/           # 预编译的 .so 库
├── build_napi_arm64.sh           # NAPI 编译脚本
├── build_all_ai_arm64.sh         # 一键编译脚本
├── 开发日志.md                    # 详细开发记录
└── README.md                      # 本文件
```

---

## 🧪 测试环境

| 系统 | 设备 | 状态 |
|------|------|------|
| OpenHarmony 6.0 | RK3568 (ARM64) | ✅ 已验证 |
| OpenHarmony 6.0 | 展锐 P7885 (ARM64) | ✅ 已验证 |

---

## 📝 关于 NPU

当前实现仅使用 CPU（NEON 指令集）。

**为什么不用 NPU？**

| 芯片 | NPU 算力 | 能跑 LLM 吗 | 原因 |
|------|---------|------------|------|
| P7885 | 8 TOPS | ❌ 不能 | 算子库偏 CNN（卷积、池化），缺少 Transformer 核心算子（GeMM、RoPE、KV Cache、Paged Attention） |
| RK3568 | 1 TOPS | ❌ 不能 | RKNN-Toolkit 同样只支持传统神经网络 |

**展锐 P7885 NPU 详情**（来自 Kallen 调研）：
- 6nm 工艺，8 TOPS，支持 INT8/INT4/FP16
- 典型场景：人脸识别、图像超分、目标检测、视频增强 —— 都是 CNN 类任务
- **无公开算子列表**，SDK 只给 NDA 合作伙伴
- 即使有 SDK，动态序列的 LLM 推理会因内存带宽限制直接卡死

**端侧 LLM 加速门槛**：至少 40+ TOPS 且支持 Transformer 算子（如高通 Hexagon、Snapdragon X Elite 45 TOPS）。8 TOPS 的 CNN NPU 跑 LLM 就像拿计算器跑 Stable Diffusion。

## License
Apache License 2.0
