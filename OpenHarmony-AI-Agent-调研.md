# OpenHarmony AI Agent 调研报告

> 调研时间：2026-01-29
>
> 调研目的：梳理手机端开源 GUI Agent 方案，明确 OpenHarmony AI Agent 项目的生态定位与技术路线

---

## 一、行业概览

2025-2026 年，手机端 AI Agent（GUI Agent）成为热点。核心能力是**通过视觉理解屏幕 + 模拟用户操作**，实现跨应用自动化。

主要技术路线：
- **云端大模型驱动**：依赖 GPT-4V / Gemini 做决策，能力强但延迟高、成本高
- **端侧小模型**：3B-8B 参数本地推理，离线可用、保护隐私
- **框架+模型分离**：框架负责控制，模型可替换

---

## 二、主流开源项目

### 2.1 一线项目（活跃维护）

| 项目 | 来源 | 参数量 | 特点 | GitHub |
|------|------|--------|------|--------|
| **Mobile-Agent-v3** | 阿里 X-PLUG | 7B | 跨平台（手机+桌面），AndroidWorld 73.3%，开源 SOTA | [X-PLUG/MobileAgent](https://github.com/X-PLUG/MobileAgent) |
| **AgentCPM-GUI** | 清华 THUNLP + 面壁 | 8B | **首个中文 App 适配**（高德、大众点评、B站、小红书等 30+），强化微调 | [OpenBMB/AgentCPM-GUI](https://github.com/OpenBMB/AgentCPM-GUI) |
| **OpenPhone** | 港大 | **3B** | 端侧原生设计，无需云端，适配消费级 GPU/NPU | [HKUDS/OpenPhone](https://github.com/HKUDS/OpenPhone) |
| **AppAgent / AppAgentX** | 腾讯 | 依赖 GPT-4V | 2025.3 发布 AppAgentX，带进化机制 | [TencentQQGYLab/AppAgent](https://github.com/TencentQQGYLab/AppAgent) |
| **mobile-use** | Minitap | 框架 | Android + iOS 双端，**AndroidWorld 100%**（首个满分） | [minitap-ai/mobile-use](https://github.com/minitap-ai/mobile-use) |
| **OMG-Agent** | Safphere | - | 纯开源 Mobile GUI Agent | [Safphere/OMG-Agent](https://github.com/Safphere/OMG-Agent) |

### 2.2 重量级项目（部分开源）

| 项目 | 来源 | 状态 | 说明 |
|------|------|------|------|
| **MAI-UI** | 阿里通义 | 2B/8B 权重开放 | AndroidWorld 76.7%，超 Gemini 2.5 Pro，HuggingFace 可下载 |
| **Open-AutoGLM** | 智谱 | 2025.12 开源 | 模型可下载 |
| **UI-TARS / UI-TARS-2** | 字节 | 部分开源 | 视觉定位能力强 |
| **GUI-Owl** | 阿里 X-PLUG | 开源 | Mobile-Agent-v3 的基座模型，专注 GUI 感知和定位 |

### 2.3 Benchmark 排行（AndroidWorld）

| 排名 | 项目 | 成功率 |
|------|------|--------|
| 1 | mobile-use | 100% |
| 2 | MAI-UI-8B | 76.7% |
| 3 | Mobile-Agent-v3 | 73.3% |
| 4 | AgentCPM-GUI | ~70% |

---

## 三、重点项目详解

### 3.1 Mobile-Agent-v3 (阿里)

**技术栈**：
- 基座模型：GUI-Owl-7B（多模态 VLM）
- 架构：多 Agent 协作框架
- 能力：GUI 感知 + 定位 + 端到端操作

**亮点**：
- 跨平台：Android + Desktop（OSWorld 37.7%）
- 2025.8 发布，持续更新
- 2025.9 发布 UI-S1（半在线强化学习）

**代码结构**：
```
MobileAgent/
├── GUI-Owl/          # 基座视觉模型
├── mobile_agent_v3/  # Agent 框架
└── benchmarks/       # 评测脚本
```

### 3.2 AgentCPM-GUI (清华/面壁)

**技术栈**：
- 基座模型：MiniCPM-V (8B)
- 训练：大规模双语 Android 数据集预训练 + 强化微调 (RFT)

**亮点**：
- **首个中文 App 深度适配**：高德、大众点评、B站、小红书、微信等 30+ 应用
- 强化微调让模型"先想再动"，提升规划能力
- 输入：截图 → 输出：结构化操作指令

**适用场景**：
- 国内 App 自动化（其他项目主要针对英文 App）
- 需要复杂推理的多步骤任务

### 3.3 OpenPhone (港大)

**技术栈**：
- 参数量：3B（专为端侧设计）
- 推理：消费级 GPU (8-12GB) / 移动 NPU

**亮点**：
- **真正的端侧部署**：无需云端，零 API 成本
- 3B 模型推理速度是 7B 的 3-5 倍
- 隐私保护：数据不出设备

**适用场景**：
- 算力受限的嵌入式设备
- 对隐私要求高的场景
- 需要离线运行的场景

### 3.4 mobile-use (Minitap)

**技术栈**：
- 架构：框架层（不绑定特定模型）
- 平台：Android + iOS 双端支持

**亮点**：
- **AndroidWorld 100%** —— 首个满分
- 框架与模型解耦，可接入任意 LLM
- 支持真机控制（不只是模拟器）

**适用场景**：
- 需要灵活切换模型的场景
- iOS 自动化（其他项目主要只支持 Android）

---

## 四、豆包手机助手深度调研

> 字节跳动 2025.12 发布的"豆包手机助手"是目前**落地最激进**的系统级 GUI Agent 产品，值得单独分析。

### 4.1 产品概述

**发布时间**：2025 年 12 月 1 日

**合作方式**：字节不造手机，与中兴合作推出首款工程样机 nubia M153
- 配置：骁龙 8s Gen 3 + 16GB + 512GB
- 售价：3499 元
- 首批 3 万台秒罄，二手市场价格翻番

**核心定位**：系统级 AI 助手，深度植入 Android 底层，拥有 GPU 缓冲区抓取和系统事件注入权限

### 4.2 技术架构

#### 4.2.1 核心模型：UI-TARS 系列

豆包手机助手基于字节自研的 **UI-TARS** 模型，演进路线：

| 版本 | 发布时间 | 特点 |
|------|----------|------|
| UI-TARS 1.0 | 2025.01 | 初代开源，性能优于当时曝光的 OpenAI Operator |
| UI-TARS 1.5 | 2025.04 | 加入强化学习驱动的推理机制（先想后做） |
| **UI-TARS 2.0** | 2025.09 | 集成 GUI + Game + Code + Tool Use，"All In One" |

**UI-TARS-2 架构**：
- 视觉编码器：532M 参数
- 语言模型：23B 激活参数（MoE 混合专家）
- 训练数据：数百万次真实手机交互
- 训练流程：持续预训练 → 监督微调 → 拒绝采样 → 多轮 RL（自增强闭环）

**开源地址**：
- [bytedance/UI-TARS (GitHub)](https://github.com/bytedance/UI-TARS)
- [bytedance/UI-TARS-desktop (GitHub)](https://github.com/bytedance/UI-TARS-desktop)

> 注意：豆包手机使用的是 **UI-TARS 闭源版本**，针对移动场景专门优化，性能高于开源版。

#### 4.2.2 双模式设计

豆包手机助手拆成两套完全不同的 Pipeline：

| 模式 | 技术路线 | 特点 | 适用场景 |
|------|----------|------|----------|
| **标准模式** | Naive Simulation | 浅层视觉 (VLM)，prompt 小，响应极快 | 简单任务，追求速度 |
| **Pro 模式** | Deep Reasoning + Tool Use | 深度推理，会 Pause & Think | 复杂任务，需要判断 |

**实测差异**（"截图陷阱"测试：相册里的截图包含伪造搜索按钮）：
- 标准模式：傻乎乎地点击图片里的按钮（System 1 直觉反应）
- Pro 模式：明显停顿思考，然后拒绝点击，建议切换浏览器

#### 4.2.3 虚拟屏幕技术

核心创新：**人机并行**
- 后台虚拟屏幕上独立完成比价、订票等复杂操作
- 用户仍在物理屏幕自由使用其他应用
- 类似"自动驾驶"，AI 和人各用各的屏幕

### 4.3 权限与安全机制

#### 4.3.1 系统级权限

豆包手机助手使用 **INJECT_EVENTS** 系统级权限：
- 可模拟用户点击、滑动、输入
- 需要用户主动授权
- 行业内 AI 助手都需要类似权限

#### 4.3.2 三层授权体系

| 阶段 | 机制 |
|------|------|
| **事前** | 首次打开弹窗提示操作及权限使用场景 |
| **事中** | 每次执行前询问：单次允许 / 始终允许 / 拒绝 |
| **事后** | 敏感操作（支付、身份验证）暂停任务，交由人工接管 |

#### 4.3.3 六类必须二次确认的操作

1. 权限与隐私管理
2. 金融与交易操作
3. 系统与设备控制
4. 法律与合规要求相关
5. 高风险不可逆操作
6. 健康与医疗数据处理

#### 4.3.4 本地模型安全

- 基于 TEE（可信执行环境）和硬件加密
- 模型从预置、分发到存储始终加密
- 密钥由 TEE 保护
- 高敏感数据处理依赖本地模型，"数据不离端"

### 4.4 风控冲突问题

#### 4.4.1 技术原理

豆包操作第三方 App 主要依赖 Android 的 **AccessibilityService（无障碍服务）**：
- 本来是给视障人士用的
- 能读取屏幕内容、模拟点击
- **在风控系统眼里 = 巨大的"后门"**

#### 4.4.2 实际遭遇

发布仅一天，用户陆续发现：

| App | 现象 |
|-----|------|
| **微信** | 触发"登录环境异常"，强制下线，无法正常登录 |
| **淘宝/闲鱼/大麦** | 强弹窗提醒 |
| **美团** | 订餐流程拒绝自动化输入 |
| **高德** | 无法被豆包操作 |

**根本原因**：风控系统不判断"是 AI 还是人"，只判断"是不是异常操作"。无障碍服务 + 事件注入 = 高风险行为。

#### 4.4.3 行业博弈

> "即使系统层的 AI 助手具备多高的系统权限，最终能否真正执行任务，仍要看各个 App 是否在业务链路、相应接口与风控体系上给予'可被自动化'的空间。"

**核心矛盾**：
- GUI Agent 要跨 App 操作 → 必须用无障碍/事件注入
- 第三方 App 风控 → 把这些行为视为高风险
- 没有应用方配合 → AI 助手的"全局执行"遇到天花板

### 4.5 当前局限性

| 局限 | 说明 |
|------|------|
| **速度** | 复杂任务执行速度尚不及人工 |
| **稳定性** | 非标准页面或动态内容容易出错 |
| **生态兼容** | 头部 App（微信、淘宝、美团）风控限制 |
| **依赖界面** | 界面改版可能导致失效 |

### 4.6 对本项目的启示

#### 4.6.1 可借鉴

| 方面 | 借鉴点 |
|------|--------|
| **双模式设计** | 标准模式（快）+ Pro 模式（准）—— 端云协同的另一种实现 |
| **虚拟屏幕** | 人机并行，不阻塞用户操作 |
| **三层授权** | 安全机制设计参考 |
| **UI-TARS 开源版** | 可作为视觉定位能力的参考实现 |

#### 4.6.2 规避

| 问题 | 规避策略 |
|------|----------|
| **风控冲突** | OpenHarmony 系统级集成，不走无障碍服务，直接调用系统 API |
| **生态依赖** | 先做 Settings 内部操作，不依赖第三方 App 配合 |
| **界面识别脆弱** | 优先用 Want/Picker 等能力调用，而非"点 UI" |

#### 4.6.3 差异化

| 豆包手机助手 | 本项目 |
|--------------|--------|
| Android + 第三方 App | OpenHarmony + 系统 Settings |
| 依赖无障碍服务 | 系统级原生集成 |
| 风控冲突严重 | 不涉及第三方 App 风控 |
| 闭源 | 完全开源 |

### 4.7 参考链接

- [起底"豆包手机"：核心技术探索早已开源 (量子位)](https://www.qbitai.com/2025/12/359876.html)
- [豆包手机的"生死劫"：权限、边界与生态 (OFweek)](https://m.ofweek.com/ai/2025-12/ART-201700-8400-30675858.html)
- [实测豆包手机助手 AI操作均需用户授权 (新华网)](https://www.news.cn/tech/20251226/a25b822dd8c545e2b238baa9b37910a1/c.html)
- [We Tested ByteDance's AI Phone First-Hand (Substack)](https://voiceofcontext.substack.com/p/we-tested-bytedances-ai-phone-first)
- [UI-TARS 官网 (ByteDance Seed)](https://seed.bytedance.com/en/ui-tars)
- [UI-TARS (GitHub)](https://github.com/bytedance/UI-TARS)

---

## 五、华为/鸿蒙生态现状

### 5.1 官方方案（均闭源）

| 方案 | 状态 | 说明 |
|------|------|------|
| **小艺智能体** | 闭源 | HarmonyOS NEXT 系统级 Agent，盘古大模型 5.0 加持 |
| **HMAF (Harmony Agent Framework)** | 闭源 SDK | HarmonyOS 6 的 Agent 框架，20 万亿 tokens 训练 |
| **DevEco CodeGenie** | 闭源 | AI 辅助编程工具 |

**HMAF 特点**：
- 系统级理解 + 规划 + 执行能力
- 50+ 第三方 Agent 接入（微博、喜马拉雅等）
- **开发者只能调用 API，核心代码不开源**

### 5.2 OpenHarmony 开源社区

| 资源 | 说明 |
|------|------|
| OpenHarmony AI 子系统 | 只有基础 AI 引擎框架，**不是 GUI Agent** |
| Gitee 鸿蒙组件市场 | 开发者贡献的组件，无 Agent 相关 |

### 5.3 结论

**OpenHarmony 生态目前没有开源的 GUI Agent 方案**。

原因：
1. 小艺是华为核心竞争力，不会开源
2. HMAF 依赖盘古大模型，模型不开源框架开源也没意义
3. OpenHarmony 定位是"系统底座"，AI 能力靠厂商自己加

---

## 六、技术方案对比

### 6.1 模型规模 vs 能力

| 参数量 | 代表项目 | 端侧可行性 | 能力上限 |
|--------|----------|------------|----------|
| 3B | OpenPhone | ✅ 手机 NPU 可跑 | 简单任务 |
| 7-8B | Mobile-Agent-v3, AgentCPM-GUI | ⚠️ 需要高端 SoC | 复杂任务 |
| 70B+ | 云端 API | ❌ 只能云端 | 最强 |

### 6.2 技术路线对比

| 路线 | 代表 | 优点 | 缺点 |
|------|------|------|------|
| 云端大模型 | AppAgent | 能力强 | 延迟高、成本高、隐私风险 |
| 端侧小模型 | OpenPhone | 离线、隐私、低成本 | 能力受限 |
| 端云协同 | 本项目 | 灵活切换 | 实现复杂 |
| 框架+模型分离 | mobile-use | 灵活 | 集成复杂 |

### 6.3 平台支持

| 项目 | Android | iOS | Desktop | OpenHarmony |
|------|---------|-----|---------|-------------|
| Mobile-Agent-v3 | ✅ | ❌ | ✅ | ❌ |
| AgentCPM-GUI | ✅ | ❌ | ❌ | ❌ |
| OpenPhone | ✅ | ❌ | ❌ | ❌ |
| mobile-use | ✅ | ✅ | ❌ | ❌ |
| **本项目** | ❌ | ❌ | ❌ | ✅ |

---

## 七、对本项目的启示

### 7.1 生态定位

**本项目是 OpenHarmony 生态第一个开源 GUI Agent**。

- Android 有 Mobile-Agent、AgentCPM-GUI、OpenPhone
- iOS 有 mobile-use
- **OpenHarmony = 空白** → 本项目填补

### 7.2 可借鉴的技术点

| 来源项目 | 可借鉴点 |
|----------|----------|
| **AgentCPM-GUI** | 强化微调 (RFT) 提升规划能力；中文 App 适配经验 |
| **OpenPhone** | 3B 模型端侧部署方案；NPU 优化思路 |
| **Mobile-Agent-v3** | GUI-Owl 的视觉定位训练数据；多 Agent 协作架构 |
| **mobile-use** | 框架与模型解耦设计；双端适配经验 |

### 7.3 差异化方向

1. **系统级集成**：直接注入 Settings，拥有更高权限（其他项目都是第三方 App）
2. **端云协同**：本地 Qwen3 + 云端 DeepSeek 双模式
3. **OpenHarmony 原生**：唯一支持鸿蒙的开源方案
4. **轻量化**：Qwen3-0.6B 比 OpenPhone 的 3B 还小，适合更低端设备

### 7.4 后续演进建议

| 阶段 | 目标 | 参考 |
|------|------|------|
| 短期 | 完善 UI-Agent Demo，支持更多 Settings 操作 | 当前实现 |
| 中期 | 接入视觉定位能力，支持任意 App | GUI-Owl |
| 长期 | 强化微调提升规划能力 | AgentCPM-GUI RFT |

---

## 八、参考链接

### 开源项目

- [Mobile-Agent (GitHub)](https://github.com/X-PLUG/MobileAgent)
- [AgentCPM-GUI (GitHub)](https://github.com/OpenBMB/AgentCPM-GUI)
- [OpenPhone (GitHub)](https://github.com/HKUDS/OpenPhone)
- [AppAgent (GitHub)](https://github.com/TencentQQGYLab/AppAgent)
- [mobile-use (GitHub)](https://github.com/minitap-ai/mobile-use)
- [OMG-Agent (GitHub)](https://github.com/Safphere/OMG-Agent)

### 华为/鸿蒙

- [OpenHarmony 官网](https://www.openharmony.cn/)
- [华为小艺官网](https://consumer.huawei.com/cn/mobileservices/celia/)
- [HarmonyOS 6 AI Agent 框架发布 (TechNode)](https://technode.com/2025/10/22/huawei-launches-harmonyos-6-with-ai-agent-framework-and-file-sharing-with-apple-devices/)

### 技术报道

- [MAI-UI 介绍 (Medium)](https://medium.com/@amlgolabs/alibabas-mai-ui-the-gui-agent-revolution-that-s-redefining-mobile-ai-in-2026-96dc5810af10)
- [小艺智能体升级 (深圳湾)](https://www.shenzhenware.com/articles/16424)
- [豆包手机助手调研 (每日经济新闻)](https://www.mrjjxw.com/articles/2025-12-11/4177585.html)

---

## 九、结论

1. **手机端 GUI Agent 已进入实用阶段**，AndroidWorld benchmark 最高已达 100%
2. **端侧小模型是趋势**，3B-8B 参数即可完成大部分任务
3. **OpenHarmony 生态是空白**，本项目填补了这一空缺
4. **技术可借鉴**，尤其是 AgentCPM-GUI 的中文适配和 OpenPhone 的端侧部署经验
5. **差异化优势明显**：系统级集成 + 端云协同 + 唯一鸿蒙支持
