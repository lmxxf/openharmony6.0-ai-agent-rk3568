# MCP Function Calling 技术实现文档

## 1. 概述

MCP（Model Context Protocol）是一种让大语言模型调用外部工具的标准协议。本项目在 OpenHarmony 6.0 Settings 应用中，基于 DeepSeek Function Calling（OpenAI 兼容格式）实现了一个设备控制 Agent，使用户可以通过自然语言操控设备设置。

## 2. 架构

```
用户输入 → DeepSeek API（附带工具 Schema + RAG 上下文）
                ↓
          LLM 返回 tool_calls？
            /        \
          yes         no
           ↓           ↓
     执行工具       流式输出文本
           ↓
     结果回传 DeepSeek
           ↓
     生成自然语言总结
```

整体为**单轮工具调用循环**：首次请求携带工具定义，LLM 自主判断是否需要调用工具。若返回 `tool_calls`，客户端执行后将结果回传，LLM 再生成面向用户的自然语言总结。

## 3. 工具注册表

5 个工具以 JSON Schema 声明式定义，运行时 `JSON.parse` 加载：

| 工具名 | 功能 | 关键参数 |
|--------|------|----------|
| `set_bluetooth` | 控制蓝牙开/关/切换 | `action`: enable / disable / toggle |
| `set_brightness` | 设置屏幕亮度 | `percent`: 0-100 |
| `set_time_format` | 切换时间格式 | `format`: 12h / 24h |
| `navigate_to_page` | 导航到设置子页面 | `page`: bluetooth / brightness / dateAndTime / wifi / aboutDevice |
| `query_device_status` | 查询设备状态 | `query_type`: bluetooth / brightness / all |

**扩展方式**：新增一个工具 = 在 `MCP_TOOLS_JSON` 中加一条 JSON 定义 + 在 `executeMcpTool()` 中加一个分支。

## 4. 技术实现细节

### SSE 流式解析增强

DeepSeek 返回 `tool_calls` 时，SSE delta 中不是 `content` 字段，而是 `tool_calls` 数组。关键处理：

- **分片累积**：`arguments` 的 JSON 字符串可能跨多个 chunk 传输，使用 `toolCallArgBuffers` (Map) 按 index 累积拼接
- **多工具并行**：`pendingToolCalls` 数组按 `index` 定位，支持 LLM 同时返回多个 tool_calls

### 工具执行循环

```
检测到 tool_calls → 解析参数 JSON → executeMcpTool() 执行
    → 构造 assistant(tool_calls) + tool(result) 消息
    → 再次请求 DeepSeek（不带 tools）→ 流式输出自然语言总结
```

第二次请求刻意不传 `tools` 字段，确保 LLM 直接生成文本回复而非再次调用工具。

### ArkTS 适配

ArkTS 禁止匿名 object literal（`arkts-no-untyped-obj-literals`），工具定义无法直接写成嵌套对象。解决方案：将完整的工具 JSON 定义为字符串常量 `MCP_TOOLS_JSON`，运行时 `JSON.parse` 绕过编译期限制。

### 底层 API 调用

| 工具 | 调用的 OH 接口 |
|------|---------------|
| 蓝牙控制 | `bluetoothModel`（OH 蓝牙框架封装） |
| 亮度控制 | `BrightnessSettingModel`（DataShare 亮度接口） |
| 时间格式 | `dateAndTimeModel`（i18n 时间格式接口） |
| 页面导航 | `Router.push()`（系统路由） |

## 5. 与旧方案对比

| 维度 | 旧方案（硬编码匹配） | 新方案（MCP Function Calling） |
|------|---------------------|-------------------------------|
| 意图识别 | 正则/关键词 if-else | LLM 自主判断 |
| 变体容忍 | 差（"打开蓝牙"行，"帮我开一下蓝牙呗"不行） | 强（自然语言理解） |
| 扩展性 | 改代码加 if 分支 | 加一条 JSON Schema |
| 多步推理 | 不支持 | 支持（LLM 可返回多个 tool_calls） |
| 错误恢复 | 硬编码兜底 | LLM 根据工具返回结果自适应回复 |

## 6. 关键代码路径

文件：`product/phone/src/main/ets/pages/aiAssistant.ets`

```
sendMessage()
  → sendToDeepSeekWithTools()     // 构造消息 + RAG 上下文注入
    → streamDeepSeekRequest()     // 发起 SSE 流式请求，携带 tools
      → handleDeepSeekSseEvent()  // 解析 SSE delta，累积 tool_calls 或文本
      → [stream end]
        → handleToolCallsAndFollowUp()  // 执行工具，回传结果，二次请求
          → executeMcpTool()             // 分发到具体设备 API
          → streamDeepSeekRequest()      // 二次请求生成自然语言总结
```

## 7. MCP vs 普通 API：到底有什么区别？

**API**：程序员写代码告诉程序"调这个接口"——你是大脑，代码是手。

**MCP**：把工具说明书给 LLM，LLM 自己决定调不调、调哪个、传什么参数——LLM 是大脑，你只提供手。

