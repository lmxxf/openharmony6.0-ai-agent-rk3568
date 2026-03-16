/**
 * Python Runner - Execute Python via NAPI fork+exec
 */

import ConfigData from '../../../../../../common/utils/src/main/ets/default/baseUtil/ConfigData';
import HeadComponent from '../../../../../../common/component/src/main/ets/default/headComponent';
import execNapi from 'libexec_napi.so';

@Entry
@Component
struct PythonRunner {
  @State status: string = 'Ready';
  @State output: string = '';
  @State isRunning: boolean = false;

  private pythonBase: string = '/data/storage/el2/base/haps/phone/files/python';

  runCmd(cmd: string): string {
    return execNapi.runCommand(cmd);
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

  debugInfo(): void {
    this.isRunning = true;
    this.status = 'Checking...';
    try {
      let lines: string[] = [];
      lines.push('base=' + this.pythonBase);
      lines.push('== ls python/bin ==\n' + this.runCmd('ls -la ' + this.pythonBase + '/bin/'));
      lines.push('== ls python/lib ==\n' + this.runCmd('ls ' + this.pythonBase + '/lib/'));
      lines.push('== with env ==\n' + this.runCmd('LD_LIBRARY_PATH=' + this.pythonBase + '/lib PYTHONHOME=' + this.pythonBase + ' ' + this.pythonBase + '/bin/python3.11 -c "import sys; print(sys.version)"'));
      this.output = lines.join('\n');
      this.status = 'Debug Done';
    } catch (e) {
      this.output = 'Error: ' + JSON.stringify(e);
      this.status = 'Debug Failed';
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
              (this.status.includes('OK') ? Color.Green :
                (this.status.includes('Fail') ? Color.Red : Color.Gray)))
            .margin({ right: 8 })
          Text(this.status)
            .fontSize(16)
        }
        .margin({ bottom: 20 })

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
          .enabled(!this.isRunning)
          .onClick(() => { this.testPython(); })

        Button('Debug Info')
          .width('80%')
          .height(45)
          .fontSize(16)
          .backgroundColor('#FF9800')
          .margin({ bottom: 20 })
          .enabled(!this.isRunning)
          .onClick(() => { this.debugInfo(); })

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
