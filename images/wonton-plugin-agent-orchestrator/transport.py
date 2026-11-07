#!/usr/bin/env python3
"""ACP 的 stdio 传输：读写、请求 id、等应答、发通知。由 adapter 和 approvals 共用。"""
import json
import sys
import threading

stdout = sys.stdout.buffer
write_lock = threading.Lock()
_rpc_id = 1_000_000_000
_id_lock = threading.Lock()
responses = {}  # 我们去问桥的请求 id -> {"event", "result"}


def log(message):
    print(f"[adapter] {message}", file=sys.stderr, flush=True)


def send(message):
    data = json.dumps(message, ensure_ascii=False).encode()
    with write_lock:
        stdout.write(data + b"\n")
        stdout.flush()


def respond(request_id, result):
    send({"jsonrpc": "2.0", "id": request_id, "result": result})


def respond_error(request_id, code, message):
    send({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def request(method, params, timeout):
    """向桥发请求（整数 id，桥只按 u64 匹配应答），等响应；超时返回 None。"""
    global _rpc_id
    with _id_lock:
        _rpc_id += 1
        request_id = _rpc_id
    entry = {"event": threading.Event(), "result": None}
    responses[str(request_id)] = entry
    send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
    entry["event"].wait(timeout)
    responses.pop(str(request_id), None)
    return entry["result"]


def settle(message, request_id):
    entry = responses.get(str(request_id))
    if entry:
        entry["result"] = message.get("result")
        entry["event"].set()


def cancel(request_id):
    entry = responses.get(str(request_id))
    if entry:
        entry["result"] = {"outcome": {"outcome": "cancelled"}}
        entry["event"].set()


def update(session_id, text=None, message_id=None):
    """给会话发一条 agent_message_chunk 更新。"""
    payload = {"sessionId": session_id, "update": {
        "sessionUpdate": "agent_message_chunk",
        "content": {"type": "text", "text": text or ""},
    }}
    if message_id:
        payload["messageId"] = message_id
    notify("session/update", payload)
