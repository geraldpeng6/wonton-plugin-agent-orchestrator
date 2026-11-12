"""插件设置值：把命令行的 名字=值 按预览里的设置表单换成核心要的类型，编码成上传请求头 Wonton-Plugin-Settings。

  plugin_settings.py header <预览 JSON 文件> [--base <值 JSON 文件>] [--old <说明>] [名字=值 …]
      标准输出是请求头的值（base64url 无填充的 JSON），没有值时为空。--base 是先叠上的值（如重装前读到的），
      命令行的值盖过它，同名的后给的算数。--old 用于装旧版本：旧版本没有的设置不带，在标准错误说明；不给 --old 时没有的设置直接报错。
      必填又没有默认值、也没给值的设置报错，说清用 --setting 补上。
  plugin_settings.py current <设置页 JSON 文件>
      标准输出是设置页里存着的值（JSON 对象，名字到值），没存过的项不出现。
  plugin_settings.py verify <设置页 JSON 文件> <请求头的值>
      核对请求头里的每个值都存下了；有不一样的退出码 1。
"""

import base64
import json
import re
import sys


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def parse_pairs(pairs):
    values = {}
    for pair in pairs:
        name, sep, value = pair.partition("=")
        if not sep or not name:
            fail(f"--setting 要写成 名字=值：{pair}")
        # 同名时后给的算数：冒烟先放探针声明的值，再放命令行的。
        values[name] = value
    return values


def option_value(field, text):
    options = [option["value"] for option in field["kind"].get("options", [])]
    shown = [json.dumps(value.get("value"), ensure_ascii=False).strip('"') for value in options]
    for value, written in zip(options, shown):
        if written == text:
            return value
    choices = "、".join(shown)
    fail(f"设置 {field['name']} 只能取这些值：{choices}；给的是 {text}")


def typed(field, text):
    """按控件类型把文本换成核心的设置值。"""
    kind = field["kind"]
    name = field["name"]
    match kind["type"]:
        case "toggle":
            lowered = text.lower()
            if lowered not in ("true", "false"):
                fail(f"设置 {name} 是开关，要写 true 或 false；给的是 {text}")
            return {"type": "flag", "value": lowered == "true"}
        case "integer":
            if not re.fullmatch(r"-?[0-9]+", text):
                fail(f"设置 {name} 要整数；给的是 {text}")
            return {"type": "integer", "value": int(text)}
        case "decimal":
            if not re.fullmatch(r"-?[0-9]+(\.[0-9]+)?", text):
                fail(f"设置 {name} 要十进制小数，如 1.5；给的是 {text}")
            return {"type": "decimal", "value": text}
        case "text":
            return {"type": "text", "value": text}
        case "choice" if kind.get("multiple"):
            items = [item.strip() for item in text.split(",") if item.strip()]
            for item in items:
                option_value(field, item)
            return {"type": "texts", "value": items}
        case "choice":
            return option_value(field, text)
        case other:
            fail(f"设置 {name} 是这份开发套件不认识的控件（{other}）：先 scripts/dev.sh kit-update")


def header(args):
    preview_file, rest = args[0], args[1:]
    base_file = old = None
    while rest and rest[0] in ("--base", "--old"):
        if len(rest) < 2:
            fail(f"{rest[0]} 后面要跟值")
        if rest[0] == "--base":
            base_file = rest[1]
        else:
            old = rest[1]
        rest = rest[2:]
    given = parse_pairs(rest)
    with open(preview_file, encoding="utf-8") as f:
        preview = json.load(f)
    fields = {field["name"]: field for field in (preview.get("settings") or {}).get("fields", [])}
    values = {}
    if base_file:
        with open(base_file, encoding="utf-8") as f:
            for name, value in json.load(f).items():
                if name in fields:
                    values[name] = value
                else:
                    print(f"新包没有设置 {name}，原来的值不带", file=sys.stderr)
    for name, text in given.items():
        if name in fields:
            values[name] = typed(fields[name], text)
        elif old is not None:
            print(f"{old}没有设置 {name}，装它时不带", file=sys.stderr)
        elif not fields:
            fail(f"这个插件没有设置项，--setting {name} 用不上")
        else:
            fail(f"这个插件没有设置 {name}；有的是：{'、'.join(fields)}")
    missing = [
        name
        for name, field in fields.items()
        if field.get("required") and name not in values and field.get("value") is None and field.get("default") is None
    ]
    if missing:
        fail("必填的设置没有值：" + "、".join(missing) + "；用 --setting 名字=值 给上（冒烟时写进 scripts/smoke-probes.sh 的 SMOKE_SETTINGS）")
    for name, value in values.items():
        print(f"设置 {name} = {json.dumps(value['value'], ensure_ascii=False)}", file=sys.stderr)
    if values:
        raw = json.dumps(values, ensure_ascii=False).encode()
        print(base64.urlsafe_b64encode(raw).rstrip(b"=").decode())


def current(args):
    with open(args[0], encoding="utf-8") as f:
        view = json.load(f)
    values = {field["name"]: field["value"] for field in view["form"]["fields"] if field.get("value") is not None}
    print(json.dumps(values, ensure_ascii=False))


def verify(args):
    with open(args[0], encoding="utf-8") as f:
        stored = {field["name"]: field.get("value") for field in json.load(f)["form"]["fields"]}
    raw = args[1] + "=" * (-len(args[1]) % 4)
    wanted = json.loads(base64.urlsafe_b64decode(raw))
    wrong = [name for name, value in wanted.items() if stored.get(name) != value]
    if wrong:
        fail("这些设置没存成给的值：" + "、".join(wrong))


def main():
    commands = {"header": header, "current": current, "verify": verify}
    if len(sys.argv) < 3 or sys.argv[1] not in commands:
        fail(__doc__.strip())
    commands[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
