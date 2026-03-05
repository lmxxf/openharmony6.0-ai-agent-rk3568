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

## 6. 向量检索 RAG（已实现）

在关键词匹配基础上，实现了向量检索 RAG。用 SiliconFlow 的 BGE-M3 模型（免费）算 embedding，SQLite 存向量，余弦相似度检索。向量检索是主路径，关键词匹配自动降级为后备方案。

### 6.1 为什么需要向量检索？

关键词匹配的局限：
- 用户问"怎么恢复出厂设置"，关键词匹配需要知识库里恰好有"恢复出厂设置"这几个字
- 用户问"怎么把手机还原到初始状态"，意思一样，但关键词完全不同，匹配不上
- 向量检索把文本转成 1024 维向量，在语义空间里算距离，同义词、近义词都能匹配

### 6.2 架构

```
首次启动流程：
知识文件 (rawfile/knowledge/*.txt)
        |  加载切片（与关键词 RAG 共用）
        v
14 个 chunk --> 分 3 批调用 SiliconFlow BGE-M3 API
        |  每个 chunk 得到 1024 维 float 向量
        v
存入 SQLite (vector_rag.db, BLOB 格式, 每条 4096 字节)
        |
        v
标记 chunk_count=14 --> 下次启动检测一致则跳过

用户提问流程：
用户输入 "怎么恢复出厂设置"
        |
        v
调用 SiliconFlow API 算 query embedding (1024 维)
        |
        v
从 SQLite 读取全部 14 条 chunk embedding
        |
        v
逐条算余弦相似度 --> 排序取 Top-3
        |
        v
注入 system prompt --> 发送 DeepSeek API
```

### 6.3 Embedding 模型

**DeepSeek 没有 Embedding API**（官方只提供 chat 和 reasoner），所以 embedding 用 SiliconFlow 托管的开源模型。

