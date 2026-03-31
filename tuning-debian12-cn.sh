#!/bin/bash
set -e;RED='\033[0;31m';GREEN='\033[0;32m';YELLOW='\033[1;33m';BLUE='\033[0;34m';NC='\033[0m'
log_info(){ echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
log_step(){ echo -e "${BLUE}[STEP]${NC} $1"; }
echo "=== Debian 12 Tuning ==="; read -p "Continue? (y/N): " c; [[ "$c" =~ ^[Yy]$ ]] || exit 0
log_step "[1/4] Update..."; apt update -qq && apt upgrade -y -qq && apt install -y -qq haveged ethtool
log_step "[2/4] Sysctl..."; cat > /etc/sysctl.d/99-tuning.conf << EOF
fs.file-max=100000;fs.nr_open=100000
net.core.rmem_max=268435456;net.core.wmem_max=268435456
net.core.somaxconn=65536;net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq_codel;net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mem=2097152 4194304 8388608
net.netfilter.nf_conntrack_max=65536
EOF
sysctl --system
log_step "[3/4] Limits..."; echo "* soft nofile 100000
* hard nofile 100000
root soft nofile 100000" >> /etc/security/limits.conf
mkdir -p /etc/systemd/system.conf.d/; echo "[Manager]
DefaultLimitNOFILE=100000" > /etc/systemd/system.conf.d/limits.conf; systemctl daemon-reexec
log_step "[4/4] Firewall..."; systemctl stop ufw 2>/dev/null; systemctl disable ufw 2>/dev/null; apt remove -y ufw 2>/dev/null; iptables -F; iptables -X; iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
echo "=== Done ==="; echo "BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"; echo "Run: reboot"
