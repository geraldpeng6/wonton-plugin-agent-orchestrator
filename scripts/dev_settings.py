"""合并开发环境的 .env；保留已有行，只补缺项并更新镜像解析值。"""

import os
from pathlib import Path
import re
import sys
import tempfile


HEADER = """# 由 scripts/dev.sh 写出；up 保留已有设置，只补缺项并更新 WONTON_CORE_IMAGE。
# 可手改：WONTON_CORE_SOURCE、WONTON_PULL、WONTON_PORT、WONTON_TUNNEL_PORT、WONTON_OWNER_EMAIL、
# WONTON_PUID、WONTON_PGID、WONTON_LAN_ADDRESSES、WONTON_EGRESS_PROXY、WONTON_EGRESS_PROXY_DETECTED、
# WONTON_PLUGIN_SLICE、TZ、RUST_LOG。核心安装超时未由 compose 传入，写进这里不会生效。
# 实例名、基础域名、WONTON_OWNER_NAME、核心容器名和数据路径定下后不要改；rebuild 只重建核心栈和工作区插件。
"""


def main():
    path = Path(sys.argv[1])
    defaults = dict(line.split("=", 1) for line in sys.stdin.read().splitlines())
    text = path.read_text() if path.exists() else ""
    lines = text.splitlines(keepends=True)
    if lines and lines[0].startswith("# 由 scripts/dev.sh 写出，每次 up 重写"):
        lines = lines[2:]
    elif text.startswith(HEADER):
        lines = lines[len(HEADER.splitlines()):]
    seen = set()
    output = [HEADER]
    for line in lines:
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
        if match:
            key = match[1]
            seen.add(key)
            if key == "WONTON_CORE_IMAGE":
                line = f"{key}={defaults[key]}\n"
        output.append(line)
    if output[-1] and not output[-1].endswith("\n"):
        output.append("\n")
    output.extend(f"{key}={value}\n" for key, value in defaults.items() if key not in seen)
    fd, temporary = tempfile.mkstemp(prefix=".env.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write("".join(output))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    main()
