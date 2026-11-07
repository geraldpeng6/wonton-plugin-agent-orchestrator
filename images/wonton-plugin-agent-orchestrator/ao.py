#!/usr/bin/env python3
"""AO 守护进程的 REST 客户端和启动引导（项目、仓库、编排器会话）。"""
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import threading

from transport import log, update

BASE = "http://127.0.0.1:" + os.environ.get("AO_PORT", "3001")
PROJECT_DIR = os.environ.get("AO_PROJECT_DIR", "/workspace/repo")
HARNESS = os.environ.get("AO_HARNESS", "qwen")
_main_session = None
_bootstrap_lock = threading.Lock()


def main_session():
    return _main_session


def http(method, path, body=None, timeout=20):
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            payload = json.loads(raw) if raw else None
        except ValueError:
            payload = raw.decode(errors="replace")
        return error.code, payload


def get_session(session_id):
    status, body = http("GET", f"/api/v1/sessions/{session_id}")
    if status != 200 or not body:
        return None
    return body.get("session")


def ensure_agent_running(session_id):
    """容器重启、桥重连后会话可能是 exited：让守护进程把 agent 进程拉回来再发话。"""
    for _ in range(60):
        session = get_session(session_id)
        if session is None:
            return
        state = (session.get("activity") or {}).get("state")
        if state not in ("exited", "idle") or session.get("isTerminated"):
            return
        http("POST", f"/api/v1/sessions/{session_id}/resume-agent")
        time.sleep(1)
        session = get_session(session_id)
        if session and (session.get("activity") or {}).get("state") not in ("exited",):
            return


def send_message(session_id, text):
    status, body = http(
        "POST",
        f"/api/v1/sessions/{session_id}/conversation/messages",
        {"text": text},
    )
    if status not in (200, 202):
        raise RuntimeError(f"发送消息失败：HTTP {status} {body}")


def ensure_daemon():
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        status, _ = http("GET", "/healthz", timeout=2)
        if status == 200:
            return
        time.sleep(0.5)
    raise RuntimeError("AO 守护进程 90 秒内没就绪")


def ensure_project():
    status, body = http("GET", "/api/v1/projects")
    projects = (body or {}).get("projects", []) if isinstance(body, dict) else []
    for project in projects:
        if project.get("path") == PROJECT_DIR:
            return project.get("id")
    status, body = http(
        "POST",
        "/api/v1/projects",
        {"path": PROJECT_DIR, "name": "wonton"},
    )
    if status not in (200, 201) or not body:
        raise RuntimeError(f"建项目失败：HTTP {status} {body}")
    return body["project"]["id"]


def configure_project(project_id):
    # 模型网关变量给每个会话显式带上：AO 不把守护进程环境透传给 Agent 进程。
    # 项目 env 大小写不敏感、两种写法算重名，代理变量优先取小写（undici 只认小写）。
    env = {}
    for key in ("openai_base_url", "openai_api_key", "openai_model",
                "https_proxy", "http_proxy", "no_proxy"):
        value = os.environ.get(key) or os.environ.get(key.upper())
        if value:
            env[key if key.startswith(("openai", "https", "http", "no_")) else key] = value
    http(
        "PUT",
        f"/api/v1/projects/{project_id}/config",
        {
            "config": {
                "defaultBranch": "main",
                "orchestrator": {"agent": HARNESS},
                "worker": {"agent": HARNESS},
                "env": env,
            }
        },
    )


def ensure_repo():
    if os.path.isdir(os.path.join(PROJECT_DIR, ".git")):
        return
    os.makedirs(PROJECT_DIR, exist_ok=True)
    run = lambda *args: os.system("git -C %s %s >/dev/null 2>&1" % (PROJECT_DIR, " ".join(args)))
    run("init", "-q", "-b", "main")
    run("config", "user.name", "wonton")
    run("config", "user.email", "wonton@127.0.0.1")
    with open(os.path.join(PROJECT_DIR, "README.md"), "w") as file:
        file.write("# 工作区\n\n编排器的工人在分支上改这个仓库，完成的改动合回 main。\n")
    run("add", "-A")
    run("commit", "-qm", "init")


def ensure_orchestrator(project_id):
    status, body = http("GET", "/api/v1/orchestrators")
    sessions = (body or {}).get("sessions", []) if isinstance(body, dict) else []
    for session in sessions:
        if session.get("projectId") == project_id and not session.get("isTerminated"):
            if session.get("provisionState") != "failed":
                return session["id"]
    status, body = http(
        "POST",
        "/api/v1/orchestrators",
        {"projectId": project_id, "mode": "chat", "approvalMode": "default", "clean": True},
        timeout=60,
    )
    if status not in (200, 201) or not body:
        raise RuntimeError(f"启动编排器失败：HTTP {status} {body}")
    return body["orchestrator"]["id"]


_bootstrap_lock = threading.Lock()


def bootstrap(on_ready):
    """确保守护进程、仓库、项目和编排器都在；返回编排器会话 id。"""
    global _main_session
    with _bootstrap_lock:
        if _main_session:
            return _main_session
        ensure_daemon()
        ensure_repo()
        project_id = ensure_project()
        configure_project(project_id)
        _main_session = ensure_orchestrator(project_id)
        ensure_agent_running(_main_session)
        log(f"主会话是编排器 {_main_session}")
        on_ready(_main_session)
        return _main_session


def fetch_conversation(session_id, after):
    status, body = http(
        "GET",
        f"/api/v1/sessions/{session_id}/conversation?beforeSequence={after + 501}&limit=500",
    )
    if status != 200 or not body:
        return "", [], []
    messages = sorted(body.get("messages") or [], key=lambda item: item.get("sequence", 0))
    activities = sorted(body.get("activities") or [], key=lambda item: item.get("sequence", 0))
    return body.get("conversationId") or "", messages, activities
