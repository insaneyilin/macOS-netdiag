#!/usr/bin/env bash
# =============================================================================
# netdiag.sh — macOS 网络一键诊断脚本
#
# 用法: bash netdiag.sh
#
# 设计原则:
#   1. 纯 bash，仅依赖 macOS 内置命令，无需网络即可运行
#   2. 从物理层向上逐层检查 (L1→L6)，每层给出 PASS/WARN/FAIL
#   3. 输出自带中文解读，断网环境下用户可自行理解
#   4. 所有网络请求带 timeout，避免脚本卡死
#   5. 最终输出诊断摘要 + 排序后的修复建议
# =============================================================================

set -o pipefail

# ── 颜色定义 ───────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── 全局状态 ───────────────────────────────────────────────────────────────
ISSUES=()
FAIL_COUNT=0
WARN_COUNT=0
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
GATEWAY=""
WIFI_SSID=""
WIFI_CHANNEL=""
WIFI_BAND=""
WIFI_MCS=""
WIFI_TXRATE=""
WIFI_SIGNAL=""
WIFI_NOISE=""
WIFI_PHY=""
WIFI_IFACE=""

# ── 工具函数 ───────────────────────────────────────────────────────────────

fail() {
    echo -e "  ${RED}[FAIL]${NC} $*"
    ISSUES+=("FAIL: $*")
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $*"
    ISSUES+=("WARN: $*")
    WARN_COUNT=$((WARN_COUNT + 1))
}

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $*"
}

info() {
    echo -e "  ${BLUE}[INFO]${NC} $*"
}

header() {
    echo ""
    echo -e "${BOLD}=== $* ===${NC}"
}

die() {
    echo -e "${RED}[FATAL]${NC} $*"
    echo "诊断无法继续，请检查 Wi-Fi 是否已开启。"
    exit 1
}

# 安全比较浮点数
gt() { echo "$1 > $2" | bc -l 2>/dev/null | grep -q 1; }

# ── 系统检查 ───────────────────────────────────────────────────────────────

check_platform() {
    header "系统环境"
    local os
    os=$(uname -s)
    if [[ "$os" != "Darwin" ]]; then
        die "此脚本仅支持 macOS (当前系统: $os)"
    fi
    local ver
    ver=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
    local model
    model=$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Model Name|Chip/ {print $0}' | sed 's/^[[:space:]]*//' | paste -sd ", " -)
    info "macOS $ver — $model"
}

# ── L1: Wi-Fi 物理层 ────────────────────────────────────────────────────────