MCP 不是一种新的通信协议，它是一个**"给 AI 装工具箱"的标准格式**。底下走的还是 HTTP API，只是请求里多了个 `tools` 字段描述工具，响应里多了个 `tool_calls` 字段返回 LLM 的调用决策。

### 真实请求/响应示例

**第一轮请求（你 → DeepSeek）：**

```json
{
  "messages": [
    {"role": "system", "content": "你是一个运行在OpenHarmony设备上的AI助手。"},
    {"role": "user", "content": "打开蓝牙"}
  ],
  "tools": [{
    "type": "function",
    "function": {
      "name": "set_bluetooth",
      "description": "控制蓝牙开关。",
      "parameters": {
        "type": "object",
        "properties": {
          "action": {"type": "string", "enum": ["enable","disable","toggle"]}
        },
        "required": ["action"]
      }
    }
  }],
  "tool_choice": "auto"
}
```

**第一轮响应（DeepSeek → 你）：**

```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "content": "我来帮您打开蓝牙。",
      "tool_calls": [{
        "id": "call_00_4QiBrVsTfBko56p4wHOWy2uN",
        "type": "function",
        "function": {
          "name": "set_bluetooth",
          "arguments": "{\"action\": \"enable\"}"
        }
      }]
    },
    "finish_reason": "tool_calls"
  }]
}
```

注意 `finish_reason` 是 `"tool_calls"` 而非 `"stop"`——意思是"我没说完，先去执行工具"。

**第二轮请求（执行工具后 → DeepSeek）：**

```json
{
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "打开蓝牙"},
    {"role": "assistant", "content": null, "tool_calls": [...]},
    {"role": "tool", "tool_call_id": "call_00_4QiBrVsT...", "content": "蓝牙已开启"}
  ]
}
```

**第二轮响应**：DeepSeek 生成最终自然语言回复，如"蓝牙已成功开启，您现在可以连接蓝牙设备了。"

### 真正打开蓝牙的是谁？

**是设备本地代码，不是 DeepSeek。** DeepSeek 只是个"决策者"，真正的执行链：

```
DeepSeek 返回 tool_calls: [{name: "set_bluetooth", arguments: '{"action":"enable"}'}]
    ↓
aiAssistant.ets → handleToolCallsAndFollowUp() 解析
    ↓
executeMcpTool("set_bluetooth", '{"action":"enable"}')
    ↓
bluetoothModel.enableBluetooth()    ← OH 系统蓝牙框架 API
    ↓
OpenHarmony 蓝牙子系统操作射频硬件
```

`bluetoothModel` 是 Settings 应用本来就有的——用户手动拨蓝牙开关调的也是同一个 API。我们只是让 LLM 来替用户拨这个开关。

## 8. 当前实现的局限与演进方向

### 当前：静态工具注册（"穷人版 MCP"）

本项目的 5 个工具**写死在代码中**。加工具需要改代码、重新编译。这不是标准 MCP 的完整形态。

### 标准 MCP：动态加载外部 MCP Server

标准 MCP 生态中，每个工具是一个独立的 **MCP Server** 进程，客户端动态发现、动态加载：

| | 当前实现（静态注册） | 标准 MCP Server 模式 |
|---|---|---|
| 工具定义 | 代码里写死 JSON | 每个 MCP Server 自己暴露 |
| 加工具 | 改代码 + 重新编译 | 安装一个 MCP Server，不改主程序 |
| 发现机制 | 没有 | 客户端调 Server 的 `/tools` 获取列表 |
| 通信方式 | 直接调本地函数 | stdio 或 HTTP/SSE 与 Server 进程通信 |
| 生态 | 自己写 | 复用社区已有的 MCP Server（天气、搜索、数据库等） |

### 在 OpenHarmony 上加载外部 MCP Server 的可行路径

标准 MCP Server 有两种通信模式：

1. **stdio 模式**（社区主流）：启动子进程，stdin/stdout 通信。**在 OH 上不可行**——ArkTS 没有 `child_process.spawn()`，设备上也没有 Node.js/Python 运行时。
2. **HTTP/SSE 模式**：Server 跑在某个端口上，客户端 HTTP 请求。**可行**——只要 MCP Server 跑在旁边一台有 Node.js 的机器上（PC/云服务器），RK3568 通过 HTTP 去调。

可行架构：

```
RK3568 (MCP 客户端)                   PC / 云服务器
    |                                     |
    |  1. HTTP GET /tools                 |
    | ----------------------------------> |  MCP Server（社区已有的）
    |  <返回工具列表>                       |  跑在 Node.js/Python 里
    |                                     |
    |  2. DeepSeek 返回 tool_call         |
    |  3. HTTP POST /execute              |
    | ----------------------------------> |  执行工具，返回结果
    |  <返回结果>                           |
    |                                     |
    |  4. 结果喂回 DeepSeek               |
```

这样社区写好的 MCP Server（天气查询、网页搜索、数据库操作等）都能被 OpenHarmony 设备使用，只需要 Server 支持 HTTP/SSE 模式或者套一层 HTTP 网关。
