# syntax=docker/dockerfile:1
# silly_mcnulty · dxkuma-agent-channel 的 UBI10 基础镜像（两用：冒烟实测 → 生产演进）
#
# 构建：
#   GitHub Actions：push 到 main 自动构建并推送 ghcr.io/yushu2606/silly_mcnulty（见 .github/workflows/）
#   本地：podman build -f Containerfile -t dxkuma/agent-channel-base:dev .
# 说明、运行方式与待验证清单见 README.md。

# ---------- 阶段 1：EL10 同代镜像（取 UBI 仓库缺失的二进制） ----------
# UBI10 仓库不含 tmux / bubblewrap（RHEL10 本体有但 UBI 子集剔除了）；
# AlmaLinux 10 与 UBI10 同为 el10 / glibc 2.39，二进制兼容。
FROM docker.io/almalinux:10 AS el10-tools
RUN dnf install -y --setopt=install_weak_deps=0 tmux bubblewrap && dnf clean all

# ---------- 阶段 2：主镜像 ----------
FROM registry.access.redhat.com/ubi10/ubi:latest

# 基础工具 + tmux/bwrap 的运行时依赖（均核对过在 UBI 仓库内）。
# 注意：libevent/ncurses-libs/systemd-libs/libcap/libselinux/libgcc 属 UBI 仓库但基础镜像未预装
# ——这是 2026-10-14 首次构建 ldd 断言失败的根因（UBI 只是没预装，并不是没有）。
RUN dnf install -y --setopt=install_weak_deps=0 \
        socat git ca-certificates curl tar gzip findutils which procps-ng shadow-utils \
        libevent ncurses-libs systemd-libs libcap libselinux libgcc \
    && dnf clean all && rm -rf /var/cache/yum

# 拷入 tmux / bubblewrap（运行时依赖见上方 dnf 清单；若未来仍缺 .so，应急补法：
# COPY --from=el10-tools /usr/lib64/<lib> /usr/lib64/）
COPY --from=el10-tools /usr/bin/tmux  /usr/bin/tmux
COPY --from=el10-tools /usr/bin/bwrap /usr/bin/bwrap
# 缺库断言：拆成每二进制一行；ldd 全输出进日志，失败时一眼定位缺什么
RUN ldd /usr/bin/tmux  | tee /tmp/ldd-tmux.txt  && ! grep -q "not found" /tmp/ldd-tmux.txt  && tmux -V
RUN ldd /usr/bin/bwrap | tee /tmp/ldd-bwrap.txt && ! grep -q "not found" /tmp/ldd-bwrap.txt && bwrap --version

# ripgrep：RHEL/Alma/UBI 10 仓库均无（仅 EPEL 10 有）；取官方 release 的 musl 静态构建，
# 钉版本 + sha256 校验。已知上游 issue #3494：musl x86_64 在超大/高并发搜索
# （约 20GiB / 180 万文件）下偶发 SIGSEGV——与本项目场景相距甚远，记录备查。
# aarch64 构建：换 tarball 名与 SHA（15.2.0 起提供 aarch64-musl；见 README）。
ARG RG_VERSION=15.2.0
ARG RG_SHA256=33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c
RUN curl -fsSL -o /tmp/rg.tgz \
        "https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/ripgrep-${RG_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    && echo "${RG_SHA256}  /tmp/rg.tgz" | sha256sum -c - \
    && tar -xzf /tmp/rg.tgz -C /tmp \
    && install -m 0755 "/tmp/ripgrep-${RG_VERSION}-x86_64-unknown-linux-musl/rg" /usr/bin/rg \
    && rm -rf /tmp/rg.tgz "/tmp/ripgrep-${RG_VERSION}-x86_64-unknown-linux-musl" \
    && rg --version | head -1

# uv（钉 0.13.0：2026-10-09 发布，首个 "Add CPython 3.15.0" 的版本）
COPY --from=ghcr.io/astral-sh/uv:0.13.0 /uv /uvx /bin/