check_l1_phy() {
    header "L1: Wi-Fi 物理层"

    # 获取 Wi-Fi 接口
    WIFI_IFACE=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $NF}')
    if [[ -z "$WIFI_IFACE" ]]; then
        WIFI_IFACE="en0"
    fi

    # 检查接口是否活跃
    if ! ifconfig "$WIFI_IFACE" 2>/dev/null | grep -q "status: active"; then
        die "Wi-Fi 接口 ($WIFI_IFACE) 未激活"
    fi

    # 获取 Wi-Fi 详细信息
    local wifi_data
    wifi_data=$(system_profiler SPAirPortDataType 2>/dev/null)

    # SSID: "Current Network Information:" 下一行, 取第一个字段去冒号
    WIFI_SSID=$(echo "$wifi_data" | awk '/Current Network Information:/{getline; gsub(/:$/,""); gsub(/^[[:space:]]+/,""); print; exit}')
    if [[ -z "$WIFI_SSID" ]]; then
        WIFI_SSID=$(networksetup -getairportnetwork "$WIFI_IFACE" 2>/dev/null | awk -F': ' '{print $NF}')
    fi

    if [[ -z "$WIFI_SSID" || "$WIFI_SSID" == *"not associated"* ]]; then
        die "未连接到任何 Wi-Fi 网络"
    fi
    info "当前 Wi-Fi: ${BOLD}$WIFI_SSID${NC}"

    # ── 信号和噪声 ──
    # 格式: "              Signal / Noise: -61 dBm / -94 dBm"
    # awk: $1=Signal, $2=/, $3=Noise:, $4=-61, $5=dBm, $6=/, $7=-94, $8=dBm
    local sig_line
    sig_line=$(echo "$wifi_data" | grep "Signal / Noise:" | head -1)
    WIFI_SIGNAL=$(echo "$sig_line" | awk '{print $4}')
    WIFI_NOISE=$(echo "$sig_line" | awk '{print $7}')

    if [[ -n "$WIFI_SIGNAL" && "$WIFI_SIGNAL" =~ ^-?[0-9]+$ ]]; then
        local snr=$(( WIFI_SIGNAL - WIFI_NOISE ))
        if [[ "$WIFI_SIGNAL" -gt -50 ]]; then
            pass "信号强度: ${WIFI_SIGNAL} dBm, 噪声: ${WIFI_NOISE} dBm (SNR ${snr} dB, 优秀)"
        elif [[ "$WIFI_SIGNAL" -gt -65 ]]; then
            pass "信号强度: ${WIFI_SIGNAL} dBm, 噪声: ${WIFI_NOISE} dBm (SNR ${snr} dB, 良好)"
        elif [[ "$WIFI_SIGNAL" -gt -75 ]]; then
            warn "信号强度: ${WIFI_SIGNAL} dBm (SNR ${snr} dB, 偏弱) — 建议靠近路由器"
        else
            fail "信号强度: ${WIFI_SIGNAL} dBm (SNR ${snr} dB, 很弱) — 距离路由器太远或有障碍物"
        fi
    else
        warn "无法获取信号强度"
    fi

    # ── MCS Index (关键指标!) ──
    WIFI_MCS=$(echo "$wifi_data" | awk -F': ' '/MCS Index/ {print $2}' | tr -d ' ' | head -1)
    if [[ -n "$WIFI_MCS" && "$WIFI_MCS" =~ ^[0-9]+$ ]]; then
        if [[ "$WIFI_MCS" -ge 7 ]]; then
            pass "MCS Index: ${WIFI_MCS} (优秀)"
        elif [[ "$WIFI_MCS" -ge 4 ]]; then
            pass "MCS Index: ${WIFI_MCS} (正常)"
        elif [[ "$WIFI_MCS" -ge 2 ]]; then
            warn "MCS Index: ${WIFI_MCS} (偏低) — 存在一定干扰或信号衰减"
        elif [[ "$WIFI_MCS" -eq 1 ]]; then
            fail "MCS Index: ${WIFI_MCS} (极低!) — Wi-Fi 芯片已大幅降速，存在严重干扰"
        else
            fail "MCS Index: ${WIFI_MCS} (最低!) — Wi-Fi 芯片处于抢救模式，信道质量极差或路由器异常"
        fi
    else
        warn "无法获取 MCS Index"
    fi

    # ── 发射速率 ──
    WIFI_TXRATE=$(echo "$wifi_data" | awk -F': ' '/Transmit Rate/ {print $2}' | tr -d ' ' | head -1)
    if [[ -n "$WIFI_TXRATE" && "$WIFI_TXRATE" =~ ^[0-9]+$ ]]; then
        if [[ "$WIFI_TXRATE" -ge 200 ]]; then
            pass "发射速率: ${WIFI_TXRATE} Mbps (优秀)"
        elif [[ "$WIFI_TXRATE" -ge 50 ]]; then
            pass "发射速率: ${WIFI_TXRATE} Mbps (正常)"
        elif [[ "$WIFI_TXRATE" -ge 20 ]]; then
            warn "发射速率: ${WIFI_TXRATE} Mbps (偏低) — 网页浏览可能卡顿"
        else
            fail "发射速率: ${WIFI_TXRATE} Mbps (极低!) — 视频和网页都将严重卡顿"
        fi
    fi

    # ── 信道和频段 ──
    WIFI_CHANNEL=$(echo "$wifi_data" | awk -F': ' '/Channel:/ {print $2}' | head -1)
    WIFI_PHY=$(echo "$wifi_data" | awk -F': ' '/PHY Mode:/ {print $2}' | head -1)

    if [[ -n "$WIFI_CHANNEL" ]]; then
        if echo "$WIFI_CHANNEL" | grep -q "5GHz"; then
            WIFI_BAND="5GHz"
        elif echo "$WIFI_CHANNEL" | grep -q "2GHz"; then
            WIFI_BAND="2.4GHz"
        fi
        info "信道: $WIFI_CHANNEL, PHY: ${WIFI_PHY:-unknown}, 频段: ${WIFI_BAND:-unknown}"
    fi

    # ── SNR vs MCS 矛盾检测 ──
    if [[ -n "$WIFI_SIGNAL" && -n "$WIFI_MCS" && "$WIFI_MCS" =~ ^[0-9]+$ && "$WIFI_SIGNAL" =~ ^-?[0-9]+$ ]]; then
        local snr=$(( WIFI_SIGNAL - WIFI_NOISE ))
        if [[ "$snr" -ge 30 && "$WIFI_MCS" -le 1 ]]; then
            echo ""
            echo -e "  ${RED}╔══════════════════════════════════════════════╗${NC}"
            echo -e "  ${RED}║  ⚠  SNR ${snr}dB 但 MCS=${WIFI_MCS} — Wi-Fi SOS 信号      ║${NC}"
            echo -e "  ${RED}║                                            ║${NC}"
            echo -e "  ${RED}║  信号质量够用，但芯片主动降到最低速        ║${NC}"
            echo -e "  ${RED}║  最可能原因:                                ║${NC}"
            echo -e "  ${RED}║  1. 蓝牙天线分时干扰 (关蓝牙试试)          ║${NC}"
            echo -e "  ${RED}║  2. AWDL 信道切换 (sudo ifconfig awdl0 down)║${NC}"
            echo -e "  ${RED}║  3. 路由器无线芯片异常 (重启路由器)        ║${NC}"
            echo -e "  ${RED}║  4. 同信道有多个网络竞争                    ║${NC}"
            echo -e "  ${RED}╚══════════════════════════════════════════════╝${NC}"
        fi
    fi
}

