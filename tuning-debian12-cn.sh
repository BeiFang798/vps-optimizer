#!/bin/bash
# ==============================================================================
# Debian 12 (Bookworm) 系统优化脚本 - 中文注释版
# 适用场景: 8核8G内存 / 德国服务器 / 1Gbps带宽 / 个人使用
# 优化目标: sing-box代理节点 (HY2/VLESS协议)
# 核心优化: BBRv3拥塞控制 + 大缓冲区 + 禁用慢启动 + 连接数优化
# 作者: 系统优化工程师
# 日期: 2026-03-31
# ==============================================================================

set -e

# 颜色定义 - 用于美化输出
RED='\033[0;31m'      # 红色 - 错误
GREEN='\033[0;32m'    # 绿色 - 成功
YELLOW='\033[1;33m'   # 黄色 - 警告
BLUE='\033[0;34m'     # 蓝色 - 信息
NC='\033[0m'          # 恢复默认颜色

# 日志输出函数
log_info() {
    echo -e "${GREEN}[信息]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

log_error() {
    echo -e "${RED}[错误]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[步骤]${NC} $1"
}

# 脚本开始 - 显示系统信息
clear
echo "=================================================================="
echo "           Debian 12 系统优化脚本 - 个人1Gbps代理节点"
echo "=================================================================="
echo "  系统信息:"
echo "    操作系统: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "    内核版本: $(uname -r)"
echo "    CPU核心数: $(nproc)"
echo "    内存总量: $(free -h | awk '/^Mem:/ {print $2}')"
echo "    当前时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=================================================================="
echo ""

# ===== 步骤1: 系统更新与必要组件安装 =========================================
log_step "[1/7] 系统更新与安装必要组件..."

log_info "正在更新软件包列表..."
apt-get update -qq

log_info "正在升级已安装软件包..."
apt-get upgrade -y -qq

log_info "正在安装优化所需组件..."
# haveged: 增加系统熵池,加速TLS握手(生成随机数)
# ethtool: 网卡高级配置
# net-tools: 网络工具(ifconfig等)
# ufw: 简易防火墙
apt-get install -y -qq curl wget vim haveged ethtool net-tools ufw

# 启动haveged服务,确保TLS证书生成有足够随机数
log_info "启动 haveged 熵池服务..."
systemctl enable --now haveged 2>/dev/null || log_warn "haveged 启动失败,继续执行"

# ===== 步骤2: 内核网络参数优化 (核心步骤) =====================================
log_step "[2/7] 配置内核网络参数 (sysctl)..."

log_info "写入网络优化配置到 /etc/sysctl.d/99-singbox-personal.conf"

cat > /etc/sysctl.d/99-singbox-personal.conf << 'EOF'
# ==============================================================================
# 内核网络参数优化配置 - 针对 sing-box 代理节点优化
# 适用: Debian 12, 8核8G, 1Gbps带宽, 德国位置
# ==============================================================================

# --- 文件描述符限制 ---
# 系统级文件句柄上限,影响最大并发连接数
fs.file-max = 100000
# 单个进程可打开文件数上限
fs.nr_open = 100000
# 禁用setuid程序core dump,提升安全性
fs.suid_dumpable = 0

# --- 核心网络缓冲区 (针对1Gbps高带宽优化) ---
# Socket监听队列长度,应对突发连接
net.core.somaxconn = 65536
# 网卡队列包上限,减少高并发时丢包
net.core.netdev_max_backlog = 131072
# 最大接收缓冲区 (256MB,个人8G内存充裕)
net.core.rmem_max = 268435456
# 最大发送缓冲区 (256MB)
net.core.wmem_max = 268435456
# 默认接收缓冲区 (1MB)
net.core.rmem_default = 1048576
# 默认发送缓冲区 (1MB)
net.core.wmem_default = 1048576
# 网卡处理预算,提升吞吐
net.core.netdev_budget = 50000
net.core.netdev_budget_usecs = 5000

# --- TCP协议优化 (针对德国->中国跨境高延迟链路) ---
# SYN Flood攻击防护,必须开启
net.ipv4.tcp_syncookies = 1
# TIME_WAIT状态端口复用,加速端口回收(仅出站有效)
net.ipv4.tcp_tw_reuse = 1
# FIN_WAIT_2状态超时时间,15秒快速回收
net.ipv4.tcp_fin_timeout = 15
# 【关键优化】禁用空闲后慢启动,保持连接高速率(跨境长连接必需)
net.ipv4.tcp_slow_start_after_idle = 0
# TCP保活探测间隔,5分钟(个人设备稳定)
net.ipv4.tcp_keepalive_time = 300
# 保活探测次数
net.ipv4.tcp_keepalive_probes = 3
# 保活探测间隔(秒)
net.ipv4.tcp_keepalive_intvl = 15
# TCP时间戳,用于RTT测量和防序列号回绕
net.ipv4.tcp_timestamps = 1
# 选择性确认,提升丢包恢复效率
net.ipv4.tcp_sack = 1
# 窗口缩放,支持高带宽延迟积网络
net.ipv4.tcp_window_scaling = 1
# 不保存连接指标缓存,每次连接独立优化
net.ipv4.tcp_no_metrics_save = 1

# --- TCP内存自动调优 (按内存页4KB计算) ---
# 8GB内存个人场景: 最小8MB,压力16MB,最大32MB
# 格式: min压力值 max压力值 绝对上限值 (单位:页)
net.ipv4.tcp_mem = 2097152 4194304 8388608
# 单连接接收缓冲: 最小4KB,默认1MB,最大128MB
net.ipv4.tcp_rmem = 4096 1048576 134217728
# 单连接发送缓冲: 最小4KB,默认1MB,最大128MB
net.ipv4.tcp_wmem = 4096 1048576 134217728

# --- 拥塞控制算法 (Debian 12 6.1内核支持BBRv3) ---
# 队列管理算法,fq_codel比fq更适合现代内核
net.core.default_qdisc = fq_codel
# BBR算法: 适应高延迟丢包链路,提升跨境吞吐
net.ipv4.tcp_congestion_control = bbr

# --- UDP协议优化 (HY2/Hysteria2基于UDP) ---
# UDP最小接收缓冲16KB
net.ipv4.udp_rmem_min = 16384
# UDP最小发送缓冲16KB
net.ipv4.udp_wmem_min = 16384
# UDP总体内存: 最小8MB,压力16MB,最大32MB
net.ipv4.udp_mem = 2097152 4194304 8388608

# --- 连接跟踪表优化 (conntrack) ---
# 最大连接跟踪条目数(个人场景保守)
net.netfilter.nf_conntrack_max = 65536
# 已建立TCP连接超时: 5分钟(缩短省内存)
net.netfilter.nf_conntrack_tcp_timeout_established = 300
# UDP流超时: 60秒
net.netfilter.nf_conntrack_udp_timeout = 60
# UDP流持续超时: 2分钟
net.netfilter.nf_conntrack_udp_timeout_stream = 120

# --- 安全加固 ---
# 忽略ICMP广播请求,防Smurf攻击
net.ipv4.icmp_echo_ignore_broadcasts = 1
# 忽略伪造ICMP错误
net.ipv4.icmp_ignore_bogus_error_responses = 1
# 禁用ICMP重定向接受(防MITM)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
# 禁用ICMP重定向发送
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOF

# 应用sysctl配置
log_info "应用内核参数..."
if sysctl --system >/dev/null 2>&1; then
    log_info "内核参数应用成功"
else
    log_warn "部分参数可能未生效(在LXC容器中常见),继续执行"
fi

# ===== 步骤3: 文件描述符与进程限制 ============================================
log_step "[3/7] 配置文件描述符与进程数限制..."

log_info "配置 /etc/security/limits.conf"

cat > /etc/security/limits.conf << 'EOF'
# ==============================================================================
# 系统资源限制配置 - 针对高并发代理节点
# ==============================================================================

# 所有用户
* soft nofile 100000    # 软限制: 打开文件数
* hard nofile 100000    # 硬限制: 打开文件数
* soft nproc 65535      # 软限制: 进程数
* hard nproc 65535      # 硬限制: 进程数

# root用户(确保服务进程生效)
root soft nofile 100000
root hard nofile 100000
EOF

# systemd全局限制配置
log_info "配置 systemd 全局限制..."

mkdir -p /etc/systemd/system.conf.d/

cat > /etc/systemd/system.conf.d/limits.conf << 'EOF'
[Manager]
# 默认文件描述符限制
DefaultLimitNOFILE=100000
# 默认进程数限制
DefaultLimitNPROC=65535
EOF

# 重新加载systemd配置
systemctl daemon-reexec
log_info "systemd 配置已更新"

# ===== 步骤4: 网卡高级特性优化 ================================================
log_step "[4/7] 优化网卡硬件卸载特性..."

# 自动检测默认网卡接口
IFACE=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' | head -n1)

# 如果检测失败,默认使用eth0
if [ -z "$IFACE" ]; then
    IFACE="eth0"
    log_warn "未能自动检测网卡,默认使用 eth0"
else
    log_info "检测到网卡接口: $IFACE"
fi

# 检查网卡是否存在且ethtool可用
if [ -d "/sys/class/net/$IFACE" ] && command -v ethtool >/dev/null 2>&1; then
    log_info "尝试开启网卡硬件卸载特性(GRO/GSO/TSO)..."
    
    # GRO(Generic Receive Offload): 合并小包,减少CPU中断
    ethtool -K "$IFACE" gro on 2>/dev/null || log_warn "GRO 开启失败(可能不支持)"
    
    # GSO(Generic Segmentation Offload): 延迟分片,提升吞吐
    ethtool -K "$IFACE" gso on 2>/dev/null || log_warn "GSO 开启失败(可能不支持)"
    
    # TSO(TCP Segmentation Offload): 硬件TCP分片
    ethtool -K "$IFACE" tso on 2>/dev/null || log_warn "TSO 开启失败(可能不支持)"
    
    log_info "网卡优化完成(部分特性可能因虚拟化不支持)"
else
    log_warn "跳过网卡优化(ethtool不可用或接口不存在)"
fi

# ===== 步骤5: 日志轮转配置 ====================================================
log_step "[5/7] 配置 sing-box 日志轮转..."

# 创建日志目录
mkdir -p /var/log/sing-box

# 配置logrotate,防止日志占满磁盘
cat > /etc/logrotate.d/sing-box << 'EOF'
/var/log/sing-box/*.log {
    # 每天轮转
    daily
    # 保留7天
    rotate 7
    # 压缩旧日志
    compress
    # 延迟压缩(最近一个未压缩)
    delaycompress
    # 日志不存在不报错
    missingok
    # 空日志不轮转
    notifempty
    # 权限设置
    create 0644 root root
    # 轮转后尝试通知sing-box(如运行中)
    postrotate
        /bin/kill -HUP $(cat /var/run/sing-box/sing-box.pid 2>/dev/null) 2>/dev/null || true
    endscript
}
EOF

log_info "日志轮转配置完成(保存7天,自动压缩)"

# ===== 步骤6: 防火墙配置 ======================================================
log_step "[6/7] 配置 UFW 防火墙..."

log_info "重置 UFW 到安全默认状态..."
# 静默重置,清除旧规则
ufw --force reset >/dev/null 2>&1 || true

log_info "设置默认策略..."
# 默认拒绝所有入站
ufw default deny incoming
# 默认允许所有出站
ufw default allow outgoing

log_info "添加 SSH 允许规则(防止断开连接)..."
# 必须保留SSH端口,否则可能失去连接
ufw allow 22/tcp comment 'SSH远程管理'

# 注意: sing-box端口(443/8443)暂不开启,部署后手动添加
# ufw allow 443/tcp comment 'HY2/VLESS TLS'
# ufw allow 443/udp comment 'HY2 QUIC/UDP'
# ufw allow 8443/tcp comment 'VLESS备用端口'

log_info "启用防火墙..."
ufw --force enable

log_info "防火墙已启用(当前仅允许SSH, sing-box端口后续添加)"

# ===== 步骤7: 验证与总结 ======================================================
log_step "[7/7] 验证优化结果..."

echo ""
echo "=================================================================="
echo "                        优化结果验证"
echo "=================================================================="

# 验证BBR状态
BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [ "$BBR_STATUS" = "bbr" ]; then
    echo -e "  [${GREEN}成功${NC}] BBR拥塞控制算法: ${GREEN}已启用 (bbr)${NC}"
    echo "           说明: 适用于高延迟跨境链路,提升吞吐"
else
    echo -e "  [${YELLOW}警告${NC}] BBR状态: ${YELLOW}$BBR_STATUS${NC}"
    echo "           说明: 内核可能不支持BBR,将使用默认cubic算法"
fi
echo ""

# 验证慢启动禁用
SLOW_START=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo "unknown")
if [ "$SLOW_START" = "0" ]; then
    echo -e "  [${GREEN}成功${NC}] TCP慢启动禁用: ${GREEN}已禁用${NC}"
    echo "           说明: 长连接保持高速率,跨境场景关键优化"
else
    echo -e "  [${YELLOW}警告${NC}] TCP慢启动: ${YELLOW}当前值=$SLOW_START${NC}"
    echo "           说明: 建议禁用以提升长连接性能"
fi
echo ""

# 验证缓冲区大小
RMEM=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
if [ "$RMEM" = "268435456" ]; then
    echo -e "  [${GREEN}成功${NC}] 接收缓冲区上限: ${GREEN}256MB${NC}"
    echo "           说明: 适配1Gbps高带宽,减少瓶颈"
else
    echo -e "  [${YELLOW}警告${NC}] 接收缓冲区: ${YELLOW}$(echo $RMEM | awk '{print $1/1048576 "MB"}')${NC}"
fi

WMEM=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "0")
if [ "$WMEM" = "268435456" ]; then
    echo -e "  [${GREEN}成功${NC}] 发送缓冲区上限: ${GREEN}256MB${NC}"
else
    echo -e "  [${YELLOW}警告${NC}] 发送缓冲区: ${YELLOW}$(echo $WMEM | awk '{print $1/1048576 "MB"}')${NC}"
fi
echo ""

# 验证文件描述符
FD_LIMIT=$(ulimit -n)
if [ "$FD_LIMIT" = "100000" ] || [ "$FD_LIMIT" -ge 100000 ]; then
    echo -e "  [${GREEN}成功${NC}] 文件描述符限制: ${GREEN}$FD_LIMIT${NC}"
    echo "           说明: 支持高并发连接"
else
    echo -e "  [${YELLOW}警告${NC}] 文件描述符限制: ${YELLOW}$FD_LIMIT${NC}"
    echo "           说明: 当前限制较低,可能影响并发"
fi
echo ""

# 验证防火墙
if ufw status | grep -q "Status: active"; then
    echo -e "  [${GREEN}成功${NC}] UFW防火墙状态: ${GREEN}已启用${NC}"
    echo "           说明: 基础防护已生效"
    # 显示当前规则
    echo "           当前规则:"
    ufw status numbered | grep -E "(^\[|To\s+Action)" | head -5 | sed 's/^/                    /'
else
    echo -e "  [${YELLOW}警告${NC}] UFW防火墙: ${YELLOW}未启用${NC}"
fi
echo ""

# 验证连接跟踪
CONNTRACK_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "unknown")
echo "  [信息] 连接跟踪表上限: $CONNTRACK_MAX"

echo "=================================================================="
echo ""

# 最终提示
log_info "系统优化完成!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "                         后续操作指南"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  【必须操作】"
echo "    1. 重启系统确保所有配置持久化:"
echo "       ${YELLOW}reboot${NC}"
echo ""
echo "    2. 重启后验证关键参数:"
echo "       ${YELLOW}sysctl net.ipv4.tcp_congestion_control${NC}"
echo "       ${YELLOW}sysctl net.ipv4.tcp_slow_start_after_idle${NC}"
echo "       ${YELLOW}ulimit -n${NC}"
echo ""
echo "  【sing-box部署后操作】"
echo "    3. 开放防火墙端口(根据实际配置):"
echo "       ${YELLOW}ufw allow 443/tcp comment 'HY2/VLESS'${NC}"
echo "       ${YELLOW}ufw allow 443/udp comment 'HY2 UDP'${NC}"
echo "       ${YELLOW}ufw allow 8443/tcp comment 'VLESS备用'${NC}"
echo ""
echo "  【常用监控命令】"
echo "    查看实时连接数: ${YELLOW}ss -s${NC}"
echo "    查看内存使用:   ${YELLOW}free -h${NC}"
echo "    查看网络统计:   ${YELLOW}ip -s link show $IFACE${NC}"
echo "    查看conntrack:  ${YELLOW}sysctl net.netfilter.nf_conntrack_count${NC}"
echo "    查看BBR状态:    ${YELLOW}sysctl net.ipv4.tcp_congestion_control${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
