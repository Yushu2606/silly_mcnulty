# silly_mcnulty

dxkuma 机器人体系的**基础镜像构建仓**：为 **dxkuma-agent-channel**（迪拉熊的下一个形体——基于 nonebot2 / OneBot v11 的 Claude Code Channel）提供 UBI10 基础镜像的构建流水线（Containerfile ＋ GitHub Actions → ghcr.io）。

**两用定位**：先服务 channel 的冒烟实测（干净环境），随后按生产需要演进——不重建第二套。

## 构建产物

- `ghcr.io/yushu2606/silly_mcnulty:latest` 与 `:sha-<commit>`
- 触发：push 到 `main`（仅 `Containerfile` 或 workflow 变更时）或手动 `workflow_dispatch`
- 首次使用：到仓库 Settings → Packages 把该镜像设为 public（或拉取端 `docker login ghcr.io`）

## 版本锚点（钉死）

| 组件 | 锚点 | 来源与备注 |
|---|---|---|
| Python | **3.15.0**（2026-10-09 GA） | uv 托管（`linux-gnu` 构建，glibc 2.17 基线；UBI10 是 2.39，无碍）。UBI 仓库最高 3.14，不用 |
| uv | **0.13.0**（2026-10-09） | 官方镜像 COPY；首个 "Add CPython 3.15.0"。uv 可用 Python 列表按版本冻结，必须 ≥ 0.13.0。镜像内 `UV_PYTHON_DOWNLOADS=manual`（显式安装允许、运行期不自动下载；`never` 会连 install 一起拒） |
| Claude Code | 官方安装脚本，默认 `stable` | 装到 `kuma` 名下；可 `--build-arg CLAUDE_INSTALL_CHANNEL=<版本号>` 钉死；脚本版默认自更新，容器内已禁用（升级 = 重建镜像） |
| tmux / bubblewrap | 从 `almalinux:10` 多阶段 COPY；运行时依赖从 UBI 仓库 dnf 安装 | **UBI10 仓库没有这两个二进制**（RHEL10 本体有；Alma10 同 el10 / glibc 2.39，二进制兼容）。依赖（libevent/ncurses-libs/systemd-libs/libcap/libselinux/libgcc）**在 UBI 仓库内但基础镜像未预装**——需显式 dnf |
| ripgrep | **15.2.0**（官方 musl 静态，钉 sha256） | RHEL/Alma/UBI 10 仓库均无（仅 EPEL 10 有）。**EPEL 备选**：Alma 阶段 `dnf install epel-release && dnf install ripgrep` |
| socat / git / 基础工具 | UBI appstream / baseos | 直接 dnf；**镜像不需要 Node**（`@anthropic-ai/sandbox-runtime` 是 CC 内置的） |

## 本地构建与运行

```bash
podman build -f Containerfile -t dxkuma/agent-channel-base:dev .    # docker 同理
```

构建期自证（任一失败即构建失败）：`ldd` 无缺库、各组件版本可跑、`uv run --python 3.15.0` 可用。
**AVX**：CC 二进制需要 AVX——构建机与宿主 CPU 都要有（无 AVX 报 `Illegal instruction`，官方无 native 绕过）。

```bash
# 冒烟运行示例：物料挂载 + 配置卷 + 自定义 API env
podman run -it --rm --name kuma-smoke \
  -v <smoke-channel 物料目录>:/opt/smoke \
  -v kuma-claude-config:/home/kuma/.claude-config \
  -e ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
  -e ANTHROPIC_AUTH_TOKEN="$ANTHROPIC_AUTH_TOKEN" \
  dxkuma/agent-channel-base:dev
```

`tmux new -s smoke`；从宿主观察/接管：`podman exec -it kuma-smoke tmux attach -t smoke`。
**登录与配置**：状态分 `~/.claude/` 与 `~/.claude.json` 两处——本镜像用 `CLAUDE_CONFIG_DIR=/home/kuma/.claude-config` 收拢到一处，把卷挂到它即可。

## 容器内 bwrap / userns 验证（只读四条）

```sh
cat /proc/sys/user/max_user_namespaces                 # 0 = userns 被禁（宿主需允许）
unshare -U --map-current-user true                     # EPERM = 被 seccomp 拦（第一层）
bwrap --ro-bind / / --dev /dev --proc /proc -- true    # 挂 proc 失败 = /proc 被 runc 掩码（第二层）
grep " /proc" /proc/self/mountinfo | wc -l             # >1 通常 = /proc 被掩码（线索，非充分）
```

## 两条路线（生产化时的裁决点——冒烟不受影响）

- **路线 A「容器即沙盒」**（官方 devcontainer 支持模式）：非 root + 容器边界 + egress 防火墙，**不套内层沙盒**。
- **路线 B「嵌套沙盒」**：CC 沙盒在容器内运行。需要 settings 设 `sandbox.enableWeakerNestedSandbox: true`（官方修复 `/proc` 挂载；官方明说"显著削弱安全"），podman 加 `--security-opt unmask=/proc/*`；docker 加 `seccomp=unconfined` ＋ `apparmor=unconfined`（Ubuntu 宿主）＋ `systempaths=unconfined`。
  - **已记录硬伤**：容器内**非 root** 跑新版 CC，apply-seccomp 二次嵌套 userns 写 `/proc/self/setgroups` 得 EACCES——内核硬限制（claude-code #48304 closed as not planned；#56345 证实 `enableWeakerNestedSandbox` 对它无效）。
  - **连锁影响**：`autoAllowBashIfSandboxed`（沙盒内命令自动放行）依赖沙盒成立——走路线 A 时该机制不存在，治理层需重新设计。
- 不要设 `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`（会把 `enableWeakerNestedSandbox` 静默强制回 false，claude-code #73786）。

## 待验证清单（首建 / 首跑）

- [x] ~~`ldd` 断言~~ **已修（2026-10-14）**：根因＝UBI 基础镜像未预装 tmux/bwrap 的运行时依赖（libevent/ncurses-libs/systemd-libs/libcap/libselinux/libgcc 全在 UBI 仓库内）→ 已加入 dnf 清单；断言拆为每二进制一行、ldd 输出进日志
- [ ] claude 脚本安装落点与断言（`claude --version` 在 kuma 的 PATH 下通过）
- [ ] UBI10 未被官方点名支持 CC（按"RHEL10 用户空间"推断可行）——首跑 `claude -p "ok"` 确认
- [ ] 自定义 API 环境下 channel 门禁（与 smoke-channel 记录表第 1 项合并验证）
- [ ] 宿主 userns 策略：RHEL 系默认允许非特权 userns；若宿主加固过（`max_user_namespaces=0`）需先放开
