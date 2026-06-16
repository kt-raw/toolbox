#!/bin/bash
#
# VPS 三网测速系统
# ivpsr.com
# 支持三网测速 / 单节点测试 / 多节点批量测试
#

# set -e 已禁用：jq/speedtest-cli 等命令的失败不应导致脚本退出

########## 配色 ##########
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[0;37m'
PLAIN='\033[0m'

########## 路径配置 ##########
NODES_JSON="nodes.json"

# GitHub 节点库地址
NODES_URL="https://raw.githubusercontent.com/kt-raw/toolbox/main/nodes.json"

########## 工具函数 ##########

# 运营商类型 → 中文名
type_cn() {
    case $1 in
        telecom) echo "电信" ;;
        unicom)  echo "联通" ;;
        mobile)  echo "移动" ;;
        *)       echo "$1" ;;
    esac
}

# 延迟安装依赖（仅在缺失时触发一次 apt update）
NEED_UPDATE=false

ensure_cmd() {
    local name=$1 cmd=$2 pkg=$3
    if ! command -v "$cmd" &>/dev/null; then
        if [ "$NEED_UPDATE" = false ]; then
            apt update -y >/dev/null 2>&1
            NEED_UPDATE=true
        fi
        echo -e "${YELLOW}[INSTALL] ${name}${PLAIN}"
        apt install -y "$pkg" >/dev/null 2>&1
    fi
}

# 带宽 bytes/s → Mbps（保留2位小数）
# 输出: "143.80" 或 "失败"
to_mbps() {
    local bps=$1
    if [ -z "$bps" ] || [ "$bps" = "null" ]; then
        echo "失败"
    else
        local val
        val=$(echo "scale=2; $bps / 125000" | bc 2>/dev/null)
        if [ "${val:0:1}" = "." ]; then
            val="0${val}"
        fi
        echo "$val"
    fi
}

# 格式化延迟值（保留2位小数）
# 输出: "59.10" 或 "-"
fmt_lat() {
    local val=$1
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        echo "-"
    else
        local f
        f=$(printf "%.2f" "$val" 2>/dev/null) || { echo "-"; return; }
        echo "$f"
    fi
}

# 格式化抖动值（保留2位小数）
# 输出: "39.60" 或 "-"
fmt_jit() {
    local val=$1
    if [ -z "$val" ] || [ "$val" = "null" ] || [ "$val" = "-" ]; then
        echo "-"
    else
        local f
        f=$(printf "%.2f" "$val" 2>/dev/null) || { echo "-"; return; }
        echo "$f"
    fi
}

# 打印测速结果表格行（配色与截图一致，全部左对齐）
# 颜色: 节点=黄色, 下载=绿色, 上传=青色, 延迟=蓝色, 抖动=紫色
# 列宽: 节点名32 / 下载值+单位12 / 上传值+单位12 / 延迟值+单位10 / 抖动值+单位9
print_row() {
    local line="$1"
    local node="$2"
    local dl_val="$3"
    local ul_val="$4"
    local lat_val="$5"
    local jit_val="$6"
    # 先纯文本格式化，再 echo -e 包裹颜色
    printf -v _c1 "%-32s" "${line} ${node}"
    printf -v _c2 "%-12s" "${dl_val} Mbps"
    printf -v _c3 "%-12s" "${ul_val} Mbps"
    printf -v _c4 "%-10s" "${lat_val} ms"
    printf -v _c5 "%-9s"  "${jit_val} ms"
    echo -e "${YELLOW}${_c1}${PLAIN}   ${GREEN}${_c2}${PLAIN}   ${CYAN}${_c3}${PLAIN}   ${BLUE}${_c4}${PLAIN}   ${PURPLE}${_c5}${PLAIN}"
}

print_header() {
    echo -e "${GREEN}---------------------------------------------------------------------------------${PLAIN}"
    # 先纯文本格式化，再 echo -e 包裹颜色
    printf -v _h1 "%-32s" "测速节点"
    printf -v _h2 "%-12s" "下载/Mbps"
    printf -v _h3 "%-12s" "上传/Mbps"
    printf -v _h4 "%-10s" "延迟/ms"
    printf -v _h5 "%-9s"  "抖动/ms"
    echo -e "${WHITE}${_h1}${PLAIN}   ${WHITE}${_h2}${PLAIN}   ${WHITE}${_h3}${PLAIN}   ${WHITE}${_h4}${PLAIN}   ${WHITE}${_h5}${PLAIN}"
}

