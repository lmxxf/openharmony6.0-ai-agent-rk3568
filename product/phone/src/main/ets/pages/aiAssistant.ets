/**
 * Copyright (c) 2024 OpenHarmony Contributors
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

import Router from '@system.router';
import ConfigData from '../../../../../../common/utils/src/main/ets/default/baseUtil/ConfigData';
import LogUtil from '../../../../../../common/utils/src/main/ets/default/baseUtil/LogUtil';
import HeadComponent from '../../../../../../common/component/src/main/ets/default/headComponent';
import llama from 'libllama_napi.so';

interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
  timestamp: number;
}

// 模型路径配置
const MODEL_PATH = '/data/storage/el2/base/files/qwen2.5-0.5b-q4.gguf';
const N_THREADS = 8;

@Entry
@Component
struct AiAssistant {
  @State messages: ChatMessage[] = [];
  @State inputText: string = '';
  @State isLoading: boolean = false;
  @State modelStatus: string = '模型未加载';
  @State modelLoaded: boolean = false;
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
    this.modelStatus = '正在加载模型...';

    // 使用 TaskPool 在后台线程加载模型
    try {
      const success: boolean = llama.loadModel(MODEL_PATH, N_THREADS);
      if (success) {
        this.modelStatus = 'Qwen2.5-0.5B 已加载';
        this.modelLoaded = true;
        LogUtil.info('Model loaded successfully');
      } else {
        this.modelStatus = '模型加载失败';
        this.modelLoaded = false;
        LogUtil.error('Failed to load model');
      }
    } catch (error) {
      this.modelStatus = '模型加载出错';
      this.modelLoaded = false;
      LogUtil.error('Error loading model: ' + JSON.stringify(error));
    }
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

        if (!this.modelLoaded) {
          Button('重新加载')
            .fontSize(12)
            .height(28)
            .onClick(() => {
              this.loadModel();
            })
        }
      }
      .width(ConfigData.WH_100_100)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor('#f5f5f5')

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
              Text('基于 Qwen2.5-0.5B 本地模型')
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

    // 滚动到底部
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 100);

    // 构造对话格式的 prompt
    const formattedPrompt: string = this.formatPrompt(prompt);

    // 异步调用 llama.cpp 推理
    const generatePromise: Promise<string> = llama.generate(formattedPrompt, 256);
    generatePromise.then((response: string) => {
      const assistantMessage: ChatMessage = {
        role: 'assistant',
        content: response,
        timestamp: Date.now()
      };
      this.messages.push(assistantMessage);
      this.isLoading = false;

      setTimeout(() => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 100);
    }).catch((error: Error) => {
      const errorMessage: ChatMessage = {
        role: 'assistant',
        content: '推理出错: ' + JSON.stringify(error),
        timestamp: Date.now()
      };
      this.messages.push(errorMessage);
      LogUtil.error('Generate error: ' + JSON.stringify(error));
      this.isLoading = false;

      setTimeout(() => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 100);
    });
  }

  // 格式化 prompt 为 Qwen 对话格式
  formatPrompt(userInput: string): string {
    // Qwen2.5 chat template
    let prompt = '<|im_start|>system\n你是一个运行在OpenHarmony设备上的本地AI助手。请简洁回答用户问题。<|im_end|>\n';

    // 添加历史对话（最多保留最近 3 轮）
    const recentMessages = this.messages.slice(-6);
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
