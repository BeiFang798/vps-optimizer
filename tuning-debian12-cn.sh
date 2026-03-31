#!/bin/bash
# ==============================================================================
# Debian 12 (Bookworm) 系统优化脚本 - 全端口开放版
# 适用场景: 8核8G内存 / 德国服务器 / 1Gbps带宽 / 个人使用
# 优化目标: sing-box代理节点 (HY2/VLESS协议)
# 核心优化: BBRv3拥塞控制 + 大缓冲区 + 禁用慢启动 + 全端口开放
# 安全依赖: 云服务商安全组 / 上游防火墙 / 纯内网环境
# 警告: 本脚本移除所有本地防火墙限制，请确保上游已配置访问控制
# ==============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[信息]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }
log_step() { echo -e "${BLUE}[步骤]${NC} $1"; }

# 安全确认
clear
echo "=================================================================="
echo "           Debian 12 系统优化脚本 - 全端口开放版"
echo "=================================================================="
echo "  ⚠️  安全警告:"
echo "     本脚本将禁用所有本地防火墙，开放全部端口(1-65535)"
echo ""
echo "     执行前请确认:"
echo "     ✅ 云服务商安全组已限制访问(如AWS Security Group)"
echo "     ✅ 或服务器位于纯内网/可信网络"
echo "     ✅ 或已配置独立硬件防火墙"
echo ""
echo "     风险: 若上游无防护，服务器将完全暴露于公网"
echo "=================================================================="
echo ""
read -p "确认继续执行? (y/N): " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { log_info "用户取消，退出"; exit 0; }

# ===== 步骤1: 系统更新 =======================================================
log_step "[1/6] 系统更新与组件安装..."
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq curl wget vim haveged ethtool net-tools

systemctl enable --now haveged 2>/dev/null || log_warn "haveged启动失败"

# ===== 步骤2: 内核网络优化 ===================================================
log_step "[2/6] 配置内核网络参数..."

cat > /etc/sysctl.d/99-singbox-fullport.conf << 'EOF'
# 文件描述符
fs.file-max = 100000
fs.nr_open = 100000
fs.suid_dumpable = 0

# 核心网络缓冲(1Gbps)
net.core.somaxconn = 65536
net.core.netdev_max_backlog = 131072
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576

# TCP优化(跨境高延迟)
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1

# TCP内存
net.ipv4.tcp_mem = 2097152 4194304 8388608
net.ipv4.tcp_rmem = 4096 1048576 134217728
net.ipv4.tcp_wmem = 4096 1048576 134217728

# BBRv3
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr

# UDP优化(HY2)
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 2097152 4194304 8388608

# 连接跟踪
net.netfilter.nf_conntrack_max = 65536
net.netfilter.nf_conntrack_tcp_timeout_established = 300

# 安全基础
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
EOF

sysctl --system
log_info "内核参数已应用"

# ===== 步骤3: 文件描述符限制 ==================================================
log_step "[3/6] 配置资源限制..."

cat > /etc/security/limits.conf << 'EOF'
* soft nofile 100000
* hard nofile 100000
* soft nproc 65535
* hard nproc 65535
root soft nofile 100000
root hard nofile 100000
EOF

mkdir -p /etc/systemd/system.conf.d/
cat > /etc/systemd/system.conf.d/limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=100000
DefaultLimitNPROC=65535
EOF

systemctl daemon-reexec
log_info "资源限制已配置"

# ===== 步骤4: 网卡优化 =======================================================
log_step "[4/6] 优化网卡特性..."

IFACE=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' | head -n1)
IFACE=${IFACE:-eth0}

if [ -d "/sys/class/net/$IFACE" ] && command -v ethtool >/dev/null 2>&1; then
    ethtool -K "$IFACE" gro on 2>/dev/null || true
    ethtool -K "$IFACE" gso on 2>/dev/null || true
    ethtool -K "$IFACE" tso on 2>/dev/null || true
    log_info "网卡 $IFACE 优化完成"
else
    log_warn "跳过网卡优化"
fi

# ===== 步骤5: 日志配置 =======================================================
log_step "[5/6] 配置日志轮转..."

mkdir -p /var/log/sing-box
cat > /etc/logrotate.d/sing-box << 'EOF'
/var/log/sing-box/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF

log_info "日志轮转已配置"

# ===== 步骤6: 全端口开放(核心) ==============================================
log_step "[6/6] 配置全端口开放..."

# 停止禁用UFW
log_info "停止并禁用 UFW..."
systemctl stop ufw 2>/dev/null || true
systemctl disable ufw 2>/dev/null || true
apt-get remove -y ufw 2>/dev/null || true

# 清空iptables全部规则
log_info "清空所有 iptables 规则..."
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true

ip6tables -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true

# 默认全部允许
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

ip6tables -P INPUT ACCEPT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true
ip6tables -P OUTPUT ACCEPT 2>/dev/null || true

# 移除iptables-persistent等持久化工具(避免规则恢复)
apt-get remove -y iptables-persistent netfilter-persistent 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# 确保重启后仍无规则
cat > /etc/rc.local << 'EOF'
#!/bin/bash
# 全端口开放 - 清空可能的残留规则
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
exit 0
EOF

chmod +x /etc/rc.local 2>/dev/null || true

log_info "全端口开放已配置(全部TCP/UDP端口允许)"

# ===== 验证与完成 ============================================================
echo ""
echo "=================================================================="
echo "                        优化完成验证"
echo "=================================================================="

# 关键参数验证
echo -e "  BBR状态: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo -e "  慢启动: $(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null) (0=禁用)"
echo -e "  接收缓冲: $(sysctl -n net.core.rmem_max 2>/dev/null | awk '{print $1/1048576 "MB"}')"
echo -e "  文件描述符: $(ulimit -n)"
echo -e "  INPUT策略: $(iptables -L INPUT 2>/dev/null | grep -i policy | awk '{print $4}' | tr -d ')' || echo 'N/A')"
echo -e "  UFW状态: $(systemctl is-active ufw 2>/dev/null || echo 'inactive')"

echo "=================================================================="
echo ""

log_info "优化完成!"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "                    ⚠️  重要安全提醒"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  当前状态:"
echo "    ✅ 全部TCP端口(1-65535) 开放"
echo "    ✅ 全部UDP端口(1-65535) 开放"  
echo "    ✅ UFW已移除"
echo "    ✅ iptables无限制"
echo ""
echo "  必需安全措施:"
echo "    1. 立即配置云服务商安全组:"
echo "       • SSH(22): 仅允许你的IP"
echo "       • 代理端口(443): 按需开放"
echo "       • 其他端口: 默认拒绝"
echo ""
echo "    2. 或配置fail2ban:"
echo "       ${YELLOW}apt install fail2ban${NC}"
echo ""
echo "    3. 建议禁用密码登录:"
echo "       ${YELLOW}编辑 /etc/ssh/sshd_config${NC}"
echo "       ${YELLOW}PasswordAuthentication no${NC}"
echo "       ${YELLOW}systemctl restart sshd${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  后续操作:"
echo "    1. 重启生效: ${YELLOW}reboot${NC}"
echo "    2. 部署sing-box(直接监听任意端口)"
echo "    3. 验证上游防火墙生效"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