########## 初始化 ##########

init_deps() {
    echo -e "${CYAN}[1/3] 检查依赖...${PLAIN}"
    ensure_cmd "curl" curl curl
    ensure_cmd "jq"   jq   jq
    ensure_cmd "bc"   bc   bc

    if ! command -v speedtest &>/dev/null; then
        if [ "$NEED_UPDATE" = false ]; then
            apt update -y >/dev/null 2>&1
            NEED_UPDATE=true
        fi
        echo -e "${YELLOW}[INSTALL] Ookla Speedtest CLI${PLAIN}"
        # 官方安装脚本
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash >/dev/null 2>&1
        apt install -y speedtest >/dev/null 2>&1
        speedtest --accept-license >/dev/null 2>&1
    fi
}

init_nodes() {
    echo -e "${CYAN}[2/3] 拉取节点库...${PLAIN}"
    local raw
    raw=$(curl -s --connect-timeout 10 --max-time 30 "$NODES_URL")
    if [ -z "$raw" ]; then
        echo -e "${RED}[ERROR] 节点库下载失败${PLAIN}"
        # 检查本地缓存
        if [ -f "$NODES_JSON" ] && [ -s "$NODES_JSON" ]; then
            echo -e "${YELLOW}[INFO] 使用本地缓存${PLAIN}"
        else
            echo -e "${RED}[ERROR] 无缓存可用，退出${PLAIN}"
            exit 1
        fi
        return
    fi
    # 校验 JSON 格式
    if echo "$raw" | jq '.' > "$NODES_JSON" 2>/dev/null; then
        echo -e "${GREEN}[INFO] 节点库加载完成${PLAIN}"
    else
        echo -e "${RED}[ERROR] 节点库 JSON 格式错误${PLAIN}"
        # 删除无效文件
        rm -f "$NODES_JSON"
        if [ -f "$NODES_JSON" ] && [ -s "$NODES_JSON" ]; then
            echo -e "${YELLOW}[INFO] 使用本地缓存${PLAIN}"
        else
            echo -e "${RED}[ERROR] 无缓存可用，退出${PLAIN}"
            exit 1
        fi
    fi
}

########## 核心测速 ##########

# 单个节点测速（Ookla 官方 CLI）
speed_test_node() {
    local id=$1
    local result
    result=$(timeout 70 speedtest -s "$id" -f json 2>/dev/null || true)
    echo "$result"
}

# 解析测速结果为可读字段（Ookla 官方 CLI JSON 格式）
parse_result() {
    local json=$1
    local dl ul lat jit server_name

    dl=$(echo "$json"   | jq -r '.download.bandwidth // "null"' 2>/dev/null || echo "null")
    ul=$(echo "$json"   | jq -r '.upload.bandwidth // "null"' 2>/dev/null || echo "null")
    lat=$(echo "$json"  | jq -r '.ping.latency // "null"' 2>/dev/null || echo "null")
    jit=$(echo "$json"  | jq -r '.ping.jitter // "-"' 2>/dev/null || echo "-")
    server_name=$(echo "$json" | jq -r '.server.name // "-"' 2>/dev/null || echo "-")

    echo "${server_name}|$(to_mbps "$dl")|$(to_mbps "$ul")|$(fmt_lat "$lat")|$(fmt_jit "$jit")"
}

# 单运营商测速（每个节点间隔 5s 规避限流，触发限流后间隔延长到 15s）
run_one_type() {
    local type=$1
    local cn=$(type_cn "$type")
    local cooldown=5  # 正常间隔

    local node_list
    node_list=$(jq -c ".${type}[]" "$NODES_JSON" 2>/dev/null || true)
    [ -z "$node_list" ] && return

    while read -r item; do
        [ -z "$item" ] && continue
        local name id
        name=$(echo "$item" | jq -r '.name' 2>/dev/null || true)
        id=$(echo "$item" | jq -r '.id' 2>/dev/null || true)
        [ -z "$id" ] || [ "$id" = "null" ] && continue

        local result
        result=$(speed_test_node "$id")

        # 限流检测 → 等 60 秒重试，后续节点加大间隔
        if echo "$result" | jq -e '.type == "error" and (.error | test("Too many requests"))' >/dev/null 2>&1; then
            echo -e "${RED}[限流] ${name} 触发频率限制，等待60秒...${PLAIN}"
            sleep 60
            cooldown=15
            result=$(speed_test_node "$id")
        fi

        [ -z "$result" ] && { sleep "$cooldown"; continue; }

        local parsed dl ul lat jit sname
        parsed=$(parse_result "$result")
        IFS='|' read -r sname dl ul lat jit <<< "$parsed"

        print_row "$cn" "$name" "$dl" "$ul" "$lat" "$jit"

        sleep "$cooldown"
    done <<< "$node_list"
}

