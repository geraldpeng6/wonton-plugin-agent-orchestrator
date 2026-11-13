Agent Orchestrator

开发流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)。

[Agent Orchestrator](https://github.com/OrchestratorInc/agent-orchestrator) 是给一群编程 Agent 派活的编排器。
在云吞里它是聊天中的一个 Bot：你给一个目标，它把活拆给工人，每个工人在自己的 git worktree 里干活；
它要问你、要你批准的时候出确认卡片，所以动手之前你看得到。每个任务一个话题，工人的回复、CI 和 review
的进展都留在那个话题里，主对话只有一行“新任务”。

编排器和工人都是 [Qwen Code](https://github.com/QwenLM/qwen-code)，模型使用模型网关。网关未就绪时不改连其他来源；
API key 和自建地址在模型设置里配置。并发、分工、反馈回投由 AO 自己管；云吞只提供话题、确认卡片和推送。
任务数量在 AO 里定。

自动从 issue 接活默认关。

## 怎么用

1. 装好、模型网关接好以后，私聊里直接说目标，比如“在这个仓库里加一个 add(a, b) 函数和测试”。
2. 它开一个任务话题，里面是它派出的工人；工人改文件、跑命令前会出确认卡片。
3. 它问你问题时，有选项的按卡片回答，也可以点“在话题里回答”后直接在话题里写。
4. 交付是分支上的改动，完成时合回 main（仓库没有配 GitHub 时不建 PR、不 push）。

## 构建镜像

```bash
docker build -t ghcr.io/geraldpeng6/wonton-plugin-agent-orchestrator:0.1.2 -f images/wonton-plugin-agent-orchestrator/Dockerfile images/wonton-plugin-agent-orchestrator
```

镜像按上游 v0.14.10 的源码原样构建（sha256 核对，不改源码）：上游只为 Linux x64 发 deb/AppImage，
arm64 没有发布物，所以按目标架构从源码编译，两个架构都覆盖。qwen-code 由底座在容器首次启动时从官方 npm
registry 按摘要下载到数据卷，首启要多等一会儿；健康检查以 ACP socket 和 AO 的 healthz 都通为准。
发布后用 `scripts/publish.sh` 把摘要写回 compose。

## 边界

- AO 守护进程只监听容器内 loopback，适配器是唯一出口；不给 Docker socket，不给宿主 shell。
- 工人的命令和文件改动全部经确认卡片；AO 的“完全权限”没有打开。
- 插件容器里没有 Docker，AO 的容器回收（ContainerReap）对自己容器里 `docker run` 的活儿不生效，
  工人在容器里怎么跑都行。
- 插件能执行命令并出网，模型设置不是网络级隔离；工人运行的任意代码仍可自行访问网络。

## 图标

`icon.png` 取自上游仓库的 `docs/assets/readme/logo.png`，原样使用；Agent Orchestrator 与
Orchestrator.inc 的名称和标志归 Orchestrator.inc 所有，本插件不是它的官方出品。许可证和来源见 [NOTICE](NOTICE)。