# ── L2: Wi-Fi 环境干扰 ──────────────────────────────────────────────────────

check_l2_environment() {
    header "L2: Wi-Fi 环境干扰"

    # ── 信道拥塞 ──
    if [[ -n "$WIFI_CHANNEL" ]]; then
        local ch_num
        ch_num=$(echo "$WIFI_CHANNEL" | grep -oE '[0-9]+' | head -1)
        if [[ -n "$ch_num" ]]; then
            local wifi_data
            wifi_data=$(system_profiler SPAirPortDataType 2>/dev/null)

            # 统计同信道网络数 (排除 awdl0 的条目)
            local same_ch_count
            same_ch_count=$(echo "$wifi_data" | grep -c "Channel: ${ch_num} " 2>/dev/null || echo 0)

            if [[ "$same_ch_count" -ge 4 ]]; then
                warn "信道 ${ch_num} 上有 ${same_ch_count} 个 Wi-Fi 网络 — 信道拥挤"
            elif [[ "$same_ch_count" -eq 3 ]]; then
                warn "信道 ${ch_num} 上有 ${same_ch_count} 个 Wi-Fi 网络 (含自身) — 存在竞争"
            elif [[ "$same_ch_count" -le 1 ]]; then
                pass "信道 ${ch_num} 无明显竞争"
            else
                pass "信道 ${ch_num} 网络数量正常"
            fi
        fi
    fi

    # ── AWDL (Apple Wireless Direct Link) ──
    if ifconfig awdl0 2>/dev/null | grep -q "status: active"; then
        warn "AWDL 已激活 — AirDrop/AirPlay/Handoff 会周期性打断 Wi-Fi"
        info "  修复: sudo ifconfig awdl0 down  (重启后自动恢复)"
    else
        pass "AWDL 未激活"
    fi

    # ── 蓝牙 ──
    local bt_state
    bt_state=$(system_profiler SPBluetoothDataType 2>/dev/null | grep "State:" | awk -F': ' '{print $2}')
    if [[ "$bt_state" == "On" ]]; then
        local bt_chip
        bt_chip=$(system_profiler SPBluetoothDataType 2>/dev/null | grep "Chipset:" | awk -F': ' '{print $2}')
        warn "蓝牙已开启 (芯片: ${bt_chip:-unknown})"
        if [[ "$bt_chip" == *"BCM"* || "$bt_chip" == *"4388"* ]]; then
            info "  Broadcom 芯片 Wi-Fi/蓝牙共用天线，蓝牙开启会降低 Wi-Fi 性能"
            info "  修复: 系统设置 → 蓝牙 → 关闭"
        fi
    else
        pass "蓝牙已关闭"
    fi
}

