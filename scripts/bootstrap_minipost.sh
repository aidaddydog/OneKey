#!/usr/bin/env bash
# 一键部署（在线）v1.1 — 公开引导脚本（OneKey）
# 作用：从公开仓（本脚本）引导克隆你的私有仓（minipost）并启动 Docker Compose
# 特点：中文注释、进度提示、日志落盘、UFW 放行、二次覆盖安全确认、Deploy Key/HTTPS(PAT) 两种克隆方式

set -Eeuo pipefail

# ====== 配色/日志 ======
c_red='\033[1;31m'; c_grn='\033[1;32m'; c_ylw='\033[1;33m'; c_blu='\033[38;5;39m'; c_rst='\033[0m'
ok(){ echo -e "${c_grn}[+] $*${c_rst}"; }
warn(){ echo -e "${c_ylw}[!] $*${c_rst}"; }
err(){ echo -e "${c_red}[-] $*${c_rst}" >&2; }
LOG=/var/log/minipost_bootstrap.log; mkdir -p "$(dirname "$LOG")"; exec > >(tee -a "$LOG") 2>&1

# ====== 默认参数（可命令行覆盖）======
REPO_URL="git@github.com:aidaddydog/minipost.git"   # 私有主仓（SSH）
REPO_BRANCH="main"
DEPLOY_DIR="/opt/minipost"
SSH_KEY_PATH="/root/.ssh/minipost_deploy"            # Deploy Key 私钥路径
AUTO_OPEN_PORTS="80,443"                             # 基础放行；会附加 .deploy.env 里的 HTTP/HTTPS/PORT
NON_INTERACTIVE="no"                                 # -y 无需确认
GIT_SSH_OPTS="-oStrictHostKeyChecking=accept-new"

# ====== 解析参数 ======
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_URL="$2"; shift 2;;
    --branch) REPO_BRANCH="$2"; shift 2;;
    --dir) DEPLOY_DIR="$2"; shift 2;;
    --key) SSH_KEY_PATH="$2"; shift 2;;
    --ports) AUTO_OPEN_PORTS="$2"; shift 2;;
    --yes|-y) NON_INTERACTIVE="yes"; shift;;
    *) warn "忽略未知参数：$1"; shift;;
  esac
done

ok "参数：repo=$REPO_URL branch=$REPO_BRANCH dir=$DEPLOY_DIR key=$SSH_KEY_PATH"

# ====== 前置检查 ======
[[ $EUID -eq 0 ]] || { err "必须以 root 运行"; exit 1; }
grep -qi "ubuntu" /etc/os-release || warn "非 Ubuntu 系统；脚本按 Ubuntu 24 优化"
ok "前置检查通过"

# ====== 安装基础工具 ======
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl git ufw jq

# ====== 安装 Docker & Compose（如未安装）======
if ! command -v docker >/dev/null 2>&1; then
  ok "安装 Docker ..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi
if ! docker compose version >/dev/null 2>&1; then
  ok "安装 Docker Compose 插件 ..."
  apt-get install -y docker-compose-plugin
fi
ok "Docker/Compose 就绪"

# ====== 准备 Git 认证（Deploy Key 或 HTTPS/PAT）======
if [[ "$REPO_URL" == git@github.com:* ]]; then
  [[ -f "$SSH_KEY_PATH" ]] || { err "未找到 Deploy Key：$SSH_KEY_PATH"; exit 1; }
  chmod 600 "$SSH_KEY_PATH"
  export GIT_SSH_COMMAND="ssh -i $SSH_KEY_PATH $GIT_SSH_OPTS"
  ok "使用 Deploy Key（SSH）克隆"
else
  ok "使用 HTTPS/PAT 克隆（需事先 export GIT_TOKEN 并写进 REPO_URL）"
fi

# ====== 二次覆盖/升级 ======
if [[ -d "$DEPLOY_DIR/.git" ]]; then
  if [[ "$NON_INTERACTIVE" == "yes" ]]; then CHOICE="y"; else
    read -rp $'\e[1;33m[?]\e[0m 检测到已有部署，是否覆盖更新？(y/N) ' CHOICE || true
  fi
  [[ "$CHOICE" =~ ^[Yy]$ ]] || { ok "已取消覆盖"; exit 0; }
  ok "将执行安全覆盖：拉取更新并重建容器"
else
  mkdir -p "$DEPLOY_DIR"
fi

# ====== 克隆/更新仓库 ======
if [[ -d "$DEPLOY_DIR/.git" ]]; then
  (cd "$DEPLOY_DIR" && git fetch --all && git checkout "$REPO_BRANCH" && git pull --ff-only) \
    && ok "仓库更新完成" || { err "仓库更新失败"; exit 1; }
else
  git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" "$DEPLOY_DIR" \
    && ok "仓库克隆完成" || { err "仓库克隆失败"; exit 1; }
fi

# ====== 读取 .deploy.env 并补充分发端口 ======
if [[ -f "$DEPLOY_DIR/.deploy.env" ]]; then
  set -a; source "$DEPLOY_DIR/.deploy.env"; set +a
  for p in "${PORT:-}" "${HTTP_PORT:-}" "${HTTPS_PORT:-}"; do
    [[ -n "${p:-}" ]] && AUTO_OPEN_PORTS="$AUTO_OPEN_PORTS,$p"
  done
fi

# ====== 放行端口（若启用 UFW）======
if command -v ufw >/dev/null 2>&1; then
  ufw --force enable || true
  IFS=',' read -ra PORTS <<<"$AUTO_OPEN_PORTS"
  for p in "${PORTS[@]}"; do
    p_trim="$(echo "$p" | xargs)"; [[ -n "$p_trim" ]] && ufw allow "$p_trim/tcp" || true
  done
  ok "UFW 已放行端口：${AUTO_OPEN_PORTS}"
fi

# ====== 启动服务（Docker Compose）======
compose_file="$DEPLOY_DIR/docker-compose.yml"
[[ -f "$compose_file" ]] || { err "缺少 $compose_file"; exit 1; }

ok "拉取镜像并启动容器 ..."
docker compose -f "$compose_file" pull || true
docker compose -f "$compose_file" up -d --remove-orphans

ok "部署完成 ✅"
echo -e "${c_blu}引导日志：tail -n 200 -F $LOG${c_rst}"
echo -e "${c_blu}Compose日志：docker compose -f $compose_file logs -f --tail=200${c_rst}"
