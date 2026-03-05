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