# ── L3: 本机网络配置 ────────────────────────────────────────────────────────

check_l3_config() {
    header "L3: 本机网络配置"

    # ── 网关获取 ──
    GATEWAY=$(netstat -rn -f inet 2>/dev/null | awk '/^default/ {print $2; exit}')
    if [[ -z "$GATEWAY" ]]; then
        fail "无法获取默认网关 — 路由表异常"
        GATEWAY="unknown"
    else
        pass "默认网关: $GATEWAY"
    fi

    # ── DNS 配置 ──
    local dns_servers
    dns_servers=$(scutil --dns 2>/dev/null | awk '/nameserver/ {print $3}' | sort -u)
    if [[ -z "$dns_servers" ]]; then
        fail "未配置 DNS 服务器"
    else
        local dns_summary
        dns_summary=$(echo "$dns_servers" | tr '\n' ' ')
        info "DNS 服务器: $dns_summary"

        # 检查 DNS 是否被路由器代理
        local first_dns
        first_dns=$(echo "$dns_servers" | head -1)
        if [[ "$first_dns" == "$GATEWAY" || "$first_dns" == 192.168.* ]]; then
            info "DNS 指向路由器/内网，路由器可能在代理 DNS 查询"
        fi
    fi

    # ── HTTP/HTTPS/SOCKS 代理 ──
    local has_proxy=0
    for proto in webproxy securewebproxy socksfirewallproxy; do
        local status
        status=$(networksetup "-get${proto}" Wi-Fi 2>/dev/null | grep "^Enabled:" | awk '{print $2}')
        if [[ "$status" == "Yes" ]]; then
            fail "已启用 ${proto} 代理 — 所有流量经过代理服务器"
            has_proxy=1
        fi
    done
    if [[ "$has_proxy" -eq 0 ]]; then
        pass "未启用 HTTP/HTTPS/SOCKS 代理"
    fi

    # ── VPN / 网络扩展 ──
    local extensions
    extensions=$(systemextensionsctl list 2>/dev/null | grep "network_extension" | grep "activated enabled")
    if [[ -n "$extensions" ]]; then
        local ext_name
        ext_name=$(echo "$extensions" | awk -F'[()]' '{print $2}' | head -1)
        warn "检测到网络扩展: ${ext_name:-unknown} — 可能影响网络路由"
    else
        pass "未检测到活跃的 VPN 网络扩展"
    fi

    # ── MTU ──
    local mtu
    mtu=$(ifconfig "$WIFI_IFACE" 2>/dev/null | awk '/mtu/ {print $NF}')
    if [[ "$mtu" != "1500" && -n "$mtu" ]]; then
        warn "MTU: ${mtu} (标准值为 1500) — 可能导致部分网站无法访问"
    fi
}

# ── L4: 局域网连通性 ────────────────────────────────────────────────────────

