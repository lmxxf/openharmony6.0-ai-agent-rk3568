/**
 * Copyright (c) 2024 OpenHarmony Contributors
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

import Router from '@system.router';
import ConfigData from '../../../../../../common/utils/src/main/ets/default/baseUtil/ConfigData';
import LogUtil from '../../../../../../common/utils/src/main/ets/default/baseUtil/LogUtil';
import HeadComponent from '../../../../../../common/component/src/main/ets/default/headComponent';
import llama from "libllama_napi.so";
import http from '@ohos.net.http';
import util from '@ohos.util';
import bluetoothModel from '../model/bluetoothImpl/BluetoothModel';
import dateAndTimeModel from '../model/dateAndTimeImpl/DateAndTimeModel';
import { BrightnessSettingModel } from '../model/displayAndBrightnessImpl/brightness/BrightnessSettingModel';
import { McpClient, McpServerConfig, McpToolOpenAi } from '../model/mcpImpl/McpClient';

// ============================================================
// 基础消息类型
// ============================================================

interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
  timestamp: number;
}

interface ApiMessage {
  role: string;
  content: string;
}

// ============================================================
// [MCP] Tool Calling 类型定义（OpenAI 兼容格式）
// ============================================================

interface McpFunctionDef {
  name: string;
  description: string;
  parameters: Record<string, Object>;
}

interface McpTool {
  type: string; // 'function'
  function: McpFunctionDef;
}

interface McpToolCallFunction {
  name: string;
  arguments: string; // JSON string
}

interface McpToolCall {
  id: string;
  type: string; // 'function'
  function: McpToolCallFunction;
}

// [MCP] 扩展请求体：携带 tools 字段
interface ApiRequestBodyWithTools {
  model: string;
  messages: Object[];
  stream: boolean;
  max_tokens: number;
  tools?: McpTool[];
  tool_choice?: string;
}

// ============================================================
// [RAG] 知识库类型
// ============================================================

interface KbDocMeta {
  id: string;
  file: string;
  title: string;
  keywords: string[];
}

interface KbIndex {
  documents: KbDocMeta[];
}

interface KbChunk {
  docId: string;
  text: string;
  keywords: string[];
}

// ArkTS 要求所有 object literal 有显式类型
interface ScoredChunk {
  chunk: string;
  score: number;
}

interface ToolResult {
  tool_call_id: string;
  result: string;
}

interface AssistantToolCallMessage {
  role: string;
  content: string | null;
  tool_calls: Object[];
}

interface ToolResultMessage {
  role: string;
  tool_call_id: string;
  content: string;
}

interface ToolCallForApi {
  id: string;
  type: string;
  function: McpToolCallFunction;
}

// ============================================================
// 模型 / 推理模式配置
// ============================================================

interface ModelConfig {
  name: string;
  path: string;
  size: string;
}

type InferenceMode = 'local' | 'cloud';

interface InferenceModeConfig {
  name: string;
  mode: InferenceMode;
  desc: string;
}

const INFERENCE_MODES: InferenceModeConfig[] = [
  { name: '本地推理', mode: 'local', desc: '离线可用，较慢' },
  { name: '云端 DeepSeek', mode: 'cloud', desc: '需联网，快速' },
];

const AVAILABLE_MODELS: ModelConfig[] = [
  { name: 'Qwen2.5-0.5B', path: '/data/storage/el2/base/files/qwen2.5-0.5b-q4.gguf', size: '470MB' },
  { name: 'Qwen3-0.6B', path: '/data/storage/el2/base/files/qwen3-0.6b-q4.gguf', size: '381MB' },
];

// DeepSeek API 配置（运行时从 rawfile/api_config.json 加载）
let DEEPSEEK_API_URL = 'https://api.deepseek.com/v1/chat/completions';
let DEEPSEEK_API_KEY = '';
let DEEPSEEK_MODEL = 'deepseek-chat';

const N_THREADS = 8;

// ============================================================
// [MCP] 工具注册表 — 声明式定义，扩展只需加一条
// ============================================================

const PAGE_URI_MAP: Record<string, string> = {
  'bluetooth': 'pages/bluetooth',
  'brightness': 'pages/screenAndBrightness',
  'dateAndTime': 'pages/dateAndTime',
  'wifi': 'pages/wifi',
  'aboutDevice': 'pages/system/aboutDevice',
};

// [MCP] 工具定义用 JSON 字符串，运行时 parse（绕过 ArkTS 的 arkts-no-untyped-obj-literals 限制）
const MCP_TOOLS_JSON = '[{"type":"function","function":{"name":"set_bluetooth","description":"控制蓝牙开关。可以打开、关闭或切换蓝牙状态。","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["enable","disable","toggle"],"description":"蓝牙操作：enable=打开，disable=关闭，toggle=切换当前状态"}},"required":["action"]}}},{"type":"function","function":{"name":"set_brightness","description":"设置屏幕亮度百分比（0-100）。","parameters":{"type":"object","properties":{"percent":{"type":"number","description":"亮度百分比，0 到 100 之间的整数"}},"required":["percent"]}}},{"type":"function","function":{"name":"set_time_format","description":"设置系统时间显示格式为 12 小时制或 24 小时制。","parameters":{"type":"object","properties":{"format":{"type":"string","enum":["12h","24h"],"description":"时间格式"}},"required":["format"]}}},{"type":"function","function":{"name":"navigate_to_page","description":"导航到设置应用内的指定页面。可选页面: bluetooth, brightness, dateAndTime, wifi, aboutDevice","parameters":{"type":"object","properties":{"page":{"type":"string","enum":["bluetooth","brightness","dateAndTime","wifi","aboutDevice"],"description":"目标页面"}},"required":["page"]}}},{"type":"function","function":{"name":"query_device_status","description":"查询设备当前状态（蓝牙状态、屏幕亮度等）。","parameters":{"type":"object","properties":{"query_type":{"type":"string","enum":["bluetooth","brightness","all"],"description":"查询类型：bluetooth=蓝牙状态，brightness=亮度值，all=全部"}},"required":["query_type"]}}}]';
const MCP_TOOLS: McpTool[] = JSON.parse(MCP_TOOLS_JSON) as McpTool[];

// ============================================================
// 主组件
// ============================================================

@Entry
@Component
struct AiAssistant {
  @State messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State isLoading: boolean = false;
  @State modelStatus: string = '模型未加载';
  @State modelLoaded: boolean = false;
  @State currentModelIndex: number = 0;
  @State showModelPicker: boolean = false;
  @State inferenceMode: InferenceMode = 'cloud';
  @State showModePicker: boolean = false;
  private scroller: Scroller = new Scroller();
  private deepSeekSseBuffer: string = '';
  private deepSeekDecoder: util.TextDecoder = new util.TextDecoder();
  private brightnessModel: BrightnessSettingModel = new BrightnessSettingModel();
  // [MCP] 流式累积 tool_calls
  private pendingToolCalls: McpToolCall[] = [];
  private toolCallArgBuffers: Map<number, string> = new Map();
  private currentStreamMsgIndex: number = -1;
  private currentStreamMessages: Object[] = [];
  // [MCP] 远程 MCP Client
  private mcpClient: McpClient = new McpClient();
  private remoteToolRouteMap: Map<string, number> = new Map();
  private allTools: McpToolOpenAi[] = [];
  // [RAG] 知识库切片
  private knowledgeChunks: KbChunk[] = [];

  aboutToAppear() {
    LogUtil.info('AiAssistant aboutToAppear');
    this.allTools = [...MCP_TOOLS] as McpToolOpenAi[];
    this.loadApiConfig();
    this.loadKnowledgeBase();

    if (this.inferenceMode === 'local') {
      this.loadModel();
    } else {
      this.modelStatus = '云端 DeepSeek (MCP+RAG)';
      this.modelLoaded = true;
    }
  }

  async loadApiConfig() {
    try {
      const context = getContext(this);
      const resourceManager = context.resourceManager;
      const configData = await resourceManager.getRawFileContent('api_config.json');
      const configStr = this.decodeUtf8(configData);
      const config = JSON.parse(configStr) as Record<string, Object>;
      if (config['deepseek_api_key']) {
        DEEPSEEK_API_KEY = config['deepseek_api_key'] as string;
        LogUtil.info('[MCP] API Key loaded');
      }
      if (config['deepseek_api_url']) {
        DEEPSEEK_API_URL = config['deepseek_api_url'] as string;
      }
      if (config['deepseek_model']) {
        DEEPSEEK_MODEL = config['deepseek_model'] as string;
      }
      // [MCP] 加载远程 MCP Server 配置
      const mcpServersVal = config['mcp_servers'];
      if (mcpServersVal) {
        const serversJson = JSON.stringify(mcpServersVal);
        const servers = JSON.parse(serversJson) as McpServerConfig[];
        if (servers.length > 0) {
          this.initMcpServers(servers);
        }
      }
    } catch (error) {
      LogUtil.error('[MCP] Failed to load API config: ' + JSON.stringify(error));
      if (this.inferenceMode === 'cloud') {
        this.modelStatus = 'API 配置缺失';
        this.modelLoaded = false;
      }
    }
  }

  // ============================================================
  // [MCP] 远程 MCP Server 初始化
  // ============================================================

  private async initMcpServers(configs: McpServerConfig[]) {
    LogUtil.info('[MCP] Initializing ' + configs.length + ' remote MCP servers');
    await this.mcpClient.initAll(configs);

    const remoteTools = this.mcpClient.getAllRemoteToolsAsOpenAi();
    this.allTools = [...MCP_TOOLS as McpToolOpenAi[], ...remoteTools];
    this.remoteToolRouteMap = this.mcpClient.buildToolRouteMap();

    LogUtil.info('[MCP] Total tools available: ' + this.allTools.length +
      ' (local: ' + MCP_TOOLS.length + ', remote: ' + remoteTools.length + ')');
    if (this.inferenceMode === 'cloud') {
      this.modelStatus = '云端 DeepSeek (MCP+RAG, ' + this.allTools.length + ' tools)';
    }
  }

  private isLocalTool(name: string): boolean {
    const localNames: string[] = ['set_bluetooth', 'set_brightness', 'set_time_format',
      'navigate_to_page', 'query_device_status'];
    return localNames.includes(name);
  }

  // ============================================================
  // [RAG] 知识库加载与检索
  // ============================================================

  async loadKnowledgeBase() {
    try {
      const resourceManager = getContext(this).resourceManager;
      const indexData = await resourceManager.getRawFileContent('knowledge/kb_index.json');
      const index = JSON.parse(this.decodeUtf8(indexData)) as KbIndex;

      for (const doc of index.documents) {
        try {
          const content = await resourceManager.getRawFileContent(doc.file);
          const text = this.decodeUtf8(content);
          const chunks = this.splitIntoChunks(text, 500);
          for (const chunk of chunks) {
            this.knowledgeChunks.push({ docId: doc.id, text: chunk, keywords: doc.keywords });
          }
        } catch (e) {
          LogUtil.error('[RAG] Failed to load doc: ' + doc.file);
        }
      }
      LogUtil.info('[RAG] Knowledge base loaded: ' + this.knowledgeChunks.length + ' chunks');
    } catch (error) {
      LogUtil.error('[RAG] Failed to load knowledge base: ' + JSON.stringify(error));
    }
  }

  private splitIntoChunks(text: string, maxLen: number): string[] {
    const paragraphs = text.split(/\n\n+/);
    const chunks: string[] = [];
    let current = '';
    for (const para of paragraphs) {
      if (current.length + para.length > maxLen && current.length > 0) {
        chunks.push(current.trim());
        current = '';
      }
      current += para + '\n\n';
    }
    if (current.trim().length > 0) {
      chunks.push(current.trim());
    }
    return chunks;
  }

  private retrieveRelevantChunks(query: string, topK: number = 3): string[] {
    const queryLower = query.toLowerCase();
    const scored: ScoredChunk[] = [];

    for (const entry of this.knowledgeChunks) {
      let score = 0;
      const chunkLower = entry.text.toLowerCase();

      // 文档级关键词匹配（权重高）
      for (const kw of entry.keywords) {
        if (query.includes(kw) || queryLower.includes(kw.toLowerCase())) {
          score += 3;
        }
      }

      // 内容级：query 中的中文字符 bigram 匹配
      for (let i = 0; i < query.length - 1; i++) {
        const c = query.charCodeAt(i);
        if (c >= 0x4E00 && c <= 0x9FFF) {
          const bigram = query.substring(i, i + 2);
          if (chunkLower.includes(bigram)) {
            score += 1;
          }
        }
      }

      // 英文单词匹配
      const words = queryLower.match(/[a-zA-Z]{2,}/g);
      if (words) {
        for (const w of words) {
          if (chunkLower.includes(w)) {
            score += 2;
          }
        }
      }

      if (score > 0) {
        scored.push({ chunk: entry.text, score: score } as ScoredChunk);
      }
    }

    scored.sort((a, b) => b.score - a.score);
    const results = scored.slice(0, topK).map(s => s.chunk);
    LogUtil.info('[RAG] Retrieved ' + results.length + ' chunks for query: ' + query.substring(0, 30));
    return results;
  }

  private buildSystemPromptWithRAG(userQuery: string): string {
    const basePrompt = '你是一个运行在 OpenHarmony 设备上的 AI 助手。你可以使用工具来控制设备设置（蓝牙、亮度、时间格式等），也可以查询设备状态。请根据用户意图决定是否调用工具，并用简洁的中文回答。';

    const relevantChunks = this.retrieveRelevantChunks(userQuery);
    if (relevantChunks.length === 0) {
      return basePrompt;
    }

    const ragContext = relevantChunks.join('\n---\n');
    return basePrompt + '\n\n以下是相关的知识库参考信息：\n' + ragContext + '\n\n请参考以上信息回答用户问题。如果参考信息不相关，请忽略。';
  }

  // ============================================================
  // [MCP] 工具执行器
  // ============================================================

  private executeMcpTool(name: string, argsJson: string): string {
    let args: Record<string, Object> = {};
    try {
      args = JSON.parse(argsJson) as Record<string, Object>;
    } catch (e) {
      return '参数解析失败: ' + argsJson;
    }

    LogUtil.info('[MCP] Executing tool: ' + name + ' args: ' + argsJson);

    if (name === 'set_bluetooth') {
      const action = args['action'] as string;
      try {
        if (action === 'enable') {
          bluetoothModel.enableBluetooth();
          return '蓝牙已开启';
        } else if (action === 'disable') {
          bluetoothModel.disableBluetooth();
          return '蓝牙已关闭';
        } else if (action === 'toggle') {
          const state = bluetoothModel.getState();
          if (state === 2) {
            bluetoothModel.disableBluetooth();
            return '蓝牙已关闭（原来是开启状态）';
          } else {
            bluetoothModel.enableBluetooth();
            return '蓝牙已开启（原来是关闭状态）';
          }
        }
      } catch (e) {
        return '蓝牙操作失败: ' + JSON.stringify(e);
      }
    }

    if (name === 'set_brightness') {
      const percent = Math.max(0, Math.min(100, Number(args['percent'])));
      const min = this.brightnessModel.getMinBrightness();
      const max = this.brightnessModel.getMaxBrightness();
      const value = Math.round(min + (max - min) * (percent / 100.0));
      this.brightnessModel.setValue(value, 0);
      return '亮度已设置为 ' + percent + '%';
    }

    if (name === 'set_time_format') {
      const format = args['format'] as string;
      if (format === '24h') {
        dateAndTimeModel.setTimeFormatAs24H();
        return '已切换为 24 小时制';
      } else if (format === '12h') {
        dateAndTimeModel.setTimeFormatAs12H();
        return '已切换为 12 小时制';
      }
    }

    if (name === 'navigate_to_page') {
      const page = args['page'] as string;
      const uri = PAGE_URI_MAP[page] || '';
      if (uri.length > 0) {
        Router.push({ uri: uri });
        return '已导航到: ' + page;
      }
      return '未知页面: ' + page;
    }

    if (name === 'query_device_status') {
      const queryType = args['query_type'] as string;
      const status: string[] = [];
      if (queryType === 'bluetooth' || queryType === 'all') {
        const btState = bluetoothModel.getState();
        status.push('蓝牙: ' + (btState === 2 ? '已开启' : '已关闭'));
      }
      if (queryType === 'brightness' || queryType === 'all') {
        const val = this.brightnessModel.getValue();
        const min = this.brightnessModel.getMinBrightness();
        const max = this.brightnessModel.getMaxBrightness();
        const pct = max > min ? Math.round((val - min) / (max - min) * 100) : 0;
        status.push('亮度: ' + pct + '%');
      }
      return status.length > 0 ? status.join(', ') : '无查询结果';
    }

    return '未知工具: ' + name;
  }

  // ============================================================
  // 生命周期 & 模型管理（与之前相同）
  // ============================================================

  aboutToDisappear() {
    LogUtil.info('AiAssistant aboutToDisappear');
  }

  loadModel() {
    const model = AVAILABLE_MODELS[this.currentModelIndex];
    this.modelStatus = `正在加载 ${model.name}...`;

    LogUtil.info("LlamaNAPI: llama object type: " + typeof llama);
    if (typeof llama === "undefined" || llama === null) {
      this.modelStatus = "模块导入失败";
      return;
    }
    try {
      const success: boolean = llama.loadModel(model.path, N_THREADS);
      if (success) {
        this.modelStatus = `${model.name} 已加载`;
        this.modelLoaded = true;
        LogUtil.info('Model loaded successfully: ' + model.name);
      } else {
        this.modelStatus = `${model.name} 加载失败`;
        this.modelLoaded = false;
        LogUtil.error('Failed to load model: ' + model.name);
      }
    } catch (error) {
      this.modelStatus = '模型加载出错';
      this.modelLoaded = false;
      LogUtil.error('Error loading model: ' + JSON.stringify(error));
    }
  }

  switchModel(index: number) {
    if (index === this.currentModelIndex && this.modelLoaded) {
      return;
    }
    this.currentModelIndex = index;
    this.modelLoaded = false;
    this.messages = [];
    this.loadModel();
  }

  switchInferenceMode(mode: InferenceMode) {
    if (mode === this.inferenceMode) {
      return;
    }
    this.inferenceMode = mode;
    this.messages = [];

    if (mode === 'local') {
      this.modelLoaded = false;
      this.loadModel();
    } else {
      this.modelStatus = '云端 DeepSeek (MCP+RAG)';
      this.modelLoaded = true;
    }
  }

  // ============================================================
  // UI
  // ============================================================

  build() {
    Column() {
      HeadComponent({ headName: $r('app.string.ai_assistant'), isActive: true })

      Row() {
        Circle()
          .width(8)
          .height(8)
          .fill(this.modelLoaded ? '#52c41a' : '#faad14')
        Text(this.modelStatus)
          .fontSize(12)
          .fontColor('#666666')
          .margin({ left: 8 })

        Blank()

        Button(this.inferenceMode === 'local' ? '本地' : '云端')
          .fontSize(12)
          .height(28)
          .backgroundColor(this.inferenceMode === 'local' ? '#52c41a' : '#007AFF')
          .onClick(() => {
            this.showModePicker = true;
          })
          .bindMenu(this.showModePicker, this.ModePickerMenu())

        if (this.inferenceMode === 'local') {
          Button('切换模型')
            .fontSize(12)
            .height(28)
            .backgroundColor('#007AFF')
            .margin({ left: 8 })
            .onClick(() => {
              this.showModelPicker = true;
            })
            .bindMenu(this.showModelPicker, this.ModelPickerMenu())
        }
      }
      .width(ConfigData.WH_100_100)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor('#f5f5f5')

      Scroll(this.scroller) {
        Column() {
          if (this.messages.length === 0) {
            Column() {
              Image($r('app.media.ic_ai'))
                .width(80)
                .height(80)
                .margin({ top: 60 })
              Text('AI 助手')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .margin({ top: 16 })
              Text(this.inferenceMode === 'local'
                ? `当前模型: ${AVAILABLE_MODELS[this.currentModelIndex].name}`
                : '当前模型: DeepSeek Chat (MCP+RAG)')
                .fontSize(14)
                .fontColor('#999999')
                .margin({ top: 8 })
              Text(this.inferenceMode === 'local'
                ? '在设备端运行，保护您的隐私'
                : '支持工具调用 (MCP) 和知识检索 (RAG)')
                .fontSize(12)
                .fontColor('#cccccc')
                .margin({ top: 4 })
            }
            .width(ConfigData.WH_100_100)
            .alignItems(HorizontalAlign.Center)
          } else {
            ForEach(this.messages, (msg: ChatMessage, index: number) => {
              this.MessageBubble(msg)
            })
          }

          if (this.isLoading) {
            Row() {
              LoadingProgress()
                .width(20)
                .height(20)
              Text('AI正在思考...')
                .fontSize(14)
                .fontColor('#999999')
                .margin({ left: 8 })
            }
            .margin({ top: 12, bottom: 12 })
          }
        }
        .width(ConfigData.WH_100_100)
        .padding({ left: 16, right: 16, bottom: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Row() {
        TextInput({ placeholder: '输入消息...', text: this.inputText })
          .layoutWeight(1)
          .height(44)
          .borderRadius(22)
          .backgroundColor('#f0f0f0')
          .padding({ left: 16, right: 16 })
          .onChange((value: string) => {
            this.inputText = value;
          })
          .onSubmit(() => {
            this.sendMessage();
          })

        Button() {
          Image($r('app.media.ic_ok'))
            .width(24)
            .height(24)
            .fillColor(Color.White)
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor(this.inputText.length > 0 && this.modelLoaded ? '#007AFF' : '#cccccc')
        .margin({ left: 8 })
        .enabled(this.inputText.length > 0 && !this.isLoading && this.modelLoaded)
        .onClick(() => {
          this.sendMessage();
        })
      }
      .width(ConfigData.WH_100_100)
      .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      .backgroundColor(Color.White)
    }
    .width(ConfigData.WH_100_100)
    .height(ConfigData.WH_100_100)
    .backgroundColor('#f5f5f5')
  }

  @Builder
  ModelPickerMenu() {
    Menu() {
      ForEach(AVAILABLE_MODELS, (model: ModelConfig, index: number) => {
        MenuItem({
          content: `${model.name} (${model.size})`,
        })
          .selected(index === this.currentModelIndex)
          .onChange((selected: boolean) => {
            if (selected) {
              this.showModelPicker = false;
              this.switchModel(index);
            }
          })
      })
    }
  }

  @Builder
  ModePickerMenu() {
    Menu() {
      ForEach(INFERENCE_MODES, (modeConfig: InferenceModeConfig) => {
        MenuItem({
          content: `${modeConfig.name} - ${modeConfig.desc}`,
        })
          .selected(modeConfig.mode === this.inferenceMode)
          .onChange((selected: boolean) => {
            if (selected) {
              this.showModePicker = false;
              this.switchInferenceMode(modeConfig.mode);
            }
          })
      })
    }
  }

  @Builder
  MessageBubble(msg: ChatMessage) {
    Row() {
      if (msg.role === 'assistant') {
        Image($r('app.media.ic_ai'))
          .width(32)
          .height(32)
          .margin({ right: 8 })
      }

      Column() {
        Text(msg.content)
          .fontSize(15)
          .fontColor(msg.role === 'user' ? Color.White : '#333333')
          .textAlign(msg.role === 'user' ? TextAlign.End : TextAlign.Start)
      }
      .padding(12)
      .borderRadius(16)
      .backgroundColor(msg.role === 'user' ? '#007AFF' : Color.White)
      .constraintSize({ maxWidth: '75%' })

      if (msg.role === 'user') {
        Image($r('app.media.app_icon'))
          .width(32)
          .height(32)
          .margin({ left: 8 })
          .borderRadius(16)
      }
    }
    .width(ConfigData.WH_100_100)
    .justifyContent(msg.role === 'user' ? FlexAlign.End : FlexAlign.Start)
    .margin({ top: 12 })
  }

  // ============================================================
  // 消息发送入口
  // ============================================================

  sendMessage() {
    if (this.inputText.trim().length === 0 || this.isLoading || !this.modelLoaded) {
      return;
    }

    const userMessage: ChatMessage = {
      role: 'user',
      content: this.inputText.trim(),
      timestamp: Date.now()
    };
    this.messages.push(userMessage);
    const prompt = this.inputText.trim();
    this.inputText = '';
    this.isLoading = true;

    const assistantMessage: ChatMessage = {
      role: 'assistant',
      content: '',
      timestamp: Date.now()
    };
    this.messages.push(assistantMessage);
    const msgIndex = this.messages.length - 1;

    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 100);

    if (this.inferenceMode === 'cloud') {
      // [MCP+RAG] 云端推理：带工具 + 知识检索
      this.sendToDeepSeekWithTools(prompt, msgIndex);
    } else {
      this.sendToLocal(prompt, msgIndex);
    }
  }

  // ============================================================
  // [MCP+RAG] 云端推理：带 Function Calling + RAG 上下文注入
  // ============================================================

  async sendToDeepSeekWithTools(userQuery: string, msgIndex: number) {
    if (!DEEPSEEK_API_KEY || DEEPSEEK_API_KEY.trim().length === 0) {
      this.messages[msgIndex] = {
        role: 'assistant',
        content: 'DeepSeek API Key 未配置（请在 rawfile/api_config.json 填写 deepseek_api_key）',
        timestamp: Date.now()
      };
      this.isLoading = false;
      return;
    }

    // [RAG] 构造带知识检索的 system prompt
    const systemPrompt = this.buildSystemPromptWithRAG(userQuery);

    // 构造消息历史
    const apiMessages: Object[] = [
      { role: 'system', content: systemPrompt } as ApiMessage
    ];

    const recentMessages = this.messages.slice(-5, -1);
    for (const msg of recentMessages) {
      apiMessages.push({ role: msg.role, content: msg.content } as ApiMessage);
    }

    // 保存当前流状态
    this.currentStreamMsgIndex = msgIndex;
    this.currentStreamMessages = apiMessages;

    // [MCP] 带 tools 的请求（本地 + 远程合并）
    this.streamDeepSeekRequest(apiMessages, this.allTools as McpTool[], msgIndex);
  }

  // ============================================================
  // [MCP] 通用流式请求（支持 tool_calls 检测）
  // ============================================================

  private async streamDeepSeekRequest(messages: Object[], tools: McpTool[] | null, msgIndex: number) {
    this.deepSeekSseBuffer = '';
    this.deepSeekDecoder = new util.TextDecoder();
    this.pendingToolCalls = [];
    this.toolCallArgBuffers = new Map();

    const requestBody: ApiRequestBodyWithTools = {
      model: DEEPSEEK_MODEL,
      messages: messages,
      stream: true,
      max_tokens: 1024
    };
    if (tools && tools.length > 0) {
      requestBody.tools = tools;
      requestBody.tool_choice = 'auto';
    }

    const requestBodyStr = JSON.stringify(requestBody);
    LogUtil.info('[MCP] Request: ' + requestBodyStr.substring(0, 200));

    try {
      let httpRequest = http.createHttp();

      httpRequest.on('dataReceive', (data: ArrayBuffer) => {
        const chunkText = this.decodeUtf8WithStream(new Uint8Array(data));
        this.deepSeekSseBuffer += chunkText;
        this.consumeDeepSeekSseBuffer(msgIndex);
      });

      httpRequest.on('dataEnd', () => {
        LogUtil.info('[MCP] Stream ended, pending tool_calls: ' + this.pendingToolCalls.length);

        if (this.pendingToolCalls.length > 0) {
          // [MCP] 有 tool_calls — 执行工具后再请求一次
          this.handleToolCallsAndFollowUp(msgIndex);
        } else {
          this.isLoading = false;
          setTimeout(() => {
            this.scroller.scrollEdge(Edge.Bottom);
          }, 100);
        }
        httpRequest.destroy();
      });

      await httpRequest.requestInStream(DEEPSEEK_API_URL, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${DEEPSEEK_API_KEY}`
        },
        extraData: requestBodyStr,
        expectDataType: http.HttpDataType.STRING
      });

    } catch (error) {
      this.messages[msgIndex] = {
        role: 'assistant',
        content: 'API 请求出错: ' + JSON.stringify(error),
        timestamp: Date.now()
      };
      LogUtil.error('[MCP] DeepSeek error: ' + JSON.stringify(error));
      this.isLoading = false;
    }
  }

  // ============================================================
  // [MCP] Tool Calls 执行 + 后续请求
  // ============================================================

  private async handleToolCallsAndFollowUp(msgIndex: number) {
    // 执行所有 tool calls（本地同步执行，远程异步执行）
    const toolResults: ToolResult[] = [];

    for (const tc of this.pendingToolCalls) {
      let result: string;
      const toolName = tc.function.name;

      if (this.isLocalTool(toolName)) {
        result = this.executeMcpTool(toolName, tc.function.arguments);
      } else {
        // 路由到远程 MCP Server
        const serverIndex = this.remoteToolRouteMap.get(toolName);
        if (serverIndex !== undefined) {
          try {
            result = await this.mcpClient.callTool(serverIndex, toolName, tc.function.arguments);
          } catch (e) {
            result = '远程工具调用失败: ' + JSON.stringify(e);
          }
        } else {
          result = '未知工具: ' + toolName;
        }
      }

      toolResults.push({ tool_call_id: tc.id, result: result } as ToolResult);
      LogUtil.info('[MCP] Tool result: ' + toolName + ' => ' + result.substring(0, 100));
    }

    // 显示中间状态
    const toolSummary = toolResults.map(r => r.result).join('; ');
    this.messages[msgIndex] = {
      role: 'assistant',
      content: '[MCP 工具执行] ' + toolSummary + '\n',
      timestamp: this.messages[msgIndex].timestamp
    };
    this.scroller.scrollEdge(Edge.Bottom);

    // 构造后续请求：原始消息 + assistant tool_calls + tool results
    const followUpMessages: Object[] = [...this.currentStreamMessages];

    // assistant 消息（含 tool_calls）
    const toolCallsForApi: ToolCallForApi[] = [];
    for (const tc of this.pendingToolCalls) {
      const tcApi: ToolCallForApi = {
        id: tc.id,
        type: 'function',
        function: { name: tc.function.name, arguments: tc.function.arguments } as McpToolCallFunction
      };
      toolCallsForApi.push(tcApi);
    }
    const assistantMsg: AssistantToolCallMessage = {
      role: 'assistant',
      content: null,
      tool_calls: toolCallsForApi
    };
    followUpMessages.push(assistantMsg);

    // tool result 消息
    for (const tr of toolResults) {
      const toolMsg: ToolResultMessage = {
        role: 'tool',
        tool_call_id: tr.tool_call_id,
        content: tr.result
      };
      followUpMessages.push(toolMsg);
    }

    // 再次请求 DeepSeek（不带 tools，让它生成自然语言总结）
    this.streamDeepSeekRequest(followUpMessages, null, msgIndex);
  }

  // ============================================================
  // SSE 解析（增强：支持 tool_calls delta）
  // ============================================================

  private consumeDeepSeekSseBuffer(msgIndex: number) {
    let sepIndex = this.deepSeekSseBuffer.indexOf('\n\n');
    while (sepIndex !== -1) {
      const eventRaw = this.deepSeekSseBuffer.slice(0, sepIndex);
      this.deepSeekSseBuffer = this.deepSeekSseBuffer.slice(sepIndex + 2);
      this.handleDeepSeekSseEvent(eventRaw, msgIndex);
      sepIndex = this.deepSeekSseBuffer.indexOf('\n\n');
    }
  }

  private handleDeepSeekSseEvent(eventRaw: string, msgIndex: number) {
    const lines = eventRaw.split('\n');
    for (const line of lines) {
      if (!line.startsWith('data:')) {
        continue;
      }
      const dataStr = line.slice(5).trim();
      if (dataStr === '[DONE]') {
        continue;
      }
      try {
        const chunk = JSON.parse(dataStr) as Record<string, Object>;
        const choices = chunk['choices'] as Array<Record<string, Object>>;
        if (!choices || choices.length === 0) {
          continue;
        }
        const delta = choices[0]['delta'] as Record<string, Object>;
        if (!delta) {
          continue;
        }

        // [MCP] 检测 tool_calls
        const toolCallsDelta = delta['tool_calls'] as Array<Record<string, Object>>;
        if (toolCallsDelta && toolCallsDelta.length > 0) {
          for (const tcDelta of toolCallsDelta) {
            const idx = Number(tcDelta['index'] || 0);
            const fn = tcDelta['function'] as Record<string, string>;

            if (tcDelta['id']) {
              // 新的 tool call 开始
              const tc: McpToolCall = {
                id: tcDelta['id'] as string,
                type: 'function',
                function: { name: fn ? (fn['name'] || '') : '', arguments: '' }
              };
              // 确保 pendingToolCalls 有足够位置
              while (this.pendingToolCalls.length <= idx) {
                this.pendingToolCalls.push({ id: '', type: 'function', function: { name: '', arguments: '' } });
              }
              this.pendingToolCalls[idx] = tc;
              this.toolCallArgBuffers.set(idx, '');
            }

            // 累积 arguments
            if (fn && fn['arguments']) {
              const existing = this.toolCallArgBuffers.get(idx) || '';
              this.toolCallArgBuffers.set(idx, existing + fn['arguments']);
              if (this.pendingToolCalls[idx]) {
                this.pendingToolCalls[idx].function.arguments = this.toolCallArgBuffers.get(idx) || '';
              }
            }

            // 累积 name（可能分片传输）
            if (fn && fn['name'] && this.pendingToolCalls[idx]) {
              if (this.pendingToolCalls[idx].function.name.length === 0) {
                this.pendingToolCalls[idx].function.name = fn['name'];
              }
            }
          }
          continue;
        }

        // 普通文本 content delta
        const contentDelta = delta['content'] as string;
        if (contentDelta && contentDelta.length > 0) {
          this.messages[msgIndex] = {
            role: 'assistant',
            content: this.messages[msgIndex].content + contentDelta,
            timestamp: this.messages[msgIndex].timestamp
          };
          this.scroller.scrollEdge(Edge.Bottom);
        }
      } catch (e) {
        // ignore malformed JSON
      }
    }
  }

  // ============================================================
  // 本地推理（不变）
  // ============================================================

  sendToLocal(prompt: string, msgIndex: number) {
    const formattedPrompt: string = this.formatPrompt(prompt);

    const streamCallback = (token: string, done: boolean) => {
      if (!done) {
        this.messages[msgIndex] = {
          role: 'assistant',
          content: this.messages[msgIndex].content + token,
          timestamp: this.messages[msgIndex].timestamp
        };
        this.scroller.scrollEdge(Edge.Bottom);
      } else {
        this.isLoading = false;
        setTimeout(() => {
          this.scroller.scrollEdge(Edge.Bottom);
        }, 100);
      }
    };

    const streamPromise: Promise<boolean> = llama.generateStream(formattedPrompt, 128, streamCallback);
    streamPromise.catch((error: Error) => {
      this.messages[msgIndex] = {
        role: 'assistant',
        content: '推理出错: ' + JSON.stringify(error),
        timestamp: Date.now()
      };
      LogUtil.error('Generate error: ' + JSON.stringify(error));
      this.isLoading = false;

      setTimeout(() => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 100);
    });
  }

  // ============================================================
  // 工具方法
  // ============================================================

  private decodeUtf8(bytes: Uint8Array): string {
    return new util.TextDecoder().decodeWithStream(bytes);
  }

  private decodeUtf8WithStream(bytes: Uint8Array): string {
    return this.deepSeekDecoder.decodeWithStream(bytes);
  }

  formatPrompt(userInput: string): string {
    let prompt = '<|im_start|>system\n你是一个运行在OpenHarmony设备上的本地AI助手。请简洁回答用户问题。<|im_end|>\n';

    const recentMessages = this.messages.slice(-2);
    for (const msg of recentMessages) {
      if (msg.role === 'user') {
        prompt += `<|im_start|>user\n${msg.content}<|im_end|>\n`;
      } else {
        prompt += `<|im_start|>assistant\n${msg.content}<|im_end|>\n`;
      }
    }

    prompt += `<|im_start|>user\n${userInput}<|im_end|>\n<|im_start|>assistant\n`;
    return prompt;
  }
}
