#!/usr/bin/env bash
# douyin-auto-fire 服务器一键部署脚本（阿里云 ECS / Alibaba Cloud Linux 3）
# 用法：在仓库解压目录里执行  bash deploy/server-setup.sh
# 做什么：加 swap、装 Docker、配国内镜像源、构建带补丁的镜像、写好自动发现配置。
# 不做什么：不碰 Cookie（cookie.json 由用户本人粘贴），不启动每日任务（验证通过后再启动）。
set -euo pipefail

INSTALL_DIR=/opt/douyin
IMAGE=douyin-auto-fire:patched
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> [1/6] 检查交换分区（2G 内存机器跑 Chromium 需要 swap 兜底）"
if [ -z "$(swapon --show 2>/dev/null)" ]; then
  if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile || true
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "    swap 已启用"
else
  echo "    已有 swap，跳过"
fi

echo "==> [2/6] 安装 Docker"
if ! command -v docker >/dev/null 2>&1; then
  dnf install -y docker || true
fi
if ! command -v docker >/dev/null 2>&1; then
  cat > /etc/yum.repos.d/docker-ce.repo <<'EOF'
[docker-ce-stable]
name=Docker CE Stable
baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/9/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/docker-ce/linux/centos/gpg
EOF
  dnf install -y docker-ce docker-ce-cli containerd.io || true
fi
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
echo "    Docker: $(docker --version)"

echo "==> [3/6] 配置镜像加速（拉 python 基础镜像用）"
if [ ! -f /etc/docker/daemon.json ]; then
  cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1panel.live"
  ]
}
EOF
  systemctl restart docker
  echo "    已写入 /etc/docker/daemon.json"
else
  echo "    daemon.json 已存在，跳过"
fi

echo "==> [4/6] 准备源码与配置"
mkdir -p "${INSTALL_DIR}/artifacts"
if [ -d "${REPO_ROOT}/app" ]; then
  SRC="${REPO_ROOT}"
  echo "    使用当前仓库目录: ${SRC}"
else
  SRC="${INSTALL_DIR}/src"
  if [ ! -d "${SRC}/app" ]; then
    mkdir -p "${SRC}"
    curl -L https://codeload.github.com/lu93456/douyin-auto-fire/tar.gz/refs/heads/main -o /tmp/df.tgz
    tar xzf /tmp/df.tgz -C "${SRC}" --strip-components=1
  fi
  echo "    源码目录: ${SRC}"
fi

# 自动发现 + 原生表情「续火花」配置（无任何凭证，可公开）
cat > "${INSTALL_DIR}/config.json" <<'EOF'
{
  "auto_discover_spark_friends": true,
  "messages": [{"type": "sticker", "value": "续火花"}],
  "stickers": {"续火花": {"label": "续火花", "category": "常用"}},
  "send_interval_seconds": {"min": 3, "max": 8},
  "prevent_duplicates": false,
  "target_open_retries": 1,
  "target_open_timeout_seconds": 15
}
EOF
echo "    已写入 ${INSTALL_DIR}/config.json"

if [ ! -f "${INSTALL_DIR}/cookie.json" ]; then
  : > "${INSTALL_DIR}/cookie.json"
  echo "    已创建空的 ${INSTALL_DIR}/cookie.json（等用户本人粘贴 Cookie）"
fi
chmod 600 "${INSTALL_DIR}/cookie.json" || true

echo "==> [5/6] 构建镜像（pip 走阿里云镜像源加速；Chromium 下载需要几分钟）"
sed '/^FROM /a ENV PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/' "${SRC}/Dockerfile" > "${SRC}/Dockerfile.local"
docker build -f "${SRC}/Dockerfile.local" -t "${IMAGE}" "${SRC}"

echo "==> [6/6] 生成快捷脚本"
cat > "${INSTALL_DIR}/run-once.sh" <<EOF
#!/usr/bin/env bash
# 手动跑一次：bash run-once.sh --dry-run  （只验证不发送） 或  bash run-once.sh（真实发送）
exec docker run --rm --entrypoint python \\
  -e HEADLESS=true \\
  -e DOUYIN_COOKIE=/data/cookie.json \\
  -e TASK_CONFIG=/app/config.json \\
  -e ARTIFACTS_DIR=/app/artifacts \\
  -v ${INSTALL_DIR}/config.json:/app/config.json:ro \\
  -v ${INSTALL_DIR}/cookie.json:/data/cookie.json:ro \\
  -v ${INSTALL_DIR}/artifacts:/app/artifacts \\
  ${IMAGE} run.py "\$@"
EOF
chmod +x "${INSTALL_DIR}/run-once.sh"

cat > "${INSTALL_DIR}/start.sh" <<EOF
#!/usr/bin/env bash
# 启动每日自动续火花（每天 21:05，容器内 cron）；重复执行会先删旧容器
docker rm -f douyin-auto-fire >/dev/null 2>&1 || true
docker run -d --name douyin-auto-fire --restart unless-stopped \\
  -e TZ=Asia/Shanghai \\
  -e CRON_SCHEDULE="5 21 * * *" \\
  -e RUN_ON_START=false \\
  -e HEADLESS=true \\
  -e DOUYIN_COOKIE=/data/cookie.json \\
  -e TASK_CONFIG=/app/config.json \\
  -e ARTIFACTS_DIR=/app/artifacts \\
  -v ${INSTALL_DIR}/config.json:/app/config.json:ro \\
  -v ${INSTALL_DIR}/cookie.json:/data/cookie.json:ro \\
  -v ${INSTALL_DIR}/artifacts:/app/artifacts \\
  ${IMAGE}
echo "已启动。查看日志: docker logs -f douyin-auto-fire"
EOF
chmod +x "${INSTALL_DIR}/start.sh"

cat <<'EOF'

==================== 部署完成，还差最后两步（需要你本人） ====================
1) 把新鲜导出的抖音 Cookie（JSON 数组，就是之前粘到 GitHub Secret 的那种）
   粘贴进这个文件，覆盖掉空内容：
       /opt/douyin/cookie.json
2) 先跑一次只验证不发送的 Dry Run：
       bash /opt/douyin/run-once.sh --dry-run
   看到发现 10 人、全部打开成功后，再跑真实发送：
       bash /opt/douyin/run-once.sh
   真实发送成功后，启动每日自动运行：
       bash /opt/douyin/start.sh
================================================================================
EOF