check_l4_lan() {
    header "L4: 局域网连通性 (ping 网关)"

    if [[ "$GATEWAY" == "unknown" ]]; then
        fail "跳过 — 无可用网关"
        return
    fi

    info "正在 ping 网关 ($GATEWAY) 50 个包..."

    local ping_out
    ping_out=$(ping -c 50 -i 0.2 "$GATEWAY" 2>&1)
    local ping_rc=$?

    # 解析 ping 统计行: "50 packets transmitted, 50 packets received, 0.0% packet loss"
    local sent received loss_pct
    sent=$(echo "$ping_out" | awk '/packets transmitted/ {print $1}')
    received=$(echo "$ping_out" | awk '/packets transmitted/ {print $4}')

    # 找到包含 % 的字段提取丢包率
    loss_pct=$(echo "$ping_out" | awk '/packet loss/ {for(i=1;i<=NF;i++) if($i ~ /%/) {gsub(/%/,"",$i); print $i; exit}}')

    # 解析延迟统计: "round-trip min/avg/max/stddev = 2.556/2.733/3.013/0.200 ms"
    local avg min max
    local rtt_line rtt_values
    rtt_line=$(echo "$ping_out" | grep "round-trip")
    rtt_values=$(echo "$rtt_line" | awk -F'= ' '{print $2}' | sed 's/ ms//')
    min=$(echo "$rtt_values" | cut -d'/' -f1)
    avg=$(echo "$rtt_values" | cut -d'/' -f2)
    max=$(echo "$rtt_values" | cut -d'/' -f3)

    if [[ "$ping_rc" -ne 0 && -z "$loss_pct" ]]; then
        fail "ping 网关完全不通 — Wi-Fi 连接可能已中断"
        return
    fi

    echo ""
    info "发送: ${sent:-?}, 接收: ${received:-?}, 丢包: ${loss_pct:-?}%"
    info "延迟: min=${min:-?}ms, avg=${avg:-?}ms, max=${max:-?}ms"

    if [[ -n "$loss_pct" ]]; then
        if gt "$loss_pct" "50"; then
            fail "局域网丢包极严重 (${loss_pct}%) — Wi-Fi 层严重异常"
        elif gt "$loss_pct" "10"; then
            fail "局域网丢包严重 (${loss_pct}%) — Wi-Fi 层存在问题"
        elif gt "$loss_pct" "2"; then
            warn "局域网有轻微丢包 (${loss_pct}%) — 网页浏览可能偶尔卡顿"
        elif [[ "$loss_pct" == "0" || "$loss_pct" == "0.0" ]]; then
            pass "局域网连通性良好 (0% 丢包)"
        else
            pass "局域网连通性良好 (${loss_pct}% 丢包)"
        fi
    fi

    # 延迟尖峰检测
    if [[ -n "$avg" && -n "$max" ]]; then
        if gt "$max" "500"; then
            warn "检测到延迟尖峰 (max=${max}ms) — 存在间歇性干扰"
            info "  尖峰通常由 AWDL/蓝牙/信道扫描/其他设备突发流量导致"
        fi
        if gt "$avg" "50"; then
            warn "平均延迟偏高 (${avg}ms) — 正常应 <10ms"
        fi
    fi

    # ── ARP 检查 ──
    if arp -a 2>/dev/null | grep -q "$GATEWAY"; then
        pass "网关 ARP 解析正常"
    else
        warn "网关不在 ARP 表中 — 可能从未成功通信"
    fi
}

# ── L5: 互联网连通性 ────────────────────────────────────────────────────────

