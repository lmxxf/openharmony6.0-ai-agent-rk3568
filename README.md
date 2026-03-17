# OpenHarmony 6.0 Settings + AI Agent (ARM64)

基于 OpenHarmony 6.0 源码树构建的系统设置应用，深度集成 AI 助手功能，支持**本地推理**（llama.cpp + Qwen3）和**云端推理**（DeepSeek API）双模式。

本项目是 **OpenHarmony 系统原生 Settings 应用** 的增强版。通过在系统设置中注入 AI 能力，实现灵活的端云协同智能体验。

> 详细移植过程与技术细节见 [开发日志.md](开发日志.md)

## ✨ 特性

- **双模式推理**：
  - 🏠 **本地模式**：llama.cpp + Qwen3-0.6B，离线可用，保护隐私
  - ☁️ **云端模式**：DeepSeek API，快速响应，流式输出
- **MCP Tool Calling**：通过 DeepSeek Function Calling 实现设备控制 Agent，LLM 自主决定调用工具（[详见 MCP 实现文档](mcp-impl.md)）
- **RAG 知识检索**：端侧轻量级 RAG，本地知识库随 HAP 打包，关键词检索注入 system prompt（[详见 RAG 实现文档](rag-impl.md)）
- **🐍 Python Runner**：App 内嵌 Python 3.11 运行时，通过 NAPI fork+execve 在系统 App 沙箱内执行 Python 脚本（[详见下方](#-python-runner)）
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

#### 6.1 MCP 工具调用示例

云端模式下，LLM 自主决定是否调用工具（无需精确关键词，自然语言即可）：

- 蓝牙控制：`帮我打开蓝牙` / `关一下蓝牙` / `bluetooth on`
- 亮度调节：`把亮度调到50%` / `屏幕太暗了调亮一点`
- 时间格式：`切到24小时制` / `我想用12小时的时间格式`
- 设备状态：`蓝牙开着没？` / `现在亮度多少？`
- 多步操作：`打开蓝牙并把亮度调到80%`

> 技术细节见 [MCP 实现文档](mcp-impl.md)

#### 6.2 RAG 知识问答示例

当问题涉及设备使用、OpenHarmony 特性等知识时，会自动检索本地知识库：

- `OpenHarmony 6.0 有什么新特性？`
- `蓝牙连不上怎么办？`
- `ArkTS 和 TypeScript 有什么区别？`

> 技术细节见 [RAG 实现文档](rag-impl.md)

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

## 🔎 调研：豆包手机助手（GUI Agent）& 经验启示

公开信息里，“豆包手机助手”被描述为 **系统级 GUI Agent / 跨应用自动化** 的路线：通过识别界面并模拟用户操作来完成跨 App 任务（不要求每个 App 都提供可调用 API）。同时也因为“代操作”会触发第三方 App 风控、权限边界争议等问题，部分场景能力会被限制或下线。

参考阅读（公开报道/分析）：
- 每日经济新闻：系统级 Agent 权限、模拟用户操作、触发风控后的能力调整（含 `INJECT_EVENTS` 等讨论）  
  https://www.mrjjxw.com/articles/2025-12-11/4177585.html
- 21世纪经济报道：AI 手机围绕数据与权限边界的讨论  
  https://m.21jingji.com/article/20260101/8ad8af3c5e25b5e78d5f59044b496940.html
- 36氪：GUI Agent 对“流量入口/商业模式”的冲击与生态博弈  
  https://www.36kr.com/p/3596837650595843
- 新浪科技/量子位整理：UI-TARS/系统级 GUI Agent 的技术路线讨论  
  https://finance.sina.com.cn/tech/csj/2025-12-09/doc-inhaeunf1479107.shtml

**对 OpenHarmony 侧实现的启示：**
- 能用“系统能力/应用能力调用”就不要走“点 UI”，更稳、更可控、也更容易过风控。
- 必须跨 App“像人一样点屏幕”时，再考虑无障碍/自动化测试类方案，并做好权限、合规与目标 App 风控的预期管理。

## 🧩 OpenHarmony 6.0 上的可用方案（跨应用）

> 下面是“想操作其它 App”的常见实现路径对比。推荐优先级：能力调用/Picker > 无障碍 > UI 自动化测试框架。

1) **能力调用（Want/DeepLink/Service）**（推荐）
- 场景：打开通讯录、选联系人、拉起某个业务页面、调用目标 App 暴露的能力。
- 特点：稳定、可控、对 UI 变化不敏感；通常不需要“读取屏幕+模拟点击”。

