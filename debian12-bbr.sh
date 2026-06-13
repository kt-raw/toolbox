#!/bin/bash

echo "=============================="
echo "  Debian 12 BBR 检测/开启脚本"
echo "=============================="

kernel=$(uname -r)
echo "[INFO] 当前内核: $kernel"

cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
echo "[INFO] 当前TCP拥塞控制: $cc"

if [ "$cc" = "bbr" ]; then
    echo "[OK] BBR 已经开启，无需重复操作"
else
    echo "[ACTION] 开始启用 BBR..."
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    echo "[OK] 已临时开启 BBR"
fi

if ! grep -xq 'net.core.default_qdisc=fq' /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
fi
if ! grep -xq 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf; then
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi

sysctl -p >/dev/null 2>&1

final=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
echo "=============================="
echo "[RESULT] 当前最终状态:"
echo "TCP Congestion Control: $final"

if [ "$final" = "bbr" ]; then
    echo "[SUCCESS] BBR 已成功启用"
else
    echo "[WARNING] BBR 未生效，请检查内核"
fi
echo "=============================="