check_l5_wan() {
    header "L5: 互联网连通性"

    # ── ping 公网 DNS ──
    info "正在 ping 223.5.5.5 (20 个包)..."
    local ping_out
    ping_out=$(ping -c 20 -i 0.3 -W 2000 223.5.5.5 2>&1)
    local loss_pct
    loss_pct=$(echo "$ping_out" | awk '/packet loss/ {for(i=1;i<=NF;i++) if($i ~ /%/) {gsub(/%/,"",$i); print $i; exit}}')

    if [[ -n "$loss_pct" ]]; then
        if gt "$loss_pct" "50"; then
            fail "公网严重丢包 (223.5.5.5 丢包 ${loss_pct}%)"
        elif gt "$loss_pct" "10"; then
            warn "公网丢包偏高 (223.5.5.5 丢包 ${loss_pct}%)"
        else
            pass "公网连通性良好 (223.5.5.5 丢包 ${loss_pct}%)"
        fi
    else
        fail "无法 ping 通 223.5.5.5 — 可能无互联网连接"
    fi

    # ── HTTPS 连接测试 ──
    info "正在测试 HTTPS 连接到 www.baidu.com..."
    local curl_out
    curl_out=$(curl -o /dev/null -w "http=%{http_code} dns=%{time_namelookup}s tcp=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s" -s --max-time 10 "https://www.baidu.com" 2>&1)
    local curl_rc=$?

    if [[ "$curl_rc" -eq 0 ]]; then
        local http_code dns_time tcp_time tls_time total_time
        http_code=$(echo "$curl_out" | grep -oE 'http=[0-9]+' | cut -d= -f2)
        dns_time=$(echo "$curl_out" | grep -oE 'dns=[0-9.]+' | cut -d= -f2)
        tcp_time=$(echo "$curl_out" | grep -oE 'tcp=[0-9.]+' | cut -d= -f2)
        tls_time=$(echo "$curl_out" | grep -oE 'tls=[0-9.]+' | cut -d= -f2)
        total_time=$(echo "$curl_out" | grep -oE 'total=[0-9.]+' | cut -d= -f2)

        if [[ "$http_code" == "200" ]]; then
            pass "HTTPS 连接正常 (HTTP ${http_code}, 总耗时 ${total_time}s)"
        else
            warn "HTTPS 连接返回 HTTP ${http_code} (总耗时 ${total_time}s)"
        fi

        if [[ -n "$dns_time" ]] && gt "$dns_time" "3"; then
            warn "DNS 解析耗时过长 (${dns_time}s)"
        fi
        if [[ -n "$tls_time" ]] && gt "$tls_time" "1"; then
            warn "TLS 握手耗时过长 (${tls_time}s) — 丢包会导致 TLS 重传超时"
        fi
    else
        fail "HTTPS 连接失败 (curl 退出码: ${curl_rc}) — 互联网可能不可用或严重丢包"
    fi
}

# ── L6: 应用层诊断 ──────────────────────────────────────────────────────────

check_l6_app() {
    header "L6: 应用层诊断"

    # ── DNS 解析速度 ──
    info "测试 DNS 解析速度 (5次)..."
    local dns_slow=0
    for i in {1..5}; do
        local t
        t=$( { time nslookup www.baidu.com 2>/dev/null >/dev/null; } 2>&1 | grep real | awk '{print $2}')
        if [[ -n "$t" ]]; then
            local sec
            sec=$(echo "$t" | sed 's/0m//;s/s//')
            if gt "$sec" "1"; then
                dns_slow=1
                break
            fi
        fi
    done

    if [[ "$dns_slow" -eq 0 ]]; then
        pass "DNS 解析速度正常 (<1s)"
    else
        warn "DNS 解析有时偏慢 — DNS 服务器响应慢或链路丢包导致重试"
    fi

    # ── HTTP vs HTTPS 对比 ──
    info "对比 HTTP vs HTTPS 连接速度..."
    local http_time https_time
    http_time=$(curl -o /dev/null -w "%{time_total}" -s --max-time 5 "http://www.baidu.com" 2>/dev/null || echo "timeout")
    https_time=$(curl -o /dev/null -w "%{time_total}" -s --max-time 5 "https://www.baidu.com" 2>/dev/null || echo "timeout")

    info "HTTP 耗时: ${http_time}s, HTTPS 耗时: ${https_time}s"

    if [[ "$https_time" == "timeout" && "$http_time" != "timeout" ]]; then
        fail "HTTP 正常但 HTTPS 超时 — TLS 握手失败，是「Wi-Fi 间歇丢包」的典型症状"
    fi
}

# ── 诊断摘要 ────────────────────────────────────────────────────────────────

