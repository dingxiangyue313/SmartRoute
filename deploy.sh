#!/bin/bash
# SmartRoute AI 一键部署脚本 (Ubuntu/CentOS)
# 用法：在腾讯云服务器上执行 bash deploy.sh

set -e

SERVER_IP="42.193.138.163"
REPO_URL="https://github.com/yara1006/smartroute.git"
APP_DIR="/opt/smartroute"
BACKEND_PORT=8000
FRONTEND_PORT=5173

echo "========================================="
echo "  SmartRoute AI 部署脚本"
echo "========================================="

# ---------- 1. 检测系统 ----------
if command -v apt-get &>/dev/null; then
    PKG="apt"
    apt-get update -y
elif command -v yum &>/dev/null; then
    PKG="yum"
    yum update -y
elif command -v dnf &>/dev/null; then
    PKG="dnf"
    dnf update -y
else
    echo "未检测到包管理器，请手动安装依赖"
    exit 1
fi

# ---------- 2. 安装系统依赖 ----------
echo ">>> 安装系统依赖..."
if [ "$PKG" = "apt" ]; then
    apt-get install -y git python3 python3-pip python3-venv nodejs npm nginx
elif [ "$PKG" = "yum" ] || [ "$PKG" = "dnf" ]; then
    $PKG install -y git python3 python3-pip nodejs npm nginx
fi

# 确保 pip3 可用
if ! command -v pip3 &>/dev/null; then
    apt-get install -y python3-pip || yum install -y python3-pip || dnf install -y python3-pip
fi

# ---------- 3. 克隆或更新代码 ----------
echo ">>> 获取代码..."
if [ -d "$APP_DIR/.git" ]; then
    cd "$APP_DIR"
    git pull origin main
else
    mkdir -p "$APP_DIR"
    git clone "$REPO_URL" "$APP_DIR"
    cd "$APP_DIR"
fi

# ---------- 4. Python 后端 ----------
echo ">>> 安装 Python 依赖..."
cd "$APP_DIR"

# 创建虚拟环境
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate

pip install --upgrade pip
pip install -r requirements.txt

# 生成模拟数据
echo ">>> 生成 POI 数据..."
python3 data/seed_db.py

# ---------- 5. 前端构建 ----------
echo ">>> 构建前端..."
cd "$APP_DIR/web"
npm install
npm run build

# ---------- 6. 配置 Nginx ----------
echo ">>> 配置 Nginx..."
cat > /etc/nginx/conf.d/smartroute.conf << 'NGINX_EOF'
server {
    listen 80;
    server_name _;

    # 前端静态文件
    location / {
        root /opt/smartroute/web/dist;
        try_files $uri $uri/ /index.html;
    }

    # 后端 API 代理
    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket 支持（如果需要）
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # 高德地图 API 代理（前端直连高德）
    location /amap/ {
        proxy_pass https://restapi.amap.com/;
        proxy_set_header Host restapi.amap.com;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINX_EOF

# 测试并重启 Nginx
nginx -t && systemctl restart nginx && systemctl enable nginx

# ---------- 7. 启动后端（systemd 服务） ----------
echo ">>> 配置后端 systemd 服务..."
cat > /etc/systemd/system/smartroute.service << 'SERVICE_EOF'
[Unit]
Description=SmartRoute AI Backend
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/smartroute
ExecStart=/opt/smartroute/venv/bin/python -m uvicorn api:app --host 127.0.0.1 --port 8000 --workers 2
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl restart smartroute
systemctl enable smartroute

# ---------- 8. 防火墙/安全组 ----------
echo ">>> 配置防火墙..."
if command -v ufw &>/dev/null; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw reload
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
fi

# ---------- 9. 完成 ----------
echo ""
echo "========================================="
echo "  部署完成！"
echo "========================================="
echo ""
echo "  访问地址: http://$SERVER_IP"
echo "  后端 API: http://$SERVER_IP/api/health"
echo "  API 文档: http://$SERVER_IP/docs"
echo ""
echo "  常用命令："
echo "  查看后端日志:  journalctl -u smartroute -f"
echo "  重启后端:      systemctl restart smartroute"
echo "  重启前端Nginx: systemctl restart nginx"
echo "  更新代码:      cd $APP_DIR && git pull && systemctl restart smartroute && systemctl restart nginx"
echo ""
echo "  注意：腾讯云控制台的安全组需放行 80 和 443 端口"
echo "========================================="
