# 插件仓库的规则

本仓库是 Agent Orchestrator 插件：一个编排器 Bot，把活拆给工人。适配器 `images/wonton-plugin-agent-orchestrator/adapter.py` 的映射（谁对谁、什么变成卡片、什么变成话题）写在文件开头的注释里，改之前先读。

本文件对人和 AI 编程代理（Claude Code、Codex 等）同样适用。通用开发流程见[开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)，规则见[插件规范](https://github.com/wontonapp/wonton-docs/blob/main/plugin-spec.md)。

## 插件包

- 插件就是根目录的 `docker-compose.yml` 和它引用的文件。规则以核心的检查为准：`scripts/check.sh` 通过、
  `scripts/dev.sh install` 装得上，才算写对了；不靠猜规范，也不为了通过检查改动核心的规则。
- 核心不支持插件要的东西（一项权限、一个 compose 字段、宿主设备这类能力）时，不绕过核心的规则，也不悄悄去掉这项功能：
  在 PR 里写明缺什么、为什么要，向云吞提 issue。
- 只申请用得到的权限：要出网才申请 `network.egress`，只读的共享文件夹申请 `:read` 并以 `:ro` 挂载。
- 新插件默认用应用自带的登录（`sso: none`）：装好后第一次打开，用户在应用里自己注册管理员。插件网页始终在核心网关的登录
  后面，别另建绕过网关的入口；已经接了 `sso: oidc` 或 `sso: proxy` 的保留。不把用户令牌交给插件。
- 要用大模型就申请 `models`，经模型网关访问。插件里不放任何第三方 API key，也不让用户把 key 填进插件。
- 插件自己的密钥写在清单的 `secrets` 里，由核心生成或保管；不写进 compose、配置文件和镜像。
- 镜像：
  - 用上游官方镜像，按清单列表（index）的摘要固定：`名字:标签@sha256:…`。
  - 不改上游镜像，不另发修改版。确实要自己构建的，Dockerfile 放在 `images/<名字>/`，由 `scripts/publish.sh`
    构建多架构镜像、推送并按摘要固定。
  - 新用一个镜像或依赖时写明它的许可证。清单的 `license` 写应用的许可证（SPDX），插件包自己的许可证写在 LICENSE 里
    （模板是 MIT，新建仓库时换成你自己的）。
- 图标用上游标志时，来源、版权、处理方式、许可全文和商标说明写进 `NOTICE`，清单用 `notices: [NOTICE]` 引用；图标是自己
  画的就写原创和本仓库许可证。README 的图标一节只留一句来源和商标说明，指向 NOTICE。
- README 只写这个插件的说明；通用流程和规则链接开发指南与插件规范，不在插件仓库复制。

## 质量

- 代码和配置短、清楚、不冗余。每个部分只做一件事（Unix 哲学）：能用上游应用现成的配置或功能做到的，不写脚本，
  也不在中间加一层。

## 运行时原则：失败即停

- 不用 mock、预览数据、静默降级或兜底行为掩盖缺失能力。缺了配置、连不上依赖时启动失败或如实报错，不假装正常。
- 错误要说清原因：权限缺失、依赖的服务没就绪、上游出错、输入非法，分开说。
- 状态不确定时如实显示为不确定，不伪装成功。
- 健康检查检查的是真正可用，不只是进程还活着。

## 界面

- Avoid unnecessary secondary labels and descriptions. Let the layout do the explaining.
  分组、顺序、位置和图标已经说明了的，不再加副标题、说明文字或标签重复一遍。插件自己的网页同样适用。
- 错误、权限和来源的提示不算多余，照常写清楚（见“失败即停”）。
- 商店信息照规范写：`description` 一句话说清插件做什么，`about`、`release_notes` 写清楚内容；怎么显示由 App 决定。

## 共用一台 Docker

几个人或几个 Agent 可能共用一台 Docker，各自的开发环境靠实例名分开（见[开发指南的“开发环境”](https://github.com/wontonapp/wonton-docs/blob/main/develop.md#开发环境)）。

- 开发环境的起停、安装和清理只用 `scripts/dev.sh`。
- 不执行 `docker system prune`、`docker container prune`、`docker volume prune`、`docker network prune`、
  `docker image prune -a` 这类针对整台主机的清理。
- 只动名字里带着自己实例名（`.wonton/.env` 的 `WONTON_INSTANCE`）的容器、网络和卷；别人的不停、不删、不进去改。
- 自己构建或拉来试用的镜像，用完按名字删掉；不删别人的镜像。
- 不再开发时执行 `scripts/dev.sh purge`。

## 验证

插件仓库没有单元测试，改了插件包就在开发环境里走一遍：

1. `scripts/check.sh --official` 没有不合格，提醒都有原因。
2. `scripts/dev.sh reinstall --yes` 装得上，`scripts/dev.sh status` 里是 `running healthy`。
3. 浏览器打开插件网页：`sso: oidc` 或 `proxy` 验证自动登录；`sso: none` 验证首次注册管理员和应用自己的登录。
   把插件的主要功能用一遍。没有浏览器时用 `scripts/dev.sh web <路径> [<curl 参数>…]` 通过核心网关请求网页和接口，
   应用自己的登录仍需单独验证。
4. 写进数据的操作做一次，`scripts/dev.sh reinstall --yes` 以后数据还在；`scripts/dev.sh uninstall --purge` 以后数据
   删干净了（没有 `.wonton/data/apps/<slug>/`，`docker volume ls` 里没有它的卷）。

PR 描述写清改了什么、为什么、上面哪几步做了、结果是什么；每个结论附上执行的命令和结果，没做的写明没做。

## 文档与注释

- 文档和注释只记录读代码得不到的信息：为什么这样写（包括没选的写法）、约束、上游镜像和应用的实测行为。
- 不写会变的当前状态（“现在”“还没”“目前”）；验证结果写明验证时的版本和条件。
- compose 里的注释写给审核的人看：为什么要这项权限、为什么挂这个目录、为什么用这个用户运行。

## Git 与发布

- 只有 `main` 一个长期分支。一件事一个分支、一个 PR。
- 提交信息用 Conventional Commits：`type(scope): 摘要`，`type` 取 `feat`、`fix`、`docs`、`refactor`、`chore`、
  `build`、`ci`；摘要说清行为变化。
- 不提交 `.wonton/`、密钥和调试产物（截图、日志）。截图只有商店用的放在 `screenshots/`。
- 发布只用 `scripts/publish.sh`：先改清单的 `version`、写好 `release_notes`，确认 `notices` 指向的文件是最新的，再提交。发布过的 tag 不移动、不删除；
  发错了就发一个新版本。

## 在公开仓库开发

本仓库是公开的，开发就在这里：从 `main` 切分支，提 PR 合回 `main`，不另设私有仓库同步。

- 提交作者用 GitHub 的 noreply 邮箱：`git config user.email "<数字 ID>+<用户名>@users.noreply.github.com"`。
- 提交信息、PR、issue 和截图都是公开的，里面不写真实的局域网地址、主机名、账号和密钥。写验证结果时只写做了什么、结果如何；地址换成 `192.0.2.10` 这样的示例。
- 发布就是改清单的 `version`、提交、打 tag `v<version>`。官方索引记的是 tag 对应的提交，要更新就向 `geraldpeng6/wonton-store` 提 PR。