print_summary() {
    header "诊断摘要"

    local total_issues=$(( FAIL_COUNT + WARN_COUNT ))

    echo ""
    echo -e "检查时间: ${BOLD}${TIMESTAMP}${NC}"
    echo -e "Wi-Fi 网络: ${BOLD}${WIFI_SSID:-unknown}${NC}"
    echo -e "信道: ${WIFI_CHANNEL:-unknown}, 频段: ${WIFI_BAND:-unknown}"
    echo -e "MCS Index: ${WIFI_MCS:-?},  TX Rate: ${WIFI_TXRATE:-?} Mbps"
    echo -e "信号: ${WIFI_SIGNAL:-?} dBm / 噪声: ${WIFI_NOISE:-?} dBm"
    echo ""

    if [[ "$total_issues" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}✓ 所有检查通过，网络状态良好。${NC}"
        echo ""
        echo "如果仍然感觉网络慢，可能是:"
        echo "  1. 目标网站/服务器本身慢"
        echo "  2. ISP 带宽不足 (高峰期)"
        echo "  3. 路由器负载过高 (太多设备连接)"
        return
    fi

    echo -e "${YELLOW}${BOLD}发现 ${total_issues} 个问题 (${FAIL_COUNT} 严重, ${WARN_COUNT} 警告)${NC}"
    echo ""

    # ── 智能诊断建议 ──
    echo -e "${BOLD}建议修复步骤 (按优先级):${NC}"
    echo ""

    local step=1

    # 模式: SNR 正常但 MCS 极低 → 芯片 SOS
    if [[ -n "$WIFI_SIGNAL" && -n "$WIFI_MCS" && "$WIFI_MCS" =~ ^[0-9]+$ && "$WIFI_SIGNAL" =~ ^-?[0-9]+$ ]]; then
        local snr=$(( WIFI_SIGNAL - WIFI_NOISE ))
        if [[ "$snr" -ge 30 && "$WIFI_MCS" -le 1 ]]; then
            echo -e "  ${step}) ${RED}${BOLD}SNR 正常但 MCS 极低 (${WIFI_MCS}) — Wi-Fi 层的 SOS 信号${NC}"
            echo "     优先尝试: 关蓝牙 → 关 AWDL → 重启路由器 → 换 2.4GHz"
            step=$((step + 1))
            echo ""
        fi
    fi

    # 模式: 局域网丢包
    if echo "${ISSUES[@]}" | grep -q "局域网.*丢包"; then
        echo -e "  ${step}) Wi-Fi 链路丢包 → 排查物理层干扰源"
        echo "     - 关闭蓝牙: 系统设置 → 蓝牙 → 关闭"
        echo "     - 关闭 AWDL: sudo ifconfig awdl0 down"
        echo "     - 靠近路由器，减少障碍物"
        step=$((step + 1))
        echo ""
    fi

    # 模式: AWDL
    if echo "${ISSUES[@]}" | grep -q "AWDL"; then
        echo -e "  ${step}) 关闭 AWDL (AirDrop 干扰源)"
        echo "     命令: sudo ifconfig awdl0 down"
        step=$((step + 1))
        echo ""
    fi

    # 模式: 蓝牙
    if echo "${ISSUES[@]}" | grep -q "蓝牙"; then
        echo -e "  ${step}) 关闭蓝牙 (天线分时干扰)"
        echo "     方法: 系统设置 → 蓝牙 → 关闭"
        step=$((step + 1))
        echo ""
    fi

    # 模式: 信道拥挤
    if echo "${ISSUES[@]}" | grep -q "信道.*拥挤\|信道.*竞争"; then
        echo -e "  ${step}) 当前信道拥挤 → 尝试切到 2.4GHz 或重启路由器换信道"
        step=$((step + 1))
        echo ""
    fi

    # 模式: 代理/VPN
    if echo "${ISSUES[@]}" | grep -q "代理\|VPN\|网络扩展"; then
        echo -e "  ${step}) 关闭 VPN/代理 — 系统设置 → 网络 → Wi-Fi → 详情 → 代理"
        step=$((step + 1))
        echo ""
    fi

    # 兜底建议
    echo -e "  ${step}) 重启路由器 (拔电源 30 秒再插上)"
    step=$((step + 1))
    echo -e "  ${step}) 终极诊断: 手机热点测试"
    echo "     - 热点流畅 = 路由器问题 (换信道/重启/报修)"
    echo "     - 热点也卡 = Mac 硬件问题 (送修 Apple Store)"

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  完整原理和操作文档: network-diagnosis-guide.md${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
}

# ── 主流程 ──────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║       macOS 网络诊断工具 v1.0               ║${NC}"
    echo -e "${BOLD}${BLUE}║       诊断开始 — ${TIMESTAMP}          ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"

    check_platform
    check_l1_phy
    check_l2_environment
    check_l3_config
    check_l4_lan
    check_l5_wan
    check_l6_app
    print_summary

    echo ""
    echo "诊断完成。"
}

main "$@"