| 配置项 | 值 | 说明 |
|--------|------|------|
| 提供商 | [SiliconFlow](https://siliconflow.cn) | 国内平台，免费开源模型不收费 |
| 模型 | `BAAI/bge-m3` | 北京智源研究院的开源 embedding 模型 |
| 向量维度 | 1024 | 每段文本输出 1024 个 float 值 |
| 最大 Token | 8192 | 支持长文本 |
| 语言 | 中英文 + 100 多种语言 | 多语言场景友好 |
| 价格 | **免费** | 属于 SiliconFlow 免费开源模型系列 |

**API 格式**（OpenAI 兼容）：

```
POST https://api.siliconflow.cn/v1/embeddings
Authorization: Bearer {api_key}
Content-Type: application/json

请求体：
{
  "model": "BAAI/bge-m3",
  "input": ["文本1", "文本2", "文本3"],
  "encoding_format": "float"
}

响应体：
{
  "object": "list",
  "data": [
    { "embedding": [0.023, -0.011, ...], "index": 0 },
    { "embedding": [-0.005, 0.032, ...], "index": 1 },
    { "embedding": [0.018, -0.027, ...], "index": 2 }
  ],
  "model": "BAAI/bge-m3"
}
```

支持批量输入（`input` 传数组），一次调用返回多条 embedding。建索引时每批 5 个 chunk，14 个 chunk 分 3 批完成。

### 6.4 向量存储（SQLite）

使用 OpenHarmony 的 `@ohos.data.relationalStore`（SQLite），独立数据库文件 `vector_rag.db`，与 Settings 应用原有的 `settings.db` 互不影响。

**表 `kb_vector_chunks`**：

| 列 | 类型 | 说明 |
|---|---|---|
| id | INTEGER PRIMARY KEY AUTOINCREMENT | 行 ID |
| doc_id | TEXT | 文档来源（如 "device_manual"） |
| chunk_index | INTEGER | 切片序号 |
| chunk_text | TEXT | 切片原文 |
| embedding | BLOB | 1024 个 float32，共 4096 字节 |

**表 `kb_meta`**：

| 列 | 类型 | 说明 |
|---|---|---|
| key | TEXT PRIMARY KEY | 键名 |
| value | TEXT | 值 |

`kb_meta` 存储 `chunk_count`（已建索引的切片数）。启动时检查：如果数据库中的 chunk_count 与当前知识库切片数一致，跳过 embedding 计算直接进入就绪状态。知识库有变化时自动重建索引。

**向量序列化**：

```
写入：number[1024] → Float32Array(1024) → .buffer → Uint8Array → BLOB（4096 字节）
读取：BLOB → Uint8Array → Float32Array → number[1024]
```

14 个 chunk 的向量数据总共约 56 KB，对 SQLite 和设备内存毫无压力。

### 6.5 余弦相似度

手写实现，纯 ArkTS，无需外部库：

```
cosineSimilarity(a, b) = dot(a, b) / (|a| × |b|)

其中：
  dot(a, b) = Σ a[i] × b[i]
  |a| = sqrt(Σ a[i]²)
  |b| = sqrt(Σ b[i]²)
```

1024 维向量计算一次约 3000 次浮点乘法 + 1 次 sqrt，14 个 chunk 全表扫描在毫秒级完成。知识库规模在几百个 chunk 以内都不需要 ANN 索引。

### 6.6 配置

在 `rawfile/api_config.json` 中添加 SiliconFlow 配置：

```json
{
  "deepseek_api_key": "sk-xxx（你的 DeepSeek API Key）",
  "deepseek_api_url": "https://api.deepseek.com/v1/chat/completions",
  "deepseek_model": "deepseek-chat",
  "siliconflow_api_key": "sk-xxx（你的 SiliconFlow API Key）",
  "siliconflow_api_url": "https://api.siliconflow.cn/v1/embeddings",
  "embedding_model": "BAAI/bge-m3",
  "mcp_servers": [...]
}
```

- `siliconflow_api_key`：去 [siliconflow.cn](https://siliconflow.cn) 注册获取，BGE-M3 模型免费
- `siliconflow_api_url`：默认 `https://api.siliconflow.cn/v1/embeddings`，一般不用改
- `embedding_model`：默认 `BAAI/bge-m3`，也可换成 SiliconFlow 上其他 embedding 模型
- **不配置 `siliconflow_api_key`（留空或不填）时，自动降级到关键词匹配，不影响任何功能**

### 6.7 降级策略

向量检索是主路径，关键词匹配是后备，自动切换，用户无感知：

| 场景 | 行为 | 用户体验 |
|------|------|----------|
| SiliconFlow API Key 未配置 | 不建索引，直接降级 | 关键词匹配，与之前一样 |
| 建索引时网络请求失败 | 标记 fallback | 关键词匹配 |
| 还在建索引时用户提问 | 检测到未就绪 | 关键词匹配 |
| 向量检索 query embedding 失败 | 该次降级 | 关键词匹配 |
| 向量检索正常但结果为空 | 退回关键词兜底 | 关键词匹配 |
| 向量检索正常 | 返回 Top-3 | 语义匹配，准确率更高 |

### 6.8 启动时序

```
aboutToAppear()
  → Promise.all([loadApiConfig(), loadKnowledgeBase()])
      // 确保 API Key 和知识库切片都就绪
    → initVectorRag()
      → vectorRagService.init(context, config)    // 建表（首次）
      → vectorRagService.buildIndex(chunks)        // 异步，不阻塞 UI
        → 检查 kb_meta.chunk_count == 14?
          → 一致：跳过，毫秒级进入 ready
          → 不一致：分 3 批调 SiliconFlow API，~1-2 秒完成
```

首次启动约 1-2 秒建索引（3 次网络请求）。后续启动检测 chunk_count 一致则跳过，即时就绪。

### 6.9 实测数据（2026-03-05）

```
# 建索引日志
[VectorRAG] Database initialized
[VectorRAG] Building index for 14 chunks...
[VectorRAG] Embedding API call: 5 texts
[VectorRAG] Embedding API success: 5 vectors, dim=1024
[VectorRAG] Indexed batch 1/3
[VectorRAG] Embedding API call: 5 texts
[VectorRAG] Embedding API success: 5 vectors, dim=1024
[VectorRAG] Indexed batch 2/3
[VectorRAG] Embedding API call: 4 texts
[VectorRAG] Embedding API success: 4 vectors, dim=1024
[VectorRAG] Indexed batch 3/3
[VectorRAG] Index built successfully: 14 chunks

# 查询日志
[VectorRAG] Embedding API call: 1 texts
[VectorRAG] Embedding API success: 1 vectors, dim=1024
[VectorRAG] Retrieved 3 chunks for query: 怎么恢复出厂设置 (top score: 0.7059)
[RAG] Vector retrieval: 3 chunks
```

14 个 chunk 建索引总耗时约 1 秒。单次查询（query embedding + 全表扫描 + 排序）约 150ms。Top score 0.7059 说明语义匹配准确命中。

## 7. 关键词 RAG vs 向量 RAG 对比

| 维度 | 关键词 RAG（后备） | 向量 RAG（主路径） |
|------|-------------------|-------------------|
| 检索方式 | bigram + 英文词匹配 | 余弦相似度 |
| 语义理解 | 弱（纯字符串匹配） | 强（同义词/近义词/语义相似都能匹配） |
| 需要网络 | 否 | 是（调 SiliconFlow API 算 embedding） |
| 需要数据库 | 否（纯内存） | 是（SQLite 存向量） |
| 首次启动开销 | 无 | ~1-2 秒建索引 |
| 查询开销 | 纯 CPU，微秒级 | 1 次 API 调用 + CPU，~150ms |
| 离线可用 | 是 | 否（降级到关键词） |
| 代码量 | ~80 行 | ~270 行（VectorRagService.ts） |
| 扩展性 | 知识库大了匹配效果差 | 知识库大了只需更多存储和扫描时间 |

两套方案并存互补：在线时用向量检索获得更好的语义匹配效果，离线或 API 不可用时自动降级到关键词匹配保证可用性。

## 8. 关键代码路径

### 关键词 RAG（后备）

- **主文件**：`product/phone/src/main/ets/pages/aiAssistant.ets`
- **知识库加载**：`loadKnowledgeBase()` → `splitIntoChunks()`
- **关键词检索**：`retrieveRelevantChunks()`
- **Prompt 注入**：`buildSystemPromptWithRAG()`（async，自动选择向量/关键词路径）

### 向量 RAG（主路径）

- **向量服务**：`product/phone/src/main/ets/model/ragImpl/VectorRagService.ts`

```
VectorRagService.init(context, config)
  → relationalStore.getRdbStore()           // 创建 vector_rag.db
  → executeSql(CREATE_CHUNKS_SQL)           // 建 kb_vector_chunks 表
  → executeSql(CREATE_META_SQL)             // 建 kb_meta 表

VectorRagService.buildIndex(chunks)
  → getMetaValue('chunk_count')             // 检查是否需要重建
  → callEmbeddingApi(texts[])               // 分批调 SiliconFlow
  → floatArrayToBlob() → store.insert()    // BLOB 存入 SQLite
  → setMetaValue('chunk_count', '14')       // 标记完成

VectorRagService.retrieveByVector(query, topK)
  → callEmbeddingApi([query])               // query embedding
  → store.query() → blobToFloatArray()     // 读取所有 chunk 向量
  → cosineSimilarity()                      // 逐条计算
  → sort + slice(0, topK)                   // 排序取 Top-K
```

### 知识库文件

- **目录**：`product/phone/src/main/resources/rawfile/knowledge/`
- **索引**：`kb_index.json`
- **文档**：`device_manual.txt`、`oh6_features.txt`、`settings_faq.txt`
- **扩展**：添加 `.txt` 文件 + 在 `kb_index.json` 注册，无需改代码。向量索引会在下次启动时自动重建（检测到 chunk_count 变化）。
