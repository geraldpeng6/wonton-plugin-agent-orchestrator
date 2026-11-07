"""MCP 客户端（官方 SDK），在 Hermes gateway 或同镜像的一次性容器里跑：脚本从标准输入读入。

  list <URL>                initialize + tools/list（翻页），标准输出工具数组的 JSON
  call <URL> <工具> <JSON>  initialize + tools/call，标准输出 result 的 JSON

HTTP、JSON-RPC 错误、isError=true、超时：退出非 0，原因打到标准错误。
"""

import asyncio
import json
import sys

from mcp import ClientSession, types
from mcp.client.streamable_http import streamable_http_client


def dump(value):
    return value.model_dump(mode="json", by_alias=True, exclude_none=True)


async def list_tools(url):
    async with streamable_http_client(url, terminate_on_close=False) as streams:
        read, write = streams[0], streams[1]
        async with ClientSession(read, write, read_timeout_seconds=120) as session:
            await session.initialize()
            tools, cursor, page = [], None, 0
            while True:
                params = types.PaginatedRequestParams(cursor=cursor) if cursor else None
                result = await session.list_tools(params=params)
                tools += [dump(tool) for tool in result.tools]
                cursor = result.next_cursor
                page += 1
                if not cursor or page > 50:
                    return tools


async def call(url, name, arguments):
    async with streamable_http_client(url, terminate_on_close=False) as streams:
        read, write = streams[0], streams[1]
        async with ClientSession(read, write, read_timeout_seconds=300) as session:
            await session.initialize()
            result = await session.call_tool(name, arguments)
            if result.is_error:
                text = "".join(c.get("text", "") for c in dump(result).get("content", []))
                raise SystemExit(f"工具 isError：{text[:400] or json.dumps(dump(result))[:400]}")
            return dump(result)


def explain(exc):
    if isinstance(exc, BaseExceptionGroup):
        return "；".join(explain(e) for e in exc.exceptions)
    return f"{type(exc).__name__}: {exc}"


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    command, url, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
    try:
        if command == "list":
            print(json.dumps(asyncio.run(list_tools(url)), ensure_ascii=False))
        elif command == "call":
            if not rest:
                raise SystemExit("用法：call <URL> <工具> [<JSON>]")
            print(json.dumps(asyncio.run(call(url, rest[0], json.loads(rest[1] if len(rest) > 1 else "{}"))),
                             ensure_ascii=False))
        else:
            raise SystemExit(__doc__)
    except BaseExceptionGroup as group:
        raise SystemExit(f"连接失败：{explain(group)}")
    except Exception as error:
        raise SystemExit(f"连接失败：{type(error).__name__}: {error}")


main()
