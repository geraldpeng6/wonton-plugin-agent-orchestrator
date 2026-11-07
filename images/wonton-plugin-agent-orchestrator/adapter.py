#!/usr/bin/env python3
"""Agent Orchestrator 的 ACP 适配器：一端对桥说 ACP（stdio），一端驱动容器里的 AO 守护进程（REST + SSE）。

映射：
- 主人的主会话 ↔ AO 的项目编排器会话（首次 session/new 时建项目、起编排器，之后沿用）。
- 编排器派出的每个 worker 会话 ↔ 一个 ACP 会话。新 worker 出现时发 `_wonton/task`（state=working，
  taskSessionId=worker 会话），桥把任务开成话题并 `session/load`；话题里主人的话 `session/prompt` 给 worker。
- worker 的审批 activity → `session/request_permission`（AO 的 decisions 原样当选项，标题带任务名）。
- `user_input` 表单的每个带选项的问题 → 一次 `session/request_permission`，选项之外加“在话题里回答”；
  没有选项的问题在话题里发问，下一条话题消息当回答。
- 状态变化（working/needs_answer/needs_review/blocked/failed/done）走 `_wonton/task`。
- CI、review 的 CDC 事件转成对应任务会话的消息。

只监听容器内 loopback 的 AO REST；不读宿主任何凭据。
"""

import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:" + os.environ.get("AO_PORT", "3001")
PROJECT_DIR = os.environ.get("AO_PROJECT_DIR", "/workspace/repo")
HARNESS = os.environ.get("AO_HARNESS", "qwen")
POLL_SECONDS = 1.0
PROMPT_TIMEOUT = 900.0
PERMISSION_TIMEOUT = 900.0
DONE_QUIET_SECONDS = 3.0

STATE_WORKING = "working"
STATE_NEEDS_ANSWER = "needs_answer"
STATE_NEEDS_REVIEW = "needs_review"
STATE_BLOCKED = "blocked"
STATE_FAILED = "failed"
STATE_DONE = "done"

_stdout = sys.stdout.buffer
_write_lock = threading.Lock()
_rpc_id = 1_000_000_000
_id_lock = threading.Lock()
_responses = {}  # 我们去问桥的请求 id -> {"event": Event, "result": Value}
_tasks = {}  # AO worker 会话 id -> Task
_tasks_lock = threading.Lock()
_main_session = None  # AO 编排器会话 id
_pending_questions = {}
_main_ctx = None  # 主会话的审批/问题也走同一套卡片逻辑（没有 _wonton/task）
last_seen = {"main": 0, "emitted": 0}  # 主会话轮询游标


def log(message):
    print(f"[adapter] {message}", file=sys.stderr, flush=True)


def send(message):
    data = json.dumps(message, ensure_ascii=False).encode()
    with _write_lock:
        _stdout.write(data + b"\n")
        _stdout.flush()


def respond(request_id, result):
    send({"jsonrpc": "2.0", "id": request_id, "result": result})


