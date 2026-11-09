# Agent Orchestrator 本体取自上游 v0.14.10 的源码原样构建（Apache-2.0）：上游只为 Linux 发 x64 的
# deb/AppImage，arm64 没有发布物，从固定版本的源码按目标架构编译两个架构都覆盖。源码摘要核对后编译，
# 不改源码。运行时只需要 git 和 tmux（AO 的启动自检要这两样，TUI 模式用 tmux）。
ARG BASE_IMAGE=ghcr.io/geraldpeng6/wonton-agent-base:0.1.0@sha256:9d6e0ca87c14eee21b5b6503fb52dd863182e7a4f784dd644a4e8cb3f58989d7
FROM public.ecr.aws/docker/library/golang:1.27-trixie@sha256:af1bfc2614ebb1dbd31af514b78740fd678850e76498762b425ecee4c5c6ea80 AS build

ARG AO_VERSION=0.14.10
ARG AO_SHA256=4c5e205f28344efafe50687de667e940685eea24e0ae9a79a7aa742665ad8db5

RUN curl --fail --silent --show-error --location \
      "https://github.com/OrchestratorInc/agent-orchestrator/archive/refs/tags/v${AO_VERSION}.tar.gz" \
      --output /tmp/ao.tgz \
    && echo "$AO_SHA256  /tmp/ao.tgz" | sha256sum --check --strict \
    && tar -xzf /tmp/ao.tgz -C /tmp \
    && cd "/tmp/agent-orchestrator-${AO_VERSION}/backend" \
    && CGO_ENABLED=0 go build -trimpath \
         -ldflags "-s -w -X github.com/aoagents/agent-orchestrator/backend/internal/cli.Version=${AO_VERSION}" \
         -o /out/ao ./cmd/ao \
    && mkdir -p /out/doc \
    && cp "/tmp/agent-orchestrator-${AO_VERSION}/LICENSE" /out/doc/LICENSE.agent-orchestrator


FROM ${BASE_IMAGE}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends git tmux \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ao /usr/local/bin/ao
COPY --from=build /out/doc/ /usr/share/doc/wonton-plugin-agent-orchestrator/

COPY agent.toml /etc/wonton-agent/
COPY --chmod=0755 gateway /usr/local/lib/wonton-agent/gateway
COPY --chmod=0755 ao-acp /usr/local/bin/ao-acp
COPY --chmod=0755 adapter.py /usr/local/bin/wonton-ao-adapter
COPY --chmod=0644 ao.py approvals.py transport.py /usr/local/bin/
COPY prompt.md /usr/local/share/wonton-agent/prompt.md

USER 65532:65532
