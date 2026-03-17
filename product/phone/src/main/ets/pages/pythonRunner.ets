/**
 * Python Runner - Execute Python via NAPI fork+exec
 * Auto-extracts Python runtime from rawfile on first launch
 */

import fs from '@ohos.file.fs';
import ConfigData from '../../../../../../common/utils/src/main/ets/default/baseUtil/ConfigData';
import HeadComponent from '../../../../../../common/component/src/main/ets/default/headComponent';
import execNapi from 'libexec_napi.so';

// Interfaces for ArkTS strict mode
interface ToolResultData {
  path: string;
  status: string;
}

interface BridgeMessage {
  type: string;
  tool?: string;
  result?: ToolResultData;
  message?: string;
}

interface AgentResponse {
  type: string;
  content?: string;
  tool?: string;
  message?: string;
  python_version?: string;
}

@Entry
@Component
struct PythonRunner {
  @State status: string = 'Initializing...';
  @State output: string = '';
  @State isRunning: boolean = false;
  @State pythonReady: boolean = false;

  private filesDir: string = '';
  private pythonBase: string = '';

  runCmd(cmd: string): string {
    return execNapi.runCommand(cmd);
  }

  aboutToAppear(): void {
    let ctx = getContext(this);
    this.filesDir = ctx.filesDir;
    this.pythonBase = this.filesDir + '/python';

    // Check if already extracted (use runCmd to check, fs.accessSync behaves oddly)
    let check: string = this.runCmd('ls ' + this.pythonBase + '/bin/python3.11');
    if (!check.includes('exit code')) {
      this.pythonReady = true;
      this.status = 'Ready';
    } else {
      this.pythonReady = false;
      this.status = 'Not installed - click "Install Python"';
    }
  }

