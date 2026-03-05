/**
 * MCP Client — Streamable HTTP Transport
 *
 * 标准 MCP 客户端，通过 HTTP 连接外部 MCP Server，
 * 动态获取工具列表，执行远程工具调用。
 *
 * 协议参考：https://modelcontextprotocol.io/specification/2025-03-26/basic/transports
 */

import http from '@ohos.net.http';
import LogUtil from '../../../../../../../common/utils/src/main/ets/default/baseUtil/LogUtil';

// ============================================================
// 类型定义
// ============================================================

export interface McpServerConfig {
  name: string;
  url: string;
}

interface McpRemoteTool {
  name: string;
  description: string;
  inputSchema: Record<string, Object>;
}

interface McpToolsListResult {
  tools: McpRemoteTool[];
  nextCursor?: string;
}

interface McpJsonRpcResponse {
  jsonrpc: string;
  id?: number;
  result?: Record<string, Object>;
  error?: McpJsonRpcError;
}

interface McpJsonRpcError {
  code: number;
  message: string;
}

interface McpContentItem {
  type: string;
  text: string;
}

interface McpCallResult {
  content: McpContentItem[];
  isError: boolean;
}

// DeepSeek (OpenAI 兼容) 工具格式 — 与 aiAssistant.ets 中的定义对齐
export interface McpFunctionDef {
  name: string;
  description: string;
  parameters: Record<string, Object>;
}

export interface McpToolOpenAi {
  type: string;
  function: McpFunctionDef;
}

// ============================================================
// Server 运行时状态
// ============================================================

interface McpServerState {
  config: McpServerConfig;
  sessionId: string;
  tools: McpRemoteTool[];
  ready: boolean;
  error: string;
}

// ============================================================
// McpClient
// ============================================================

export class McpClient {
  private servers: McpServerState[] = [];
  private requestId: number = 0;

  private nextId(): number {
    this.requestId++;
    return this.requestId;
  }

  // --------------------------------------------------------
  // 公开接口
  // --------------------------------------------------------

  /**
   * 并发初始化所有 MCP Server
   */
  async initAll(configs: McpServerConfig[]): Promise<void> {
    this.servers = [];
    const promises: Promise<void>[] = [];
    for (const cfg of configs) {
      promises.push(this.initServer(cfg));
    }
    await Promise.all(promises);
    const readyCount = this.servers.filter(s => s.ready).length;
    LogUtil.info('[McpClient] initAll done: ' + readyCount + '/' + this.servers.length + ' servers ready');
  }

  /**
   * 获取所有就绪 Server 的远程工具，转换为 OpenAI tools 格式
   */
  getAllRemoteToolsAsOpenAi(): McpToolOpenAi[] {
    const result: McpToolOpenAi[] = [];
    for (const server of this.servers) {
      if (!server.ready) {
        continue;
      }
      for (const tool of server.tools) {
        const fnDef: McpFunctionDef = {
          name: tool.name,
          description: tool.description + ' [via ' + server.config.name + ']',
          parameters: tool.inputSchema
        };
        const openAiTool: McpToolOpenAi = {
          type: 'function',
          function: fnDef
        };
        result.push(openAiTool);
      }
    }
    return result;
  }

  /**
   * 构建 工具名 → server 索引 映射表
   */
  buildToolRouteMap(): Map<string, number> {
    const map = new Map<string, number>();
    for (let i = 0; i < this.servers.length; i++) {
      const server = this.servers[i];
      if (!server.ready) {
        continue;
      }
      for (const tool of server.tools) {
        if (!map.has(tool.name)) {
          map.set(tool.name, i);
        }
      }
    }
    return map;
  }

  /**
   * 调用远程工具
   */
  async callTool(serverIndex: number, toolName: string, argsJson: string): Promise<string> {
    if (serverIndex < 0 || serverIndex >= this.servers.length) {
      return '无效的 server 索引: ' + serverIndex;
    }
    const server = this.servers[serverIndex];
    if (!server.ready) {
      return 'MCP Server 不可用: ' + server.config.name;
    }

    let args: Record<string, Object> = {};
    try {
      args = JSON.parse(argsJson) as Record<string, Object>;
    } catch (e) {
      return '参数解析失败: ' + argsJson;
    }

    try {
      const result = await this.callToolInner(server, toolName, args);
      return result;
    } catch (e) {
      // Session 可能过期，尝试重新初始化
      LogUtil.info('[McpClient] callTool failed, retrying after re-init: ' + server.config.name);
      try {
        await this.initServer(server.config);
        // 重新查找 server（initServer 会 push 新的）
        const newServer = this.servers[this.servers.length - 1];
        if (newServer && newServer.ready) {
          // 更新原位置
          this.servers[serverIndex] = newServer;
          this.servers.pop();
          return await this.callToolInner(this.servers[serverIndex], toolName, args);
        }
      } catch (e2) {
        // 重试也失败
      }
      return '远程工具调用失败: ' + JSON.stringify(e);
    }
  }

  // --------------------------------------------------------
  // 内部实现
  // --------------------------------------------------------

  private async callToolInner(server: McpServerState, toolName: string, args: Record<string, Object>): Promise<string> {
    const body = JSON.stringify({
      jsonrpc: '2.0',
      id: this.nextId(),
      method: 'tools/call',
      params: {
        name: toolName,
        arguments: args
      }
    });

    const responseStr = await this.postJsonRpc(server.config.url, server.sessionId, body);
    const response = this.parseJsonRpcResponse(responseStr);

    if (response.error) {
      return '工具错误: ' + response.error.message;
    }

    if (response.result) {
      const callResult = response.result as Record<string, Object>;
      const content = callResult['content'] as McpContentItem[];
      if (content && content.length > 0) {
        const texts: string[] = [];
        for (const item of content) {
          if (item.text) {
            texts.push(item.text);
          }
        }
        return texts.join('\n');
      }
      return JSON.stringify(response.result);
    }

    return '无返回结果';
  }

