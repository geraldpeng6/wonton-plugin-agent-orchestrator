#!/usr/bin/env python3
"""Agent Orchestrator 的 ACP 适配器：一端对桥说 ACP（stdio），一端驱动容器里的 AO 守护进程。

映射：
- 主人的主会话 ↔ AO 的项目编排器会话（首次 session/new 时建项目、起编排器，之后沿用）。
- 编排器派出的每个 worker 会话 ↔ 一个 ACP 会话。新 worker 出现时发 `_wonton/task`，
  话题里主人的话 `session/prompt` 给它。
- worker 和编排器的审批、问题都经 approvals.py 变成卡片；状态变化走 `_wonton/task`；
  CI、review 的 CDC 事件转成对应任务会话的消息。
"""
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request

import ao
import approvals
from ao import fetch_conversation, get_session, http, send_message
from transport import (
    cancel as transport_cancel,
    log,
    notify,
    request,
    respond,
    respond_error,
    settle as transport_settle,
    update,
)

PROJECT_DIR = ao.PROJECT_DIR
HARNESS = ao.HARNESS
POLL_SECONDS = 1.0
PROMPT_TIMEOUT = 900.0

STATE_WORKING = "working"
STATE_NEEDS_ANSWER = "needs_answer"
STATE_NEEDS_REVIEW = "needs_review"
STATE_BLOCKED = "blocked"
STATE_FAILED = "failed"
STATE_DONE = "done"

_tasks = {}
_tasks_lock = threading.Lock()
_main_ctx = None
last_seen = {"main": 0, "emitted": 0}


def main_session():
    return ao.main_session()


def start_main_poll(session_id):
    start_sse()
    start_session_thread(session_id, "main")



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
    if not main_session():
        return
    notify(
        "_wonton/task",
        {
            "sessionId": main_session(),
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


def sse_loop():
    req = urllib.request.Request(
        ao.BASE + "/api/v1/events",
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
                ao.BASE + "/api/v1/events", headers={"Accept": "text/event-stream"}
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
        _main_ctx = Task(main_session())
        _main_ctx.title = ""
    conv_id, messages, activities = fetch_conversation(main_session(), last_seen["main"])
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
            emit_message(_main_ctx, main_session(), message)
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
        report_state_from_worker(task, activity)
    derive_task_state(task, session)
    if session.get("isTerminated") and not task.finished_seq_noted:
        task.finished_seq_noted = True
        set_state(task, STATE_DONE if task.done_report else STATE_FAILED)
    return True


def report_state_from_worker(task, activity):
    """worker 自己跑 `ao report --done/--needs-input/--stuck` 时直接改状态：
    编排器闲着时也不用等它的下一轮。"""
    if activity.get("activityKind") != "command" or activity.get("status") != "completed":
        return
    summary = activity.get("summary") or ""
    mapping = {
        "report --done": STATE_DONE,
        "report --needs-input": STATE_NEEDS_ANSWER,
        "report --stuck": STATE_BLOCKED,
    }
    for needle, state in mapping.items():
        if needle in summary:
            if state == STATE_DONE:
                task.done_report = True
            set_state(task, state)
            return


def handle_pending_activity(task, activity):
    kind = activity.get("activityKind")
    activity_id = activity.get("id")
    if not activity_id:
        return
    if kind == "approval" and activity_id not in task.pending_perm:
        task.pending_perm[activity_id] = None
        threading.Thread(
            target=approvals.ask_permission, args=(task, activity), daemon=True
        ).start()
    elif kind == "user_input" and activity_id not in task.questions:
        specs = approvals.question_specs(activity)
        question = approvals.Question(task, activity, [key for key, _t, _o in specs])
        task.questions[activity_id] = question
        threading.Thread(
            target=approvals.ask_questions, args=(task, activity, question), daemon=True
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
    ctx = task or (_main_ctx if session_id == main_session() else None)
    if ctx and approvals.take_text_answer(ctx, text):
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
            transport_settle(message, request_id)
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
        transport_cancel(params.get("requestId"))
    else:
        if request_id:
            respond_error(request_id, -32601, "方法未实现")


def cancel_request(request_id):
    transport_cancel(request_id)


def new_session(request_id):
    try:
        main = ao.bootstrap(start_main_poll)
        respond(request_id, {"sessionId": main})
    except Exception as error:
        log(f"建会话失败：{error}")
        respond_error(request_id, -32000, str(error))


def load_session(request_id, session_id, replay):
    try:
        if not main_session():
            ao.bootstrap(start_main_poll)
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


if __name__ == "__main__":
    main()
