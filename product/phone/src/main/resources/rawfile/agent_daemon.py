"""
Agent Daemon - runs as persistent subprocess, communicates via stdin/stdout JSON lines.

Protocol:
  - Each message is one JSON object per line (JSON Lines)
  - stdin: receives requests from ArkTS
  - stdout: sends responses/tool_calls back to ArkTS

Request format:
  {"type": "chat", "message": "user's question"}
  {"type": "tool_result", "tool": "camera", "result": {"path": "/xxx/photo.jpg"}}
  {"type": "ping"}
  {"type": "shutdown"}

Response format:
  {"type": "ready"}
  {"type": "response", "content": "LLM's answer"}
  {"type": "tool_call", "tool": "camera", "params": {}}
  {"type": "pong"}
  {"type": "error", "message": "..."}
"""

import sys
import json

def send(obj):
    """Send a JSON object to ArkTS (via stdout)"""
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + '\n')
    sys.stdout.flush()

def recv():
    """Receive a JSON object from ArkTS (via stdin), blocking"""
    line = sys.stdin.readline()
    if not line:
        return None  # EOF, parent closed pipe
    return json.loads(line.strip())

def handle_chat(message):
    """Handle a chat message - for now just echo back, later integrate LangChain"""
    # Simple demo: echo back with prefix
    send({
        "type": "response",
        "content": f"[Python Agent] You said: {message}"
    })

def handle_chat_with_tools(message):
    """
    Demo: if user says anything about 'camera' or 'photo' or '拍照',
    request a tool call instead of answering directly.
    """
    keywords = ['camera', 'photo', '拍照', '拍个照', '摄像头', 'picture', 'capture']
    if any(k in message.lower() for k in keywords):
        # Request ArkTS to take a photo
        send({
            "type": "tool_call",
            "tool": "camera",
            "params": {"action": "capture"}
        })
        # Wait for tool result
        result = recv()
        if result and result.get('type') == 'tool_result':
            tool_data = result.get('result', {})
            send({
                "type": "response",
                "content": f"[Python Agent] Photo captured! Path: {tool_data.get('path', 'unknown')}"
            })
        else:
            send({
                "type": "response",
                "content": "[Python Agent] Tool call failed or unexpected response"
            })
    else:
        # Normal response
        send({
            "type": "response",
            "content": f"[Python Agent] Echo: {message}"
        })

def main():
    # Signal ready
    send({"type": "ready", "python_version": sys.version.split()[0]})

    while True:
        try:
            msg = recv()
            if msg is None:
                break  # stdin closed

            msg_type = msg.get('type', '')

            if msg_type == 'ping':
                send({"type": "pong"})

            elif msg_type == 'chat':
                handle_chat_with_tools(msg.get('message', ''))

            elif msg_type == 'shutdown':
                send({"type": "shutdown_ack"})
                break

            else:
                send({"type": "error", "message": f"unknown type: {msg_type}"})

        except json.JSONDecodeError as e:
            send({"type": "error", "message": f"JSON parse error: {str(e)}"})
        except Exception as e:
            send({"type": "error", "message": f"exception: {str(e)}"})

if __name__ == '__main__':
    main()