  /**
   * 初始化单个 MCP Server：initialize → initialized → tools/list
   */
  private async initServer(config: McpServerConfig): Promise<void> {
    const state: McpServerState = {
      config: config,
      sessionId: '',
      tools: [],
      ready: false,
      error: ''
    };

    try {
      LogUtil.info('[McpClient] Initializing server: ' + config.name + ' at ' + config.url);

      // Step 1: initialize
      const initBody = JSON.stringify({
        jsonrpc: '2.0',
        id: this.nextId(),
        method: 'initialize',
        params: {
          protocolVersion: '2025-03-26',
          capabilities: {},
          clientInfo: {
            name: 'OH-AI-Agent',
            version: '1.0.0'
          }
        }
      });

      const initResult = await this.postJsonRpcWithHeaders(config.url, '', initBody);
      state.sessionId = initResult.sessionId;

      const initResponse = this.parseJsonRpcResponse(initResult.body);
      if (initResponse.error) {
        throw new Error('initialize failed: ' + initResponse.error.message);
      }

      LogUtil.info('[McpClient] Server initialized: ' + config.name + ', sessionId: ' + state.sessionId);

      // Step 2: notifications/initialized
      const notifyBody = JSON.stringify({
        jsonrpc: '2.0',
        method: 'notifications/initialized'
      });
      await this.postJsonRpc(config.url, state.sessionId, notifyBody);

      // Step 3: tools/list
      const toolsBody = JSON.stringify({
        jsonrpc: '2.0',
        id: this.nextId(),
        method: 'tools/list'
      });

      const toolsResponseStr = await this.postJsonRpc(config.url, state.sessionId, toolsBody);
      const toolsResponse = this.parseJsonRpcResponse(toolsResponseStr);

      if (toolsResponse.error) {
        throw new Error('tools/list failed: ' + toolsResponse.error.message);
      }

      if (toolsResponse.result) {
        const toolsResult = toolsResponse.result as Record<string, Object>;
        const tools = toolsResult['tools'] as McpRemoteTool[];
        if (tools) {
          state.tools = tools;
        }
      }

      state.ready = true;
      LogUtil.info('[McpClient] Server ready: ' + config.name + ', tools: ' + state.tools.length);

      for (const tool of state.tools) {
        LogUtil.info('[McpClient]   - ' + tool.name + ': ' + tool.description);
      }

    } catch (e) {
      state.error = JSON.stringify(e);
      state.ready = false;
      LogUtil.error('[McpClient] Failed to init server ' + config.name + ': ' + state.error);
    }

    this.servers.push(state);
  }

  // --------------------------------------------------------
  // HTTP 底层
  // --------------------------------------------------------

  private async postJsonRpc(url: string, sessionId: string, bodyStr: string): Promise<string> {
    const result = await this.postJsonRpcWithHeaders(url, sessionId, bodyStr);
    return result.body;
  }

  private async postJsonRpcWithHeaders(url: string, sessionId: string, bodyStr: string): Promise<PostResult> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream'
    };
    if (sessionId.length > 0) {
      headers['Mcp-Session-Id'] = sessionId;
    }

    LogUtil.info('[McpClient] POST ' + url + ' body: ' + bodyStr.substring(0, 150));

    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: bodyStr,
        readTimeout: 15000,
        connectTimeout: 10000,
        expectDataType: http.HttpDataType.STRING
      });

      const responseBody = (response.result || '') as string;
      const responseHeaders = response.header as Record<string, string>;

      // 提取 Mcp-Session-Id（header key 大小写不确定）
      let extractedSessionId = '';
      if (responseHeaders) {
        for (const key of Object.keys(responseHeaders)) {
          if (key.toLowerCase() === 'mcp-session-id') {
            extractedSessionId = responseHeaders[key];
            break;
          }
        }
      }

      LogUtil.info('[McpClient] Response (' + response.responseCode + '): ' + responseBody.substring(0, 200));

      httpRequest.destroy();
      return { body: responseBody, sessionId: extractedSessionId } as PostResult;
    } catch (e) {
      httpRequest.destroy();
      throw e;
    }
  }

  /**
   * 解析 JSON-RPC 响应，兼容 SSE 格式
   */
  private parseJsonRpcResponse(responseStr: string): McpJsonRpcResponse {
    let jsonStr = responseStr.trim();

    // SSE 兼容：如果响应是 SSE 格式，提取 data: 行
    if (jsonStr.startsWith('data:') || jsonStr.startsWith('event:') || jsonStr.startsWith('id:')) {
      const lines = jsonStr.split('\n');
      for (const line of lines) {
        if (line.startsWith('data:')) {
          const dataContent = line.slice(5).trim();
          if (dataContent.length > 0 && dataContent !== '[DONE]') {
            jsonStr = dataContent;
            break;
          }
        }
      }
    }

    if (jsonStr.length === 0) {
      return { jsonrpc: '2.0' } as McpJsonRpcResponse;
    }

    try {
      return JSON.parse(jsonStr) as McpJsonRpcResponse;
    } catch (e) {
      LogUtil.error('[McpClient] Failed to parse response: ' + jsonStr.substring(0, 200));
      return { jsonrpc: '2.0', error: { code: -1, message: 'JSON parse error' } as McpJsonRpcError } as McpJsonRpcResponse;
    }
  }
}

// postJsonRpcWithHeaders 返回值类型
interface PostResult {
  body: string;
  sessionId: string;
}
