#!/bin/bash
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo -e "\n❌ 请用 sudo 或 root 运行\n"
    exit 1
fi

echo -e "\n====================================="
echo "     阿里云盾 / 助手 / 监控 强力卸载   "
echo "         适用于 Ubuntu 系统          "
echo -e "=====================================\n"

# 1. 卸载阿里云盾
echo "[1/5] 卸载阿里云盾（安骑士）"
curl -sSL http://update.aegis.aliyun.com/download/uninstall.sh | bash
curl -sSL http://update.aegis.aliyun.com/download/quartz_uninstall.sh | bash
rm -rf /usr/local/aegis /var/log/aegis /etc/init.d/aegis*

# 2. 强力干掉阿里云助手
echo "[2/5] 彻底清理阿里云助手"
pkill -f aliyun-service 2>/dev/null || true
pkill -f assist_daemon 2>/dev/null || true

/usr/local/share/assist-daemon/assist_daemon --stop 2>/dev/null || true
/usr/local/share/assist-daemon/assist_daemon --delete 2>/dev/null || true

rm -rf /usr/local/share/aliyun-assist
rm -rf /usr/local/share/assist-daemon
rm -rf /usr/sbin/aliyun-service
rm -rf /etc/systemd/system/aliyun.service
rm -rf /etc/init.d/aliyun-service
rm -rf /var/log/aliyun-assist

# 3. 卸载云监控
echo "[3/5] 卸载云监控"
pkill -f cloudmonitor 2>/dev/null || true
/usr/local/cloudmonitor/cloudmonitorCtl.sh stop 2>/dev/null || true
/usr/local/cloudmonitor/cloudmonitorCtl.sh uninstall 2>/dev/null || true
rm -rf /usr/local/cloudmonitor

# 4. 再杀一遍所有阿里云相关进程
echo "[4/5] 强制结束残留进程"
pkill -f 'AliYunDun' 2>/dev/null || true
pkill -f 'aegis' 2>/dev/null || true
pkill -f 'aliyun' 2>/dev/null || true
pkill -f 'assist' 2>/dev/null || true

# 5. 刷新服务
echo "[5/5] 重载系统服务"
systemctl daemon-reload 2>/dev/null || true

echo -e "\n====================================="
echo "              清理完成               "
echo -e "=====================================\n"

# 检查
echo "===== 阿里云盾/安骑士 ====="
ps aux | grep -E "AliYunDun|aegis" | grep -v grep || echo "✅ 无进程"

echo -e "\n===== 阿里云助手 ====="
ps aux | grep -E "aliyun-service|assist-daemon" | grep -v grep || echo "✅ 无进程"

echo -e "\n===== 云监控 ====="
ps aux | grep -E "cloudmonitor|argus" | grep -v grep || echo "✅ 无进程"

echo -e "\n🎉 已彻底清理！\n"
