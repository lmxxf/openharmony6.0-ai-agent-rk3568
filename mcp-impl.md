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

## 8. 远程 MCP Server 支持（标准 MCP Client）

在静态注册的 5 个本地工具基础上，实现了标准 MCP Client，可以连接外部 MCP Server（Streamable HTTP 协议），动态获取工具列表，与本地工具合并后一起传给 DeepSeek Function Calling。

### 架构

```
RK3568 (MCP Client)                     远程 MCP Server（高德、天气等）
    |                                     |
    |  1. POST /mcp  initialize          |
    | ----------------------------------> |  JSON-RPC 2.0 握手
    |  <200 OK + protocolVersion>          |
    |                                     |
    |  2. POST /mcp  tools/list          |
    | ----------------------------------> |  获取工具列表
    |  <返回 tools[]>                      |
    |                                     |
    |  ---- 用户发消息 ----                |
    |                                     |
    |  3. DeepSeek 返回 tool_call         |
    |  4. POST /mcp  tools/call          |
    | ----------------------------------> |  执行远程工具
    |  <返回结果>                           |
    |                                     |
    |  5. 结果喂回 DeepSeek               |
```

本地工具（蓝牙、亮度等）和远程工具共存。DeepSeek 返回 tool_call 时，先检查是否本地工具，不是则路由到对应的远程 MCP Server。

### 配置

在 `rawfile/api_config.json` 中添加 `mcp_servers` 数组：

```json
{
  "deepseek_api_key": "sk-xxx（你的 DeepSeek API Key）",
  "deepseek_api_url": "https://api.deepseek.com/v1/chat/completions",
  "deepseek_model": "deepseek-chat",
  "mcp_servers": [
    { "name": "高德地图", "url": "https://mcp.amap.com/mcp?key=4229156b6896fd12fd1629d7e4e79861" }
  ]
}
```

- `name`：显示名称，仅用于日志
- `url`：MCP Server 的 Streamable HTTP 端点，支持带 query 参数（如高德的 `?key=xxx`）
- 不配置 `mcp_servers` 或配空数组，行为与之前完全一致（只有本地工具）

### 高德地图 MCP Server

高德官方提供 MCP Server，免费使用，需要到 [lbs.amap.com](https://lbs.amap.com) 注册获取 API Key。

**Streamable HTTP 端点**：`https://mcp.amap.com/mcp?key=你的高德Key`

**提供 15 个工具**：

| 工具名 | 功能 |
|--------|------|
| `maps_weather` | 根据城市名称查询天气 |
| `maps_geo` | 地址转经纬度（地理编码） |
| `maps_regeocode` | 经纬度转地址（逆地理编码） |
| `maps_ip_location` | IP 定位 |
| `maps_text_search` | 关键词搜索 POI |
| `maps_around_search` | 周边搜索 POI |
| `maps_search_detail` | POI 详情查询 |
| `maps_direction_driving` | 驾车路径规划 |
| `maps_direction_walking` | 步行路径规划 |
| `maps_direction_bicycling` | 骑行路径规划 |
| `maps_direction_transit_integrated` | 公交路径规划 |
| `maps_distance` | 距离测量 |
| `maps_schema_navi` | 唤起高德导航 |
| `maps_schema_take_taxi` | 唤起高德打车 |
| `maps_schema_personal_map` | 行程规划地图展示 |

**实测验证**（2026-03-05）：

```bash
# 1. 握手（initialize）
curl -s -X POST "https://mcp.amap.com/mcp?key=4229156b6896fd12fd1629d7e4e79861" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'

# 响应：
# {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26",
#   "capabilities":{"logging":{},"tools":{"listChanged":false}},
#   "serverInfo":{"name":"amap-sse-server","version":"1.0.0"}}}

# 2. 获取工具列表（tools/list）
curl -s -X POST "https://mcp.amap.com/mcp?key=4229156b6896fd12fd1629d7e4e79861" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# 响应：15 个工具的完整定义（含 name、description、inputSchema）

# 3. 调用天气工具（tools/call）
curl -s -X POST "https://mcp.amap.com/mcp?key=4229156b6896fd12fd1629d7e4e79861" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"maps_weather","arguments":{"city":"北京"}}}'

# 响应：
# {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text",
#   "text":"{\"city\":\"北京市\",\"forecasts\":[{\"date\":\"2026-03-05\",
#   \"dayweather\":\"小雪\",\"nightweather\":\"多云\",\"daytemp\":\"1\",
#   \"nighttemp\":\"-5\"}, ...]}"}],"isError":false}}
```

注意：高德 MCP Server 是**无状态模式**——不返回 `Mcp-Session-Id` header，不需要 `notifications/initialized` 步骤。我们的 McpClient 兼容此模式（sessionId 为空时不发该 header）。

### 关键代码路径（远程工具调用）

文件：`product/phone/src/main/ets/model/mcpImpl/McpClient.ts`

```
McpClient.initAll(configs)
  → initServer(config)                    // 对每个 MCP Server
    → POST /mcp  initialize              // JSON-RPC 握手
    → POST /mcp  notifications/initialized // 通知（无状态 server 忽略）
    → POST /mcp  tools/list              // 获取工具列表
  → getAllRemoteToolsAsOpenAi()           // 转换为 DeepSeek tools 格式
  → buildToolRouteMap()                   // toolName → serverIndex 映射

McpClient.callTool(serverIndex, toolName, argsJson)
  → POST /mcp  tools/call               // 执行远程工具
  → 解析 result.content[].text          // 提取文本结果
```

文件：`product/phone/src/main/ets/pages/aiAssistant.ets`

```
sendMessage()
  → sendToDeepSeekWithTools()
    → streamDeepSeekRequest(messages, allTools, ...)  // allTools = 本地 + 远程
      → [DeepSeek 返回 tool_calls]
      → handleToolCallsAndFollowUp()
        → isLocalTool(name)?
          → yes: executeMcpTool()         // 本地执行（蓝牙、亮度等）
          → no:  mcpClient.callTool()     // 远程执行（高德等）
        → 结果喂回 DeepSeek 生成自然语言总结
```

### 对比

| | 静态注册（本地工具） | 远程 MCP Server |
|---|---|---|
| 工具定义 | 代码里写死 `MCP_TOOLS_JSON` | MCP Server 通过 `tools/list` 动态暴露 |
| 加工具 | 改代码 + 重新编译 | 在 `api_config.json` 加一个 server URL |
| 执行方式 | 直接调 OH 系统 API | HTTP POST `tools/call` 到远程 |
| 生态 | 自己写 | 复用社区/厂商已有的 MCP Server |
| 离线可用 | 是 | 否（需要网络） |