# 三网测速
speedtest_all() {
    echo -e "\n${PURPLE}开始三网测速...${PLAIN}\n"
    print_header

    run_one_type "telecom"
    run_one_type "unicom"
    run_one_type "mobile"

    echo -e "${GREEN}---------------------------------------------------------------------------------${PLAIN}"
}

# 单节点手动测试
test_single_id() {
    echo ""
    read -rp "请输入 Speedtest 节点ID: " id

    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[ERROR] 请输入正确的数字ID${PLAIN}"
        return
    fi

    echo -e "\n${BLUE}[TEST] 节点ID: ${id}${PLAIN}\n"

    local result
    result=$(speed_test_node "$id")

    if [ -z "$result" ]; then
        echo -e "${RED}节点不可用或超时${PLAIN}"
        return
    fi

    local parsed dl ul lat jit sname
    parsed=$(parse_result "$result")
    IFS='|' read -r sname dl ul lat jit <<< "$parsed"

    echo -e "${GREEN}---------------------------------------------------------------------------------${PLAIN}"
    print_header

    print_row "-" "$sname" "$dl" "$ul" "$lat" "$jit"
    echo ""
}

# 多节点ID批量测试
test_multi_id() {
    echo ""
    echo -e "${PURPLE}多节点ID批量测速${PLAIN}"
    echo ""
    echo "选择输入方式:"
    echo -e "  ${CYAN}1.${PLAIN} 手动输入 名称|ID"
    echo -e "  ${CYAN}2.${PLAIN} 批量粘贴 名称|ID（一次性粘贴多行）"
    echo -e "  ${CYAN}3.${PLAIN} 从节点库搜索（输入关键字匹配节点名）"
    echo -e "  ${CYAN}4.${PLAIN} 测全部节点库节点（先快速存活检测，再完整测速）"
    echo ""
    read -rp "请选择 [1-4]: " mode

    local nodes=()

    case $mode in
        1)
            echo ""
            echo "输入格式: 名称|ID，每行一个，输入空行结束"
            echo "示例:"
            echo "  上海|3633"
            echo "  北京|5145"
            echo "  (回车结束)"
            echo ""
            local line
            while true; do
                read -rp "> " line
                [ -z "$line" ] && break
                nodes+=("$line")
            done
            ;;
        2)
            echo ""
            echo "请粘贴 名称|ID 列表（每行一个），粘贴完成后按 Ctrl+D 结束："
            echo "示例:"
            echo "  上海电信|3633"
            echo "  北京联通|5145"
            echo ""
            local line
            while IFS= read -r line; do
                line=$(echo "$line" | xargs)
                [ -z "$line" ] && continue
                nodes+=("$line")
            done
            ;;
        3)
            echo ""
            read -rp "输入关键字（支持多个，空格分隔，如: 上海 杭州 广州）: " keywords
            [ -z "$keywords" ] && { echo -e "${YELLOW}[INFO] 未输入关键字${PLAIN}"; return; }
            echo ""
            echo -e "${CYAN}[INFO] 搜索节点库...${PLAIN}"

            local matched_count=0
            for type in telecom unicom mobile; do
                local cn=$(type_cn "$type")
                local node_list
                node_list=$(jq -c ".${type}[]" "$NODES_JSON" 2>/dev/null || true)
                [ -z "$node_list" ] && continue

                while read -r item; do
                    [ -z "$item" ] && continue
                    local nid nname
                    nname=$(echo "$item" | jq -r '.name' 2>/dev/null)
                    nid=$(echo "$item" | jq -r '.id' 2>/dev/null)
                    [ -z "$nid" ] || [ "$nid" = "null" ] && continue

                    for kw in $keywords; do
                        if echo "$nname" | grep -qi "$kw"; then
                            nodes+=("${nname}|${nid}")
                            echo -e "  ${GREEN}✓${PLAIN} ${nname} (${nid})"
                            matched_count=$((matched_count + 1))
                            break
                        fi
                    done
                done <<< "$node_list"
            done

            if [ ${#nodes[@]} -eq 0 ]; then
                echo -e "${YELLOW}[INFO] 未匹配到任何节点${PLAIN}"
                return
            fi
            echo -e "${CYAN}[INFO] 共匹配 ${matched_count} 个节点${PLAIN}"
            ;;
        4)
            # 读取全部节点库，先快速存活检测
            echo ""
            echo -e "${CYAN}[INFO] 读取全部节点库...${PLAIN}"
            local all_nodes=()
            for type in telecom unicom mobile; do
                local node_list
                node_list=$(jq -c ".${type}[]" "$NODES_JSON" 2>/dev/null || true)
                [ -z "$node_list" ] && continue

                while read -r item; do
                    [ -z "$item" ] && continue
                    local nid nname
                    nname=$(echo "$item" | jq -r '.name' 2>/dev/null)
                    nid=$(echo "$item" | jq -r '.id' 2>/dev/null)
                    [ -z "$nid" ] || [ "$nid" = "null" ] && continue
                    all_nodes+=("${nname}|${nid}")
                done <<< "$node_list"
            done

            local all_total=${#all_nodes[@]}
            echo -e "${CYAN}[INFO] 共读取 ${all_total} 个节点${PLAIN}"
            echo ""

            # 阶段1：存活检测（跑完整测速，timeout 20s）
            echo -e "${PURPLE}阶段1: 存活检测（timeout 20s，间隔 1s）${PLAIN}"
            echo ""
            echo -e "${YELLOW}%-4s %-24s %8s %10s${PLAIN}" "序号" "节点" "ID" "状态"
            echo -e "${YELLOW}----------------------------------------------${PLAIN}"

            local alive_count=0
            local ai=0
            declare -A cached_results  # 缓存存活节点的测速结果
            for entry in "${all_nodes[@]}"; do
                ai=$((ai + 1))
                local nname nid
                IFS='|' read -r nname nid <<< "$entry"

                echo -ne "${ai}. ${nname} (${nid}) ... "

                local check_result
                check_result=$(timeout 20 speedtest -s "$nid" -f json 2>&1 || true)

                if [ -z "$check_result" ]; then
                    echo -e "${RED}无响应${PLAIN}"
                elif echo "$check_result" | grep -qi "Too many requests\|Limit reached"; then
                    echo -e "${YELLOW}限流${PLAIN}"
                else
                    local clat
                    clat=$(echo "$check_result" | jq -r '.ping.latency // empty' 2>/dev/null)
                    if [ -n "$clat" ] && [ "$clat" != "null" ]; then
                        local dl ul
                        dl=$(echo "$check_result" | jq -r '.download.bandwidth // 0' 2>/dev/null)
                        ul=$(echo "$check_result" | jq -r '.upload.bandwidth // 0' 2>/dev/null)
                        dl=$(awk "BEGIN {printf \"%.1f\", $dl/125000}" 2>/dev/null || echo "0")
                        ul=$(awk "BEGIN {printf \"%.1f\", $ul/125000}" 2>/dev/null || echo "0")
                        echo -e "${GREEN}存活${PLAIN} (${clat}ms, ↓${dl} ↑${ul} Mbps)"
                        nodes+=("${nname}|${nid}")
                        cached_results["${nid}"]="${check_result}"
                        alive_count=$((alive_count + 1))
                    else
                        echo -e "${RED}连接失败${PLAIN}"
                    fi
                fi
                sleep 1
            done

            echo ""
            echo -e "${YELLOW}----------------------------------------------${PLAIN}"
            echo -e "存活: ${GREEN}${alive_count}${PLAIN} / ${all_total}"

            if [ ${#nodes[@]} -eq 0 ]; then
                echo -e "${RED}[INFO] 没有存活节点，退出${PLAIN}"
                return
            fi

            echo ""
            echo -e "存活节点列表:"
            for entry in "${nodes[@]}"; do
                IFS='|' read -r nname nid <<< "$entry"
                echo -e "  ${GREEN}✓${PLAIN} ${nname} (${nid})"
            done

            echo ""
            read -rp "是否对这 ${alive_count} 个存活节点显示详细结果？[Y/n]: " confirm
            if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
                echo -e "${YELLOW}[INFO] 已取消${PLAIN}"
                return
            fi
            echo ""
            echo -e "存活节点测速结果 (已缓存，无需重新测速):"
            echo ""
            print_header

            local idx=0
            for entry in "${nodes[@]}"; do
                idx=$((idx + 1))
                local name id
                IFS='|' read -r name id <<< "$entry"

                local result="${cached_results[$id]}"
                local parsed dl ul lat jit sname
                parsed=$(parse_result "$result")
                IFS='|' read -r sname dl ul lat jit <<< "$parsed"

                print_row "-" "$name" "$dl" "$ul" "$lat" "$jit"
            done
            echo ""
            echo -e "${YELLOW}----------------------------------------------${PLAIN}"
            echo -e "${GREEN}[INFO] 完成！共 ${alive_count} 个存活节点${PLAIN}"
            return
            ;;
        *)
            echo -e "${RED}[ERROR] 无效选项${PLAIN}"
            return
            ;;
    esac

    if [ ${#nodes[@]} -eq 0 ]; then
        echo -e "${YELLOW}[INFO] 未输入任何节点${PLAIN}"
        return
    fi

    local total=${#nodes[@]}
    echo ""
    echo -e "开始批量测速 (共 ${total} 个节点)..."
    echo ""
    print_header

    local idx=0
    local cooldown=5
    for entry in "${nodes[@]}"; do
        idx=$((idx + 1))
        local name id
        IFS='|' read -r name id <<< "$entry"
        name=$(echo "$name" | xargs)
        id=$(echo "$id" | xargs)

        if [[ ! "$id" =~ ^[0-9]+$ ]]; then
            echo -e "[${idx}/${total}] ${RED}${name} (无效ID)${PLAIN}"
            continue
        fi

        local result
        result=$(speed_test_node "$id")

        if echo "$result" | jq -e '.type == "error" and (.error | test("Too many requests"))' >/dev/null 2>&1; then
            echo -e "[${idx}/${total}] ${YELLOW}${name} (${id}) 限流，等待60秒...${PLAIN}"
            sleep 60
            cooldown=15
            result=$(speed_test_node "$id")
        fi

        if [ -z "$result" ]; then
            echo -e "[${idx}/${total}] ${RED}${name} (${id}) 超时/不可用${PLAIN}"
            sleep "$cooldown"
            continue
        fi

        local parsed dl ul lat jit sname
        parsed=$(parse_result "$result")
        IFS='|' read -r sname dl ul lat jit <<< "$parsed"

        local has_latency=false
        [ "$lat" != "null" ] && [ -n "$lat" ] && has_latency=true

        if [ "$has_latency" = true ]; then
            print_row "-" "$name" "$dl" "$ul" "$lat" "$jit"
        fi

        sleep "$cooldown"
    done
    echo -e "${GREEN}---------------------------------------------------------------------------------${PLAIN}"
}

########## 菜单 ##########

show_menu() {
    echo ""
    echo -e "${YELLOW}--------------------------------------------${PLAIN}"
    echo -e "${GREEN}              VPS 三网测速系统${PLAIN}"
    echo -e "${YELLOW}--------------------------------------------${PLAIN}"
    echo ""
    echo "测速功能："
    echo -e "  ${CYAN}1.${PLAIN} 三网测速              ${CYAN}3.${PLAIN} 多节点批量测试"
    echo -e "  ${CYAN}2.${PLAIN} 单节点测速            ${CYAN}4.${PLAIN} 退出"
    echo ""
    echo -e "${YELLOW}--------------------------------------------${PLAIN}"
}

main_menu() {
    show_menu
    read -rp "请输入数字选择: " menu

    case $menu in
        1)
            speedtest_all
            ;;
        2)
            test_single_id
            ;;
        3)
            test_multi_id
            ;;
        4)
            echo -e "${YELLOW}[INFO] 已退出${PLAIN}"
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR] 无效选项${PLAIN}"
            exit 1
            ;;
    esac
}

########## 输出收尾 ##########

print_footer() {
    echo ""
    echo -e "${GREEN}------------------------------------------------------------${PLAIN}"
    echo -e "${WHITE}系统时间：${PLAIN}${GREEN}$(date -u '+%Y-%m-%d %H:%M:%S')${PLAIN} ${WHITE}UTC${PLAIN}"
    echo -e "${WHITE}北京时间：${PLAIN}${GREEN}$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')${PLAIN} ${WHITE}CST${PLAIN}"
    echo -e "${GREEN}------------------------------------------------------------${PLAIN}"
}

########## 入口 ##########

echo -e "${BLUE}==================================${PLAIN}"
echo -e "${CYAN} VPS三网测速系统${PLAIN}"
echo -e "${BLUE}==================================${PLAIN}"

init_deps
init_nodes
main_menu
print_footer