# 托管 Python 3.15.0（3.15.0 于 2026-10-09 GA）。
# UV_PYTHON_DOWNLOADS=manual：仅显式安装允许下载、运行期禁自动下载。
# 注意不可用 never：uv 0.13 源码中 never 会连 `uv python install` 一起拒绝（2026-10-14 构建踩过）。
ENV UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_PYTHON_BIN_DIR=/usr/local/bin \
    UV_PYTHON_DOWNLOADS=manual \
    UV_PYTHON_PREFERENCE=only-managed \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1
RUN uv python install 3.15.0
RUN uv run --no-project --python 3.15.0 python -c "import sys; print(sys.version)"
RUN chmod -R a+rX /opt/python

# 容器预置：仅禁自动更新。
# 切勿设 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC：它同时禁用 feature-flag 拉取，
# 会让 channels 显示 "not currently available"（claude-code#42982 结案同因，2026-10-14 实测踩过）。
ENV DISABLE_AUTOUPDATER=1

# 非 root 运行用户（CC 在 root 下拒绝 --dangerously-skip-permissions；沙盒/登录均按普通用户语义）
RUN useradd -m -u 1000 -s /bin/bash kuma \
    && mkdir -p /home/kuma/.claude-config && chown -R kuma:kuma /home/kuma
ENV PATH=/home/kuma/.local/bin:$PATH \
    CLAUDE_CONFIG_DIR=/home/kuma/.claude-config

# 入口脚本（必须在 root 段创建：写 /usr/local/bin 需要 root，否则 Permission denied）。
# 行为：显式命令 > 交互(tty)落 bash > 无 tty 保活（供 podman exec 使用）。
# 起因：纯 CMD ["/bin/bash"] 在无 tty（忘 -it / ssh 无 tty / -d）时读 EOF 即退 0。
RUN printf '%s\n' \
        '#!/bin/sh' \
        '# kuma entrypoint: explicit cmd > tty gets bash > no-tty stays alive' \
        'if [ "$#" -gt 0 ]; then exec "$@"; fi' \
        'if [ -t 0 ]; then exec /bin/bash; fi' \
        'echo "[kuma] no tty: staying alive; use: podman exec -it <name> bash"' \
        'exec sleep infinity' \
        > /usr/local/bin/kuma-entrypoint \
    && chmod 0755 /usr/local/bin/kuma-entrypoint

USER kuma
WORKDIR /home/kuma

# Claude Code：官方安装脚本（装到 kuma 名下 /home/kuma/.local/bin/claude）。
# - 脚本版默认后台自更新——已由 DISABLE_AUTOUPDATER=1 禁用；升级 = 重建镜像。
# - 版本钉 2.1.299（stable 通道滞后：2026-10-14 实测 stable=2.1.287、channels 不可用；可 --build-arg 覆盖）。
# - 已知坑：以 root 且 cwd 为 / 运行安装器会 hang——故此处以 kuma 身份、cwd 在 /home/kuma 运行。
ARG CLAUDE_INSTALL_CHANNEL=2.1.299
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_INSTALL_CHANNEL}"

# 最终自证：全部命令跑通才算构建成功
RUN claude --version && uv --version \
    && uv run --no-project --python 3.15.0 python -V \
    && tmux -V && bwrap --version && rg --version | head -1 && socat -V | head -1

# 入口脚本创建于上方 root 段（写 /usr/local/bin 需要 root）
#
# 默认 CMD＝保活命令：面板类平台在"镜像无 CMD"时常用 bash 兜底，遇到无 tty 场景会秒退
#（2026-10-14 实测于部署平台的 command/entrypoint 字段联动）；显式给上后平台沿用即可常驻。
# 需要交互 shell：`podman run -it ... bash` 或 `podman exec -it <name> bash`。
CMD ["sleep", "infinity"]
ENTRYPOINT ["/usr/local/bin/kuma-entrypoint"]
