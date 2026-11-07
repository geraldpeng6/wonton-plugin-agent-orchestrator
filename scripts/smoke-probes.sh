# codex 是 Agent：没有网页入口、应用账号体系或插件自己的 MCP 服务。
# shellcheck shell=bash disable=SC2034
# 通用插件冒烟只验证清单能装上；Matrix 加密私聊、模型回答和 Wonton MCP 在专项验收里实测。
IDENTITY_NA=1
SMOKE_NOTE="codex 没有网页入口、应用账号体系或插件自己的 MCP 服务；网页、主人身份、插件工具三项不适用。专项验收验证加密 Matrix 私聊、模型回答和 Wonton MCP 只读工具。"
