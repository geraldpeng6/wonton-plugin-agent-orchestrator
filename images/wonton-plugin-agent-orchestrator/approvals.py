#!/usr/bin/env python3
"""审批和 user_input 表单 → ACP request_permission 卡片。"""
import urllib.parse

from ao import http
from transport import log, request, update

PERMISSION_TIMEOUT = 900.0


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


def encode(value):
    return urllib.parse.quote(str(value), safe="")
