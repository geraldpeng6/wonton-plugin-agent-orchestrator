# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 用应用自己的“当前用户”接口断言认出的是用户管理员。没有用户体系时写 IDENTITY_NA=1，
#       并在 SMOKE_NOTE 里写原因。dweb / web_get 是带用户会话的请求助手，可继续走应用自己的登录链。
#       SSO 登录跳转不用自己写表单逻辑：dweb --sso 会从清单 webui.path 的入口出发（没写就是 /），提交核心
#       登录页的 JS 自动表单并跟完重定向，返回的页面已带应用的登录态。
# 工具：MCP_TOOL 写一个只读工具名（可带插件前缀），MCP_ARGS 是 JSON 参数；mcp_assert 从标准输入读调用结果。
#       要断言多个工具时改成写 mcp_check；调用前要备数据时写 before_mcp。
# 数据：合并前要验证“升级/重装不丢用户数据”时写 data_write 和 data_check（两个都写才跑）：data_write 用随机标记写
#       一条数据并把标记原样存进 $SMOKE_STATE，data_check 读回标记去应用里找，对不上就打印看到了什么并返回非 0。
#       应用不存用户数据时写 DATA_NA=1（两项记 N/A）。
# 装之前要准备（如先配出口代理）：写 before_install。

web_assert() { grep -q '你好'; }   # 示例页的标题

identity_check() { # 页面回显的就是网关注入的用户名
  local page
  page="$(dweb /)" || { echo "页面失败：$page"; return 1; }
  grep -qF "你好，$SMOKE_OWNER" <<<"$page" || { echo "页面没回显用户 $SMOKE_OWNER：$(head -c 120 <<<"$page")"; return 1; }
}

# 数据：合并前要验证“升级/重装不丢用户数据”时写 data_write 和 data_check（两个都写才跑）：
#   data_write 用随机标记写一条数据，把标记原样存进 $SMOKE_STATE；data_check 读回标记、去应用里找，
#   找不到就打印看到了什么并返回非 0。
# 应用不存用户数据时写 DATA_NA=1（两项记 N/A）。模板的示例页不存数据，所以这里是不适用。
export DATA_NA=1
