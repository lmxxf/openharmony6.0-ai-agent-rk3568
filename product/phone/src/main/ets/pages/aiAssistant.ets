/**
 * Copyright (c) 2024 OpenHarmony Contributors
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

import Router from '@system.router';
import ConfigData from '../../../../../../common/utils/src/main/ets/default/baseUtil/ConfigData';
import LogUtil from '../../../../../../common/utils/src/main/ets/default/baseUtil/LogUtil';
import HeadComponent from '../../../../../../common/component/src/main/ets/default/headComponent';
import llama from "libllama_napi.so";

interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
  timestamp: number;
}

// 模型配置
interface ModelConfig {
  name: string;
  path: string;
  size: string;
}

const AVAILABLE_MODELS: ModelConfig[] = [
  { name: 'Qwen2.5-0.5B', path: '/data/storage/el2/base/files/qwen2.5-0.5b-q4.gguf', size: '470MB' },
  { name: 'Qwen3-0.6B', path: '/data/storage/el2/base/files/qwen3-0.6b-q4.gguf', size: '381MB' },
];

const N_THREADS = 8;

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
  private scroller: Scroller = new Scroller();

  aboutToAppear() {
    LogUtil.info('AiAssistant aboutToAppear');
    this.loadModel();
  }

  aboutToDisappear() {
    LogUtil.info('AiAssistant aboutToDisappear');
    // 不在这里卸载模型，保持加载状态以便下次快速使用
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

  build() {
    Column() {
      // 顶部导航栏
      HeadComponent({ headName: $r('app.string.ai_assistant'), isActive: true })

      // 模型状态栏
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

        Button('切换模型')
          .fontSize(12)
          .height(28)
          .backgroundColor('#007AFF')
          .onClick(() => {
            this.showModelPicker = true;
          })
      }
      .width(ConfigData.WH_100_100)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor('#f5f5f5')
      .bindMenu(this.showModelPicker, this.ModelPickerMenu())

      // 聊天消息列表
      Scroll(this.scroller) {
        Column() {
          if (this.messages.length === 0) {
            // 欢迎界面
            Column() {
              Image($r('app.media.ic_ai'))
                .width(80)
                .height(80)
                .margin({ top: 60 })
              Text('AI 助手')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .margin({ top: 16 })
              Text(`当前模型: ${AVAILABLE_MODELS[this.currentModelIndex].name}`)
                .fontSize(14)
                .fontColor('#999999')
                .margin({ top: 8 })
              Text('在设备端运行，保护您的隐私')
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

      // 输入区域
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

    // 先添加一个空的助手消息，后续流式填充
    const assistantMessage: ChatMessage = {
      role: 'assistant',
      content: '',
      timestamp: Date.now()
    };
    this.messages.push(assistantMessage);
    const msgIndex = this.messages.length - 1;

    // 滚动到底部
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 100);

    // 构造对话格式的 prompt
    const formattedPrompt: string = this.formatPrompt(prompt);

    // 流式回调：每收到一个 token 就更新 UI
    const streamCallback = (token: string, done: boolean) => {
      if (!done) {
        // 追加 token 到消息
        this.messages[msgIndex] = {
          role: 'assistant',
          content: this.messages[msgIndex].content + token,
          timestamp: this.messages[msgIndex].timestamp
        };
        // 滚动到底部
        this.scroller.scrollEdge(Edge.Bottom);
      } else {
        // 生成完成
        this.isLoading = false;
        setTimeout(() => {
          this.scroller.scrollEdge(Edge.Bottom);
        }, 100);
      }
    };

    // 使用流式接口
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

  // 格式化 prompt 为 Qwen3 对话格式
  formatPrompt(userInput: string): string {
    // Qwen3 chat template (ChatML格式，与Qwen2.5兼容)
    let prompt = '<|im_start|>system\n你是一个运行在OpenHarmony设备上的本地AI助手。请简洁回答用户问题。<|im_end|>\n';

    // 添加历史对话（最多保留最近 1 轮，减少推理时间）
    const recentMessages = this.messages.slice(-2);
    for (const msg of recentMessages) {
      if (msg.role === 'user') {
        prompt += `<|im_start|>user\n${msg.content}<|im_end|>\n`;
      } else {
        prompt += `<|im_start|>assistant\n${msg.content}<|im_end|>\n`;
      }
    }

    // 添加当前用户输入
    prompt += `<|im_start|>user\n${userInput}<|im_end|>\n<|im_start|>assistant\n`;

    return prompt;
  }
}