2) **系统 Picker（如联系人选择）**（推荐）
- 场景：你举例的“打开通讯录然后选一个人”，更稳的做法是直接调用“联系人选择器”，拿回联系人结果（id/uri/电话等）。
- 特点：系统级交互，体验像“打开通讯录选人”，但底层不是 UI 自动化。

3) **无障碍（Accessibility）服务**
- 场景：必须跨 App 点击/输入/读取控件树（GUI Agent 典型路线）。
- 特点：更通用，但依赖系统配置与用户启用；目标 App 可能风控/限制；不同产品化 ROM 差异大。

4) **UI 自动化测试框架 `@ohos.UiTest`**
- 场景：偏测试/验收（自动找控件、点击、滑动、输入），不建议直接作为“线上 agent”能力。
- 参考：UiTest 相关资料可见社区文章（示例）：https://blog.csdn.net/adaedwa187545/article/details/143435698

## 🔧 常见问题

### Q: 云端模式报错 `2300060 "SSL peer certificate or SSH remote key was not OK"`
**A:** RK3568 等开发板出厂的 CA 根证书包（`/etc/ssl/certs/cacert.pem`）只有约 111 个证书，缺少 DigiCert/GeoTrust 等常用 CA，导致 HTTPS 请求 SSL 验证失败。

**背景**：DeepSeek 近期更换了 SSL 证书（签发日期 2025-06-06，CA 链为 GeoTrust TLS RSA CA G1 → DigiCert）。此前的旧证书 CA 恰好在 OH6 出厂证书包内，所以之前能用；换证书后新 CA 不在包里，RK3568 和 P7885 设备同时出现此问题。

`build.sh` 会在安装 HAP 后自动推送完整的 Mozilla CA 证书包到设备。如果你手动安装，需要额外执行：
```bash
hdc shell 'mount -o remount,rw /'
hdc file send product/phone/src/main/resources/rawfile/cacert.pem /etc/ssl/certs/cacert.pem
```

> **注意**：设备恢复出厂设置或刷机后需要重新推送。`build.sh` 每次部署都会自动执行此步骤。

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
│   ├── src/main/cpp/             # NAPI 封装
│   │   ├── llama_napi.cpp        # 本地推理 NAPI
│   │   ├── exec_napi.cpp         # Python Runner NAPI（fork+execve）
│   │   └── types/libllama_napi/  # 类型声明
│   ├── src/main/ets/
│   │   ├── pages/
│   │   │   ├── settingList.ets   # 主列表（含 AI + Python Runner 入口）
│   │   │   ├── aiAssistant.ets   # AI 聊天页面（本地+云端双模式）
│   │   │   └── pythonRunner.ets  # Python Runner 页面
│   │   └── res/image/
│   │       └── ic_ai.svg         # AI 助手图标
│   ├── src/main/resources/rawfile/
│   │   ├── api_config.json       # DeepSeek API 配置（gitignore）
│   │   ├── api_config.json.example  # 配置示例
│   │   ├── cacert.pem            # Mozilla CA 根证书包（修复 SSL）
│   │   ├── python-runtime.tar.gz # Python 3.11 运行时（26MB，自动解压）
│   │   └── knowledge/            # [RAG] 知识库文件
│   │       ├── kb_index.json     # 文档元数据索引
│   │       ├── device_manual.txt # 设备使用手册
│   │       ├── oh6_features.txt  # OpenHarmony 6.0 特性
│   │       └── settings_faq.txt  # 常见问题 Q&A
│   └── libs/arm64-v8a/           # 预编译的 .so 库
├── build_napi_arm64.sh           # llama NAPI 编译脚本
├── build_exec_napi.sh            # Python Runner NAPI 编译脚本
├── build_all_ai_arm64.sh         # 一键编译脚本
├── 开发日志.md                    # 详细开发记录
└── README.md                      # 本文件
```

---

## 🐍 Python Runner

> **分支：`langchain-python-test`**

在系统设置 App 内嵌 Python 3.11 运行时，无需修改系统镜像。Python 运行时（26MB）打包在 HAP 的 rawfile 中，首次使用时自动解压到 App 沙箱。

### 原理

```
ArkTS UI (pythonRunner.ets)
    │ import 'libexec_napi.so'
    ↓