  installPython(): void {
    this.isRunning = true;
    this.status = 'Reading rawfile (23MB)...';
    this.output = '';

    let ctx = getContext(this);
    let tarPath: string = this.filesDir + '/python-runtime.tar.gz';

    ctx.resourceManager.getRawFileContent('python-runtime.tar.gz').then((rawData: Uint8Array) => {
      this.output = 'rawfile read: ' + rawData.byteLength + ' bytes\n';

      // Write to filesDir
      this.status = 'Writing to disk...';
      let file: fs.File = fs.openSync(tarPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
      fs.writeSync(file.fd, rawData.buffer);
      fs.closeSync(file);
      this.output += 'written to disk\n';

      // Extract
      this.status = 'Extracting...';
      let extractResult: string = this.runCmd('cd ' + this.filesDir + ' && tar xzf python-runtime.tar.gz');
      this.output += 'tar: ' + (extractResult || 'OK') + '\n';

      // Rename python-home/ to python/, set permissions, clean up
      this.status = 'Setting up...';
      let setupCmds: string[] = [
        'mv ' + this.filesDir + '/python-home ' + this.pythonBase,
        'chmod 755 ' + this.pythonBase + '/bin/python3.11',
        'rm -f ' + tarPath,
        'touch ' + this.pythonBase + '/.installed'
      ];

      for (let cmd of setupCmds) {
        let r: string = this.runCmd(cmd);
        if (r.includes('exit code')) {
          this.output += 'WARN: ' + cmd.substring(0, 50) + '... → ' + r.trim() + '\n';
        }
      }

      // Verify
      let verifyResult: string = this.runCmd('ls ' + this.pythonBase + '/bin/python3.11');
      if (verifyResult.includes('exit code')) {
        this.status = 'Install Failed';
        this.output += 'verify failed: ' + verifyResult;
      } else {
        this.pythonReady = true;
        this.status = 'Ready (installed!)';
        this.output += '\nPython runtime extracted successfully!';
      }
      this.isRunning = false;
    }).catch((err: Error) => {
      this.status = 'Install Failed';
      this.output = 'Error reading rawfile: ' + err.message;
      this.isRunning = false;
    });
  }

  testEcho(): void {
    this.isRunning = true;
    this.status = 'Running...';
    try {
      this.output = this.runCmd('echo hello from system app');
      this.status = 'Echo OK';
    } catch (e) {
      this.output = 'Error: ' + JSON.stringify(e);
      this.status = 'Failed';
    }
    this.isRunning = false;
  }

  testPython(): void {
    this.isRunning = true;
    this.status = 'Running Python...';
    try {
      let pyBin: string = this.pythonBase + '/bin/python3.11';
      let env: string = 'LD_LIBRARY_PATH=' + this.pythonBase + '/lib'
        + ' PYTHONHOME=' + this.pythonBase;
      let script: string = "import sys; print('Python', sys.version); print('Hello from OpenHarmony System App!')";
      let cmd: string = env + ' ' + pyBin + ' -c "' + script + '"';
      this.output = this.runCmd(cmd);
      this.status = this.output.includes('exit code') ? 'Python Failed' : 'Python OK';
    } catch (e) {
      this.output = 'Error: ' + JSON.stringify(e);
      this.status = 'Python Failed';
    }
    this.isRunning = false;
  }

  testLangChain(): void {
    this.isRunning = true;
    this.status = 'Calling DeepSeek via LangChain...';
    this.output = '';
    try {
      let pyBin: string = this.pythonBase + '/bin/python3.11';
      let env: string = 'LD_LIBRARY_PATH=' + this.pythonBase + '/lib'
        + ' PYTHONHOME=' + this.pythonBase;
      let script: string = [
        "import sys",
        "print('Python', sys.version.split()[0])",
        "from langchain_core.messages import HumanMessage, AIMessage",
        "print('langchain_core: OK')",
        "from openai import OpenAI",
        "print('openai SDK: OK')",
        "client = OpenAI(api_key='sk-e1747930417044149d12302141c9e4fa', base_url='https://api.deepseek.com/v1')",
        "resp = client.chat.completions.create(model='deepseek-chat', messages=[{'role':'user','content':'Say hello from OpenHarmony in one sentence.'}], max_tokens=50)",
        "text = resp.choices[0].message.content",
        "msg = AIMessage(content=text)",
        "print('Response:', text)",
        "print('Type:', type(msg).__name__)",
        "print()",
        "print('=== LangChain + DeepSeek on OpenHarmony: SUCCESS ===')"
      ].join('; ');
      let cmd: string = env + ' ' + pyBin + " -c \"" + script + "\"";
      this.output = this.runCmd(cmd);
      this.status = this.output.includes('SUCCESS') ? 'LangChain OK' :
        (this.output.includes('exit code') ? 'LangChain Failed' : 'LangChain Done');
    } catch (e) {
      this.output = 'Error: ' + JSON.stringify(e);
      this.status = 'LangChain Failed';
    }
    this.isRunning = false;
  }

  debugInfo(): void {
    this.isRunning = true;
    this.status = 'Checking...';
    try {
      let lines: string[] = [];
      lines.push('filesDir=' + this.filesDir);
      lines.push('pythonBase=' + this.pythonBase);
      lines.push('== ls python/bin ==\n' + this.runCmd('ls -la ' + this.pythonBase + '/bin/'));
      lines.push('== ls python/lib ==\n' + this.runCmd('ls ' + this.pythonBase + '/lib/'));
      lines.push('== python version ==\n' + this.runCmd(
        'LD_LIBRARY_PATH=' + this.pythonBase + '/lib PYTHONHOME=' + this.pythonBase +
        ' ' + this.pythonBase + '/bin/python3.11 -c "import sys; print(sys.version)"'));
      this.output = lines.join('\n');
      this.status = 'Debug Done';
    } catch (e) {
      this.output = 'Error: ' + JSON.stringify(e);
      this.status = 'Debug Failed';
    }
    this.isRunning = false;
  }

  // ============================================================
  // Daemon mode: persistent Python subprocess with stdin/stdout pipes
  // ============================================================

  @State daemonRunning: boolean = false;
  @State chatInput: string = '';

  startAgent(): void {
    this.isRunning = true;
    this.status = 'Starting agent daemon...';
    this.output = '';
    try {
      // First, copy agent_daemon.py from rawfile to filesDir
      let ctx = getContext(this);
      ctx.resourceManager.getRawFileContent('agent_daemon.py').then((data: Uint8Array) => {
        let scriptPath: string = this.filesDir + '/agent_daemon.py';
        let file: fs.File = fs.openSync(scriptPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
        fs.writeSync(file.fd, data.buffer);
        fs.closeSync(file);

        // Start daemon
        let ok: boolean = execNapi.startDaemon(this.pythonBase, scriptPath);
        if (!ok) {
          this.status = 'Daemon start failed';
          this.output = 'startDaemon returned false';
          this.isRunning = false;
          return;
        }

        // Read the "ready" message
        let readyMsg: string = execNapi.readMessage();
        this.output = 'daemon: ' + readyMsg + '\n';
        this.daemonRunning = true;
        this.status = 'Agent running';
        this.isRunning = false;
      }).catch((err: Error) => {
        this.status = 'Failed to read agent script';
        this.output = 'Error: ' + err.message;
        this.isRunning = false;
      });
    } catch (e) {
      this.status = 'Daemon start error';
      this.output = 'Error: ' + JSON.stringify(e);
      this.isRunning = false;
    }
  }

  sendChat(): void {
    if (!this.chatInput || !this.daemonRunning) return;
    this.isRunning = true;
    this.status = 'Sending...';
    let userMsg: string = this.chatInput;
    this.chatInput = '';

    try {
      let chatMsg: BridgeMessage = { type: 'chat', message: userMsg };
      execNapi.sendMessage(JSON.stringify(chatMsg));
      this.output += '\n[You] ' + userMsg + '\n';

      // Read response (may be tool_call or response)
      let reply: string = execNapi.readMessage();
      let parsed: AgentResponse = JSON.parse(reply) as AgentResponse;

      if (parsed.type === 'tool_call') {
        let toolName: string = parsed.tool || 'unknown';
        this.output += '[Tool Call] ' + toolName + '\n';

        // Simulate tool execution (for now, fake camera result)
        let resultData: ToolResultData = { path: this.filesDir + '/fake_photo.jpg', status: 'simulated' };
        let toolResult: BridgeMessage = { type: 'tool_result', tool: toolName, result: resultData };
        execNapi.sendMessage(JSON.stringify(toolResult));

        // Read final response after tool
        let finalReply: string = execNapi.readMessage();
        let finalParsed: AgentResponse = JSON.parse(finalReply) as AgentResponse;
        this.output += '[Agent] ' + (finalParsed.content || '') + '\n';
      } else if (parsed.type === 'response') {
        this.output += '[Agent] ' + (parsed.content || '') + '\n';
      } else {
        this.output += '[Raw] ' + reply + '\n';
      }

      this.status = 'Agent running';
    } catch (e) {
      this.output += '[Error] ' + JSON.stringify(e) + '\n';
      this.status = 'Chat error';
    }
    this.isRunning = false;
  }

  stopAgent(): void {
    try {
      let shutdownMsg: BridgeMessage = { type: 'shutdown' };
      execNapi.sendMessage(JSON.stringify(shutdownMsg));
      execNapi.stopDaemon();
    } catch (e) {
      // ignore
    }
    this.daemonRunning = false;
    this.status = 'Agent stopped';
    this.output += '\n[System] Agent daemon stopped\n';
  }

  resetPython(): void {
    this.isRunning = true;
    this.status = 'Resetting...';
    try {
      this.runCmd('rm -rf ' + this.pythonBase);
      this.pythonReady = false;
      this.output = 'Python runtime removed. Re-enter page to extract again.';
      this.status = 'Reset Done';
    } catch (e) {
      this.output = 'Error: ' + JSON.stringify(e);
      this.status = 'Reset Failed';
    }
    this.isRunning = false;
  }

  build() {
    Column() {
      HeadComponent({ headName: 'Python Runner', isActive: true })

      Column() {
        Row() {
          Circle()
            .width(12)
            .height(12)
            .fill(this.isRunning ? Color.Orange :
              (this.status.includes('OK') || this.status.includes('Ready') ? Color.Green :
                (this.status.includes('Fail') ? Color.Red : Color.Gray)))
            .margin({ right: 8 })
          Text(this.status)
            .fontSize(16)
        }
        .margin({ bottom: 20 })

        if (!this.pythonReady) {
          Button('Install Python (23MB)')
            .width('80%')
            .height(50)
            .fontSize(18)
            .backgroundColor('#4CAF50')
            .margin({ bottom: 15 })
            .enabled(!this.isRunning)
            .onClick(() => { this.installPython(); })
        }

        Button('Test Echo')
          .width('80%')
          .height(45)
          .fontSize(16)
          .margin({ bottom: 10 })
          .enabled(!this.isRunning)
          .onClick(() => { this.testEcho(); })

        Button('Run Python')
          .width('80%')
          .height(45)
          .fontSize(16)
          .backgroundColor('#2196F3')
          .margin({ bottom: 10 })
          .enabled(!this.isRunning && this.pythonReady)
          .onClick(() => { this.testPython(); })

        Button('Run LangChain + DeepSeek')
          .width('80%')
          .height(45)
          .fontSize(16)
          .backgroundColor('#9C27B0')
          .margin({ bottom: 10 })
          .enabled(!this.isRunning && this.pythonReady)
          .onClick(() => { this.testLangChain(); })

        Button('Debug Info')
          .width('80%')
          .height(45)
          .fontSize(16)
          .backgroundColor('#FF9800')
          .margin({ bottom: 10 })
          .enabled(!this.isRunning)
          .onClick(() => { this.debugInfo(); })

        Button('Reset Python')
          .width('80%')
          .height(45)
          .fontSize(16)
          .backgroundColor('#F44336')
          .margin({ bottom: 20 })
          .enabled(!this.isRunning)
          .onClick(() => { this.resetPython(); })

        // ---- Agent Daemon Section ----
        Divider().margin({ bottom: 10 })

        if (!this.daemonRunning) {
          Button('Start Agent Daemon')
            .width('80%')
            .height(45)
            .fontSize(16)
            .backgroundColor('#00BCD4')
            .margin({ bottom: 10 })
            .enabled(!this.isRunning && this.pythonReady)
            .onClick(() => { this.startAgent(); })
        } else {
          Row() {
            TextInput({ placeholder: 'Ask the agent...', text: this.chatInput })
              .width('65%')
              .height(45)
              .fontSize(14)
              .onChange((value: string) => { this.chatInput = value; })

            Button('Send')
              .width('30%')
              .height(45)
              .fontSize(14)
              .margin({ left: '3%' })
              .backgroundColor('#00BCD4')
              .enabled(!this.isRunning)
              .onClick(() => { this.sendChat(); })
          }
          .width('80%')
          .margin({ bottom: 10 })

          Button('Stop Agent')
            .width('80%')
            .height(35)
            .fontSize(14)
            .backgroundColor('#795548')
            .margin({ bottom: 10 })
            .onClick(() => { this.stopAgent(); })
        }

        Text('Output:')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start)
          .margin({ left: 16, bottom: 8 })

        Scroll() {
          Text(this.output || '(no output yet)')
            .fontSize(13)
            .fontFamily('monospace')
            .padding(12)
            .width('100%')
            .backgroundColor('#F5F5F5')
            .borderRadius(8)
        }
        .width('92%')
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .borderRadius(8)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    }
    .width('100%')
    .height('100%')
  }
}
