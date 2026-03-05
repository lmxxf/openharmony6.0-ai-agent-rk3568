# 端侧 RAG 技术实现文档

## 1. 概述

RAG（Retrieval-Augmented Generation，检索增强生成）是一种让大语言模型基于外部知识库回答问题的技术，而非完全依赖模型参数记忆。本项目在 OpenHarmony 6.0 Settings 应用中实现了轻量级端侧 RAG：知识库以文本文件形式随 HAP 包打包分发，应用启动时加载并切片，用户提问时通过关键词检索相关片段注入 system prompt，再由云端 DeepSeek 模型基于检索上下文生成回答。

## 2. 架构

```
知识文件 (rawfile/knowledge/*.txt)
        |  启动时加载
        v
按段落切片 (~500字/片) --> 内存索引
        |  用户提问时
        v
关键词匹配打分 --> Top-3 检索
        |
        v
注入 system prompt --> 发送 DeepSeek API
        |
        v
LLM 基于检索上下文生成回答 (SSE 流式)
```

整个 RAG 流程与 MCP Tool Calling 协同工作：system prompt 中同时包含 RAG 知识上下文和工具定义，模型可以在回答知识性问题的同时调用设备控制工具。

## 3. 知识库结构

| 文件 | 说明 |
|------|------|
| `kb_index.json` | 文档元数据索引，定义每个文档的 id、文件路径、标题、关键词列表 |
| `device_manual.txt` | 设备使用手册（蓝牙/亮度/WiFi/时间/系统信息等操作指南）|
| `oh6_features.txt` | OpenHarmony 6.0 特性说明（ArkTS/Stage 模型/分布式/安全/AI 子系统）|
| `settings_faq.txt` | 设置应用常见问题 Q&A（13 个问答对）|

**扩展方式**：新增知识 = 添加一个 `.txt` 文件到 `rawfile/knowledge/` 目录 + 在 `kb_index.json` 中注册文档元数据（id、文件路径、标题、关键词）。无需修改任何代码。

## 4. 检索算法

采用三级打分机制，无需 embedding 模型，纯端侧字符串计算：

1. **文档级关键词匹配**（权重 +3/次）：`kb_index.json` 中每个文档预定义的关键词与 query 做包含匹配。命中即对该文档下的所有切片加分，实现粗粒度的文档路由。

2. **中文 bigram 匹配**（权重 +1/次）：将 query 拆成连续两字符对（如 "蓝牙连不上" -> "蓝牙"、"牙连"、"连不"、"不上"），逐一在切片内容中搜索。利用中文字符的 Unicode 范围（U+4E00~U+9FFF）过滤非中文字符。

3. **英文单词匹配**（权重 +2/次）：正则提取 query 中长度 >= 2 的英文单词，在切片中做大小写不敏感的包含匹配。

对所有切片按总分降序排列，取 Top-3 拼接后注入 system prompt。若所有切片得分均为 0，则不注入 RAG 上下文，避免引入噪声。

## 5. Prompt 注入策略

基础 system prompt 与 RAG 上下文的拼接方式：

```
你是一个运行在 OpenHarmony 设备上的 AI 助手...（基础 prompt）

以下是相关的知识库参考信息：
[检索到的切片1]
---
[检索到的切片2]
---
[检索到的切片3]

请参考以上信息回答用户问题。如果参考信息不相关，请忽略。
```

关键设计决策：
- 检索结果为空时只发基础 prompt，不注入无关内容
- 切片间用 `---` 分隔，帮助模型区分不同来源
- 尾部加"如果参考信息不相关，请忽略"兜底指令，防止模型强行使用无关信息

## 6. 与传统向量检索 RAG 对比

| 维度 | 向量检索 RAG | 本方案（关键词 RAG） |
|------|-------------|---------------------|
| 需要 embedding 模型 | 是 | 否 |
| 端侧资源占用 | 高（需加载 embedding 模型） | 极低（纯字符串匹配） |
| 语义理解能力 | 强 | 中（依赖关键词覆盖度） |
| 实现复杂度 | 高（向量数据库 + ANN 检索） | 低（约 80 行核心代码） |
| 适用场景 | 大规模知识库 | 小规模领域知识（设备手册级别） |

本方案在受限的 OpenHarmony 端侧环境下，以极低的资源开销实现了"够用"的检索增强效果，适合知识库规模在数十篇文档以内的场景。

## 7. 关键代码路径

- **主文件**：`product/phone/src/main/ets/pages/aiAssistant.ets`
- **知识库加载**：`loadKnowledgeBase()` -> `splitIntoChunks()`（L240~L279）
- **检索与注入**：`retrieveRelevantChunks()` -> `buildSystemPromptWithRAG()`（L281~L338）
- **知识文件目录**：`product/phone/src/main/resources/rawfile/knowledge/`