C++ NAPI (exec_napi.cpp) ── fork() → execve("/bin/sh", "-c", cmd)
    │                                    │
    │ pipe read stdout+stderr            ↓
    │                        LD_LIBRARY_PATH=.../python/lib
    ↓                        PYTHONHOME=.../python
UI 显示结果                  python3.11 -c "print(...)"
```

### 为什么用 NAPI fork+execve 而不是 ArkTS API

- `process.runCmd()` 在 SDK 20 中被删除（OH 安全收紧）
- `popen()` 在 App 进程中 PATH 为空，外部命令全返回 127
- `fork + execve("/bin/sh")` 可以在子进程中设置 PATH 和环境变量

### 为什么必须是系统 App

普通 App 有独立的 mount namespace，连 `/data/local/tmp/` 都看不到（返回 "No such file or directory"）。系统 App（`com.ohos.settings`）权限更高，可以在沙箱 filesDir 内执行二进制文件。

### 使用方式

1. 切换到 `langchain-python-test` 分支
2. 编译 NAPI 和 HAP：
```bash
./build_exec_napi.sh    # 编译 libexec_napi.so（20KB）
./build.sh              # 编译 HAP（含 26MB Python 运行时）
```
3. 安装 HAP 到设备
4. 打开设置 → **Python Runner**
5. 点 **Install Python (23MB)** → 等待解压完成
6. 点 **Run Python** → 显示 Python 3.11.11 输出

### 相关文件

| 文件 | 说明 |
|------|------|
| `product/phone/src/main/cpp/exec_napi.cpp` | NAPI 模块：`runCommand(cmd)` fork+execve 执行命令 |
| `product/phone/src/main/ets/pages/pythonRunner.ets` | UI 页面 + rawfile 解压逻辑 |
| `product/phone/src/main/resources/rawfile/python-runtime.tar.gz` | Python 3.11.11 运行时（bin + lib + stdlib + LangChain 依赖链） |
| `build_exec_napi.sh` | 交叉编译 libexec_napi.so |

### Python 运行时内容

tar.gz 解压后的目录结构（部署到 App 沙箱 filesDir）：

```
python/
├── bin/python3.11              # CPython 解释器（动态链接）
├── lib/
│   ├── libpython3.11.so.1.0    # Python 主库
│   ├── libcrypto.so.3          # OpenSSL
│   ├── libssl.so.3             # OpenSSL
│   └── python3.11/             # 标准库 + site-packages
│       ├── encodings/
│       ├── json/
│       ├── ssl.py
│       ├── lib-dynload/        # 64 个 C 扩展模块 (.so)
│       ├── site-packages/      # LangChain 全依赖链
│       │   ├── pydantic_core/  # Rust .so
│       │   ├── langchain_core/
│       │   ├── openai/
│       │   ├── jiter/          # Rust .so
│       │   ├── uuid_utils/     # Rust .so
│       │   ├── xxhash/         # C .so
│       │   ├── certifi/        # 含 cacert.pem（SSL 证书）
│       │   └── ...（30+ 个包）
│       └── ...
└── .installed                  # marker 文件，表示已解压
```

Python 运行时由 [langchain-on-openharmony](https://github.com/lmxxf/langchain-on-openharmony) 项目交叉编译，使用 OH 的 Clang 15 + musl sysroot，详见该项目的 DevHistory.md。

### LangChain + DeepSeek API 验证

Python Runner 页面有 **Run LangChain + DeepSeek** 按钮（紫色），点击后在 App 沙箱内执行：

```
Python 3.11 → langchain_core → openai SDK → HTTPS/TLS → DeepSeek API → AIMessage
```

验证结果（P7885）：
```
Python 3.11.11
langchain_core: OK
openai SDK: OK
Response: Hello from OpenHarmony, the open-source operating system
          shaping the future of smart devices!
Type: AIMessage
=== LangChain + DeepSeek on OpenHarmony: SUCCESS ===
```

**注意**：刷机后板子时间会重置到 2008 年，SSL 证书验证会报 `certificate is not yet valid`。需要先校时：`hdc shell 'date MMDDHHmmYYYY.SS'`

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