def respond_error(request_id, code, message):
    send({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def request(method, params, timeout):
    """向桥发请求，等响应；超时返回 None。"""
    global _rpc_id
    with _id_lock:
        _rpc_id += 1
        request_id = _rpc_id
    entry = {"event": threading.Event(), "result": None}
    _responses[str(request_id)] = entry
    send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
    entry["event"].wait(timeout)
    _responses.pop(str(request_id), None)
    return entry["result"]


def update(session_id, text=None, message_id=None, title=None):
    """给会话发一条 agent_message_chunk 更新。"""
    payload = {"sessionId": session_id}
    if message_id:
        payload["messageId"] = message_id
    block = {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text or ""}}
    if title:
        block["content"] = {"type": "text", "text": text or "", "annotations": [{"title": title}]}
    payload["update"] = block
    notify("session/update", payload)


# ---------------------------------------------------------------- HTTP

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


# ---------------------------------------------------------------- AO 引导

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


def bootstrap():
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
        start_sse()
        start_session_thread(_main_session, "main")
        return _main_session


# ---------------------------------------------------------------- 任务

class Task:
    def __init__(self, ao_id):
        self.ao_id = ao_id
        self.title = ""
        self.state = STATE_WORKING
        self.started = time.monotonic()
        self.attached = False
        self.last_sequence = 0
        self.last_activity_seq = 0
        self.pending_perm = {}  # 活动 id -> ACP request id
        self.questions = {}  # 活动 id -> Question
        self.conv_id = ""
        self.emitted = set()  # 已发过的消息 id：流式中间版本会反复出现，只发最终版
        self.done_report = False
        self.finished_seq_noted = False
        self.review_pending = False


def task_for(session_id):
    with _tasks_lock:
        return _tasks.get(session_id)


def set_state(task, state, title=None):
    old = task.state
    task.state = state
    if title:
        task.title = title
    if state != old:
        emit_task(task)


def emit_task(task):
    if not _main_session:
        return
    notify(
        "_wonton/task",
        {
            "sessionId": _main_session,
            "task": {
                "id": task.ao_id,
                "title": task.title or task.ao_id,
                "state": task.state,
                "taskSessionId": task.ao_id,
            },
        },
    )


def describe_worker(session):
    name = (session or {}).get("name") or ""
    if name:
        return name
    return session_id_title(session)


def session_id_title(session):
    return (session or {}).get("id", "")


def ensure_task(session_id):
    task = task_for(session_id)
    if task:
        return task
    session = get_session(session_id)
    title = describe_worker(session) if session else ""
    task = Task(session_id)
    task.title = title or session_id
    with _tasks_lock:
        _tasks[session_id] = task
    emit_task(task)
    return task


# ---------------------------------------------------------------- 事件和轮询

def sse_loop():
    req = urllib.request.Request(
        BASE + "/api/v1/events",
        headers={"Accept": "text/event-stream", "Last-Event-ID": "0"},
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    data_lines = []
    while True:
        try:
            with opener.open(req, timeout=3600) as response:
                for raw in response:
                    line = raw.decode(errors="replace").rstrip("\n")
                    if line.startswith("data: "):
                        data_lines.append(line[6:])
                    elif not line and data_lines:
                        handle_event("\n".join(data_lines))
                        data_lines = []
        except Exception as error:  # 连接断了重连，Last-Event-ID 由服务端续
            log(f"事件流断开：{error}")
            time.sleep(2)
            req = urllib.request.Request(
                BASE + "/api/v1/events", headers={"Accept": "text/event-stream"}
            )


def start_sse():
    threading.Thread(target=sse_loop, daemon=True).start()


def handle_event(raw):
    try:
        event = json.loads(raw)
    except ValueError:
        return
    kind = event.get("type", "")
    session_id = event.get("sessionId", "")
    payload = event.get("payload") or {}
    if kind == "session_created" and session_id:
        session = get_session(session_id)
        if session and session.get("kind") == "worker":
            task = ensure_task(session_id)
            if not task.attached:
                start_session_thread(session_id, "task")
    elif kind in ("pr_created", "pr_updated", "pr_check_recorded",
                  "pr_review_thread_added", "pr_review_thread_resolved") and session_id:
        text = describe_pr_event(kind, payload)
        if text:
            task = task_for(session_id)
            if task:
                update(task.ao_id, text=text + "\n")
    elif kind in ("review_run_created", "review_run_updated") and session_id:
        task = task_for(session_id)
        if task:
            task.review_pending = kind == "review_run_created"
            set_state(task, STATE_NEEDS_REVIEW if task.review_pending else task.state)


def describe_pr_event(kind, payload):
    labels = {
        "pr_created": "开了 PR",
        "pr_updated": "PR 有更新",
        "pr_check_recorded": "CI 结果",
        "pr_review_thread_added": "review 提了意见",
        "pr_review_thread_resolved": "review 意见已解决",
    }
    label = labels.get(kind)
    if not label:
        return ""
    detail = payload.get("summary") or payload.get("name") or payload.get("status") or ""
    url = payload.get("url") or (payload.get("pr") or {}).get("url") or ""
    parts = [f"〔{label}〕"]
    if detail:
        parts.append(str(detail))
    if url:
        parts.append(str(url))
    return " ".join(parts)


def start_session_thread(session_id, role):
    threading.Thread(
        target=session_loop, args=(session_id, role), daemon=True, name=f"poll-{session_id}"
    ).start()


def session_loop(session_id, role):
    task = task_for(session_id) if role == "task" else None
    while True:
        time.sleep(POLL_SECONDS)
        try:
            if role == "main":
                poll_main()
            elif task:
                if not poll_task(task):
                    return
        except Exception as error:
            log(f"轮询 {session_id} 失败：{error}")


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


def emit_message(ctx, session_id, message):
    """流式消息只在落定时发一次；中间快照跳过后面的最终版会补上。"""
    if message.get("streaming"):
        return
    message_id = message.get("id")
    if message_id and message_id in ctx.emitted:
        return
    if message_id:
        ctx.emitted.add(message_id)
    update(session_id, text=message.get("text") or "", message_id=message_id)


def _newest_seq(messages, activities):
    return max([item.get("sequence", 0) for item in list(messages) + list(activities)] + [0])


def poll_main():
    global _main_ctx
    if _main_ctx is None:
        _main_ctx = Task(_main_session)
        _main_ctx.title = ""
    conv_id, messages, activities = fetch_conversation(_main_session, last_seen["main"])
    if conv_id and conv_id != _main_ctx.conv_id:
        # 会话被重开（新 conversationId）：游标全部归零，旧会话里没答的卡片作废。
        _main_ctx.conv_id = conv_id
        last_seen["main"] = 0
        last_seen["emitted"] = 0
        _main_ctx.last_activity_seq = 0
        _main_ctx.questions.clear()
        _main_ctx.pending_perm.clear()
    last_seen["main"] = max(last_seen["main"], _newest_seq(messages, activities))
    for activity in activities:
        seq = activity.get("sequence", 0)
        if seq <= _main_ctx.last_activity_seq:
            continue
        _main_ctx.last_activity_seq = seq
        if activity.get("status") == "pending":
            handle_pending_activity(_main_ctx, activity)
    for message in messages:
        seq = message.get("sequence", 0)
        if seq <= last_seen["emitted"]:
            continue
        if message.get("streaming"):
            break  # 等这条落定再往前走游标
        last_seen["emitted"] = seq
        if message.get("role") == "assistant":
            emit_message(_main_ctx, _main_session, message)
        elif message.get("role") == "user":
            # 报告可能单独成一条 automation 消息，也可能挂在下一条人话前，两种都认。
            route_reports(message.get("text") or "")


def route_reports(text):
    pattern = r"\[(done|needs-input|stuck|checkpoint)\]\s+\[(.*?)\]\(ao://sessions/(?:[^/)]+/)?([^)]+)\)"
    for match in re.finditer(pattern, text):
        kind, name, worker = match.group(1), match.group(2), match.group(3)
        task = ensure_task(worker)
        if name and name != task.title:
            task.title = name
            emit_task(task)
        note = text[match.end():].strip()
        update(task.ao_id, text=(note or f"({kind})\n"))
        task.done_report = kind == "done"
        set_state(
            task,
            {
                "done": STATE_DONE,
                "needs-input": STATE_NEEDS_ANSWER,
                "stuck": STATE_BLOCKED,
                "checkpoint": STATE_WORKING,
            }[kind],
        )


def poll_task(task):
    session = get_session(task.ao_id)
    if not session:
        return False
    conv_id, messages, activities = fetch_conversation(task.ao_id, task.last_sequence)
    if conv_id and conv_id != task.conv_id:
        task.conv_id = conv_id
        task.last_sequence = 0
        task.last_activity_seq = 0
        task.questions.clear()
        task.pending_perm.clear()
    for message in messages:
        seq = message.get("sequence", 0)
        if seq <= task.last_sequence:
            continue
        if message.get("streaming"):
            break
        task.last_sequence = seq
        if not task.attached:
            continue
        if message.get("role") == "assistant":
            emit_message(task, task.ao_id, message)
    for activity in activities:
        seq = activity.get("sequence", 0)
        if seq <= task.last_activity_seq:
            continue
        task.last_activity_seq = seq
        if activity.get("status") == "pending":
            handle_pending_activity(task, activity)
    derive_task_state(task, session)
    if session.get("isTerminated") and not task.finished_seq_noted:
        task.finished_seq_noted = True
        set_state(task, STATE_DONE if task.done_report else STATE_FAILED)
    return True


def handle_pending_activity(task, activity):
    kind = activity.get("activityKind")
    activity_id = activity.get("id")
    if not activity_id:
        return
    if kind == "approval" and activity_id not in task.pending_perm:
        task.pending_perm[activity_id] = None
        threading.Thread(
            target=ask_permission, args=(task, activity), daemon=True
        ).start()
    elif kind == "user_input" and activity_id not in task.questions:
        specs = question_specs(activity)
        question = Question(task, activity, [key for key, _t, _o in specs])
        task.questions[activity_id] = question
        threading.Thread(
            target=ask_questions, args=(task, activity, question), daemon=True
        ).start()


def derive_task_state(task, session):
    if task.state in (STATE_DONE, STATE_FAILED):
        return
    if task.questions:
        set_state(task, STATE_NEEDS_ANSWER)
    elif task.pending_perm:
        set_state(task, STATE_NEEDS_ANSWER)
    elif task.review_pending:
        set_state(task, STATE_NEEDS_REVIEW)
    elif (session.get("activity") or {}).get("state") == "active":
        set_state(task, STATE_WORKING)
    elif task.done_report:
        set_state(task, STATE_DONE)


# ---------------------------------------------------------------- 审批和问题

def tool_kind(activity):
    mapping = {"command": "execute", "file_change": "edit", "edit": "edit"}
    return mapping.get(activity.get("activityKind"), "other")


def permission_title(task, activity):
    summary = activity.get("summary") or activity.get("activityKind") or "执行动作"
    prefix = f"「{task.title}」" if task.title else ""
    return f"{prefix}想{summary}" if prefix else summary


def ask_permission(task, activity):
    try:
        return _ask_permission(task, activity)
    except Exception as error:
        log(f"审批卡片失败：{error}")


def _ask_permission(task, activity):
    activity_id = activity.get("id")
    decisions = (activity.get("detail") or {}).get("decisions") or []
    options = []
    for decision in decisions:
        options.append(
            {
                "optionId": decision["id"],
                "name": decision["label"],
                "kind": decision.get("kind", "allow_once"),
            }
        )
    if not options:
        options = [{"optionId": "proceed_once", "name": "允许", "kind": "allow_once"}]
    result = request(
        "session/request_permission",
        {
            "sessionId": task.ao_id,
            "toolCall": {
                "toolCallId": activity_id,
                "title": permission_title(task, activity),
                "kind": tool_kind(activity),
                "rawInput": (activity.get("detail") or {}).get("input") or {},
            },
            "options": options,
        },
        PERMISSION_TIMEOUT,
    )
    outcome = ((result or {}).get("outcome") or {}).get("outcome")
    if outcome == "selected":
        decision = ((result or {}).get("outcome") or {}).get("optionId")
    else:
        decision = "cancel"
    key = request_key(activity) or activity_id
    status, body = http(
        "POST",
        f"/api/v1/sessions/{task.ao_id}/conversation/approvals/{encode(key)}/resolve",
        {"decisionId": decision},
    )
    if status not in (200, 202, 204):
        log(f"回答审批失败：HTTP {status} {body}")
    task.pending_perm.pop(activity_id, None)


class Question:
    def __init__(self, task, activity, keys):
        self.task = task
        self.activity = activity
        self.keys = keys  # 待回答的问题键，按 schema 顺序
        self.answers = {}
        self.awaiting = None  # 选了“在话题里回答”的键

    def complete(self):
        return len(self.answers) == len(self.keys)


def question_specs(activity):
    schema = (activity.get("detail") or {}).get("schema") or {}
    props = schema.get("properties") or {}
    specs = []
    for key, spec in props.items():
        if not isinstance(spec, dict):
            continue
        # qwen 给每个问题带一个 “Other” 自由文本字段（question_0_custom），不单独成卡片。
        if key.endswith("_custom") and key[: -len("_custom")] in props:
            continue
        choices = spec.get("oneOf") or spec.get("anyOf") or []
        options = [
            {
                "optionId": str(choice.get("const")),
                "name": choice.get("title") or str(choice.get("const")),
                "kind": "allow_once",
            }
            for choice in choices
            if "const" in choice
        ]
        specs.append((key, spec.get("title") or key, options))
    return specs


def ask_questions(task, activity, question):
    try:
        return _ask_questions(task, activity, question)
    except Exception as error:
        log(f"问题卡片失败：{error}")


def _ask_questions(task, activity, question):
    activity_id = activity.get("id")
    for key, title, options in question_specs(activity):
        if options:
            options = options + [
                {"optionId": "__topic", "name": "在话题里回答", "kind": "allow_once"}
            ]
            result = request(
                "session/request_permission",
                {
                    "sessionId": task.ao_id,
                    "toolCall": {
                        "toolCallId": f"{activity_id}:{key}",
                        "title": (f"「{task.title}」{title}" if task.title else title),
                        "kind": "other",
                        "rawInput": {},
                    },
                    "options": options,
                },
                PERMISSION_TIMEOUT,
            )
            outcome = ((result or {}).get("outcome") or {}).get("outcome")
            picked = ((result or {}).get("outcome") or {}).get("optionId")
            if outcome != "selected" or not picked:
                resolve_question(task, activity_id, question, "cancel")
                return
            if picked == "__topic":
                question.awaiting = key
                log(f"问题 {activity_id} 改在话题里回答：{title}")
                update(task.ao_id, text=f"请在这里回答：{title}\n")
                continue
            question.answers[key] = resolve_choice_value(picked)
        else:
            question.awaiting = key
            update(task.ao_id, text=f"请在这里回答：{title}\n")
        if not question.complete():
            continue
    log(f"问题 {activity_id}：{len(question.answers)}/{len(question.keys)} 已答")
    if question.complete() and not question.awaiting:
        resolve_question(task, activity_id, question, "accept")


def resolve_choice_value(picked):
    return picked


def request_key(activity):
    return activity.get("requestId") or activity.get("providerItemId") or activity.get("id")


def resolve_question(task, activity_id, question, action, content=None):
    key = request_key(question.activity) or activity_id
    status, body = http(
        "POST",
        f"/api/v1/sessions/{task.ao_id}/conversation/inputs/{encode(key)}/resolve",
        {"action": action, "content": content or question.answers},
    )
    if status not in (200, 202, 204):
        log(f"回答问题失败：HTTP {status} {body}")
    task.questions.pop(activity_id, None)


def take_text_answer(task, text):
    """话题里的一行话：如果它在等信息回答，先当回答填进当前问题。返回是否用掉了。"""
    log(f"文本答题：{len(task.questions)} 个问题在等")
    for activity_id, question in list(task.questions.items()):
        if not question.awaiting:
            continue
        question.answers[question.awaiting] = text
        question.awaiting = None
        for key in list(question.keys):
            if key in question.answers:
                continue
            break
        if question.complete():
            resolve_question(task, activity_id, question, "accept")
        return True
    return False


def encode(value):
    return urllib.parse.quote(str(value), safe="")


# ---------------------------------------------------------------- JSON-RPC

def on_prompt(message):
    session_id = message["params"]["sessionId"]
    text = "".join(
        block.get("text", "")
        for block in message["params"]["prompt"]
        if isinstance(block, dict)
    )
    threading.Thread(
        target=run_prompt, args=(message.get("id"), session_id, text), daemon=True
    ).start()


def run_prompt(request_id, session_id, text):
    task = task_for(session_id)
    ctx = task or (_main_ctx if session_id == _main_session else None)
    if ctx and take_text_answer(ctx, text):
        respond(request_id, {"stopReason": "end_turn"})
        return
    before = 0
    session = get_session(session_id)
    if session is None:
        respond_error(request_id, -32002, "会话不存在")
        return
    try:
        send_message(session_id, text)
    except RuntimeError:
        ensure_agent_running(session_id)
        send_message(session_id, text)
    deadline = time.monotonic() + PROMPT_TIMEOUT
    stop = "end_turn"
    while time.monotonic() < deadline:
        time.sleep(0.5)
        session = get_session(session_id)
        if not session:
            stop = "end_turn"
            break
        state = (session.get("activity") or {}).get("state")
        if state in ("idle", "exited"):
            break
        if state == "blocked" and time.monotonic() + 2 > deadline:
            break
    respond(request_id, {"stopReason": stop})


def handle(message):
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}
    if method is None:
        if request_id:
            entry = _responses.get(str(request_id))
            if entry:
                entry["result"] = message.get("result")
                entry["event"].set()
        return
    if method == "initialize":
        respond(
            request_id,
            {
                "protocolVersion": 1,
                "agentCapabilities": {
                    "loadSession": True,
                    "mcpCapabilities": {"http": {}},
                    "sessionCapabilities": {"close": {}},
                },
                "agentInfo": {
                    "name": "wonton-agent-orchestrator",
                    "title": "Agent Orchestrator",
                    "version": os.environ.get("AO_VERSION", "0.14.10"),
                },
            },
        )
    elif method == "session/new":
        threading.Thread(target=new_session, args=(request_id,), daemon=True).start()
    elif method in ("session/load", "session/resume"):
        threading.Thread(
            target=load_session,
            args=(request_id, params.get("sessionId"), method == "session/load"),
            daemon=True,
        ).start()
    elif method == "session/prompt":
        on_prompt(message)
    elif method == "session/cancel":
        session_id = params.get("sessionId")
        http("POST", f"/api/v1/sessions/{session_id}/conversation/interrupt")
    elif method == "session/close":
        close(params.get("sessionId"))
        respond(request_id, {})
    elif method == "$/cancel_request":
        cancel_request(str(params.get("requestId")))
    else:
        if request_id:
            respond_error(request_id, -32601, "方法未实现")


def cancel_request(request_id):
    entry = _responses.get(str(request_id))
    if entry:
        entry["result"] = {"outcome": {"outcome": "cancelled"}}
        entry["event"].set()


def new_session(request_id):
    try:
        main = bootstrap()
        respond(request_id, {"sessionId": main})
    except Exception as error:
        log(f"建会话失败：{error}")
        respond_error(request_id, -32000, str(error))


def load_session(request_id, session_id, replay):
    try:
        if not _main_session:
            bootstrap()
        attach(session_id, replay)
        respond(request_id, {})
    except Exception as error:
        log(f"恢复会话失败：{error}")
        respond_error(request_id, -32000, str(error))


def attach(session_id, replay):
    task = task_for(session_id)
    if not task:
        return
    task.attached = True
    if replay:
        status, body = http(
            "GET", f"/api/v1/sessions/{session_id}/conversation?limit=200"
        )
        if status == 200 and body:
            for message in body.get("messages") or []:
                if message.get("role") == "assistant":
                    emit_message(task, session_id, message)
            newest = max([m.get("sequence", 0) for m in body.get("messages") or []] + [0])
            task.last_sequence = max(task.last_sequence, newest)
            # 活动从头扫一遍：还挂着的审批和问题要在这个会话里重新弹出来。
            task.last_activity_seq = 0
    if not getattr(task, "thread_started", False):
        task.thread_started = True
        start_session_thread(session_id, "task")


def close(session_id):
    task = task_for(session_id)
    if task:
        task.attached = False


def main():
    for line in sys.stdin.buffer:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        try:
            handle(message)
        except Exception as error:
            log(f"处理 {message.get('method')} 失败：{error}")
            if message.get("id"):
                respond_error(message["id"], -32603, str(error))


if __name__ == "__main__":
    main()
