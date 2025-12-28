#!/bin/bash
# =============================================================================
# Did-It-Work? - Task Notification Wrapper
#
# 任务完成了吗？用 BARK 推送告诉你！
# 支持：正常完成、异常退出、手动中断（Ctrl+C）的实时通知
#
# 使用方法（单任务）：
#   ./task_with_notification.sh "<your_command>" [args...]
#   NO_PIPE=1 ./task_with_notification.sh "<your_command>" [args...]
# 使用方法（Multi-task）：
#   ./task_with_notification.sh --tasks-file tasks.txt [--continue-on-failure]
#   tasks.txt 中每行一条命令，支持 # 注释与空行
#   可选：NO_PIPE=1 对所有任务禁用管道日志捕获
#   可选：--dry-run 仅打印即将执行的任务队列
#   默认遇到失败或中断停止队列，可用 --continue-on-failure 忽略失败继续
# 配置：
#   在同目录创建 .bark_config 文件，内容为：
#   BARK_DEVICE_KEY="your_bark_device_key"
#   BARK_SERVER="https://api.day.app"  # 可选，默认值
#
# 更多信息：查看 README.md
# =============================================================================

set -o pipefail  # 管道中任何命令失败都会导致整个管道失败

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# 配置加载
# =============================================================================

# 获取脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CONFIG_FILE="${SCRIPT_DIR}/.bark_config"

# 加载配置文件
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo -e "${GREEN}✓ Loaded BARK config from: $CONFIG_FILE${NC}"
else
    echo -e "${YELLOW}⚠ Config file not found: $CONFIG_FILE${NC}"
    echo -e "${YELLOW}  Creating template config file...${NC}"
    cat > "$CONFIG_FILE" << 'EOF'
# BARK 推送配置
# 获取你的 device key: https://bark.day.app/
BARK_DEVICE_KEY="your_bark_device_key_here"
BARK_SERVER="https://api.day.app"
EOF
    echo -e "${RED}✗ Please edit $CONFIG_FILE with your BARK device key${NC}"
    exit 1
fi

# 设置默认值
BARK_SERVER="${BARK_SERVER:-https://api.day.app}"

# 验证配置
if [ -z "$BARK_DEVICE_KEY" ] || [ "$BARK_DEVICE_KEY" = "your_bark_device_key_here" ]; then
    echo -e "${RED}✗ BARK_DEVICE_KEY not configured in $CONFIG_FILE${NC}"
    exit 1
fi

# =============================================================================
# 全局变量
# =============================================================================

HOSTNAME=$(hostname)
ERROR_LOG_DIR="./error_logs"
mkdir -p "$ERROR_LOG_DIR"

TASKS=()
TASKS_FILE=""
CONTINUE_ON_FAILURE=0
DRY_RUN=0
STOP_ALL=0
LAST_SIGNAL=""

# =============================================================================
# 帮助与参数解析
# =============================================================================

print_usage() {
    cat << 'EOF'
用法：
  ./task_with_notification.sh "<command>" [args...]
  ./task_with_notification.sh --tasks-file tasks.txt [--continue-on-failure] [--dry-run]

可选：
  --tasks-file <file>     Multi-task mode，文件中每行一条命令，忽略空行与以 # 开头的行
  --continue-on-failure   遇到失败继续执行后续任务（默认失败停止）
  --dry-run               仅打印解析到的任务，不执行
  -h, --help              显示本帮助

环境变量：
  NO_PIPE=1  禁用管道捕获（适用于不希望 tee/grep 干预的命令）
EOF
}

load_tasks_from_file() {
    local file_path="$1"
    if [ ! -f "$file_path" ]; then
        echo -e "${RED}✗ Tasks file not found: ${file_path}${NC}"
        exit 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        # 去除前后空白
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

        # 跳过空行和注释
        if [ -z "$trimmed" ] || [[ "$trimmed" =~ ^# ]]; then
            continue
        fi

        TASKS+=("$trimmed")
    done < "$file_path"

    if [ ${#TASKS[@]} -eq 0 ]; then
        echo -e "${RED}✗ No valid tasks found in ${file_path}${NC}"
        exit 1
    fi
}

# =============================================================================
# BARK 推送函数
# =============================================================================

urlencode() {
    local string="$1"
    local encoded=""
    
    # 使用 xxd 将字符串转换为十六进制，然后格式化为 %xx
    encoded=$(echo -n "$string" | xxd -plain | tr -d '\n' | sed 's/\(..\)/%\1/g')
    
    echo "${encoded}"
}

send_bark_notification() {
    local title="$1"
    local body="$2"
    local level="${3:-active}"  # active, timeSensitive, passive
    
    title=$(urlencode "$title")
    body=$(urlencode "$body")
    
    # 发送推送
    local url="${BARK_SERVER}/${BARK_DEVICE_KEY}/${title}/${body}?level=${level}"
    
    echo -e "${GREEN}📲 Sending BARK notification...${NC}"
    response=$(curl -s -w "\n%{http_code}" "$url")
    http_code=$(echo "$response" | tail -n1)
    
    if [ "$http_code" = "200" ]; then
        echo -e "${GREEN}✓ Notification sent successfully${NC}"
    else
        echo -e "${RED}✗ Failed to send notification (HTTP $http_code)${NC}"
    fi
}

# =============================================================================
# 清理和通知函数
# =============================================================================

cleanup_and_notify() {
    local exit_code="$1"
    local start_time="$2"
    local error_log="$3"
    local task_command="$4"
    local task_index="$5"
    local total_tasks="$6"
    local is_multi="$7"

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local duration_formatted
    duration_formatted=$(printf '%02d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))

    local error_msg=""
    if [ -n "$error_log" ] && [ -s "$error_log" ]; then
        error_msg=$(tail -n 50 "$error_log" | head -n 20)
    fi

    local exit_reason="unknown"
    if [ "$exit_code" -eq 0 ]; then
        exit_reason="success"
    elif [ "$exit_code" -eq 130 ] || [ "$exit_code" -eq 143 ]; then
        exit_reason="interrupted"
    else
        exit_reason="error"
    fi

    local progress=""
    if [ "$is_multi" -eq 1 ]; then
        progress="${task_index}/${total_tasks}"
    fi

    local title
    local body
    local level

    case "$exit_reason" in
        success)
            title="✅ Task Completed"
            [ -n "$progress" ] && title="${title} [${progress}]"
            body="Host: ${HOSTNAME}
Duration: ${duration_formatted}
Command: ${task_command}"
            if [ -n "$progress" ]; then
                body="${body}
Mode: Multi-task
Progress: ${progress}"
            fi
            level="active"
            echo -e "${GREEN}========================================${NC}"
            echo -e "${GREEN}Task completed successfully!${NC}"
            echo -e "${GREEN}Duration: ${duration_formatted}${NC}"
            [ -n "$progress" ] && echo -e "${GREEN}Progress: ${progress}${NC}"
            echo -e "${GREEN}========================================${NC}"
            ;;
        interrupted)
            title="⚠️ Task Interrupted"
            [ -n "$progress" ] && title="${title} [${progress}]"
            body="Host: ${HOSTNAME}
Duration: ${duration_formatted}
Reason: Manual interruption (Ctrl+C)"
            if [ -n "$progress" ]; then
                body="${body}
Mode: Multi-task
Progress: ${progress}"
            fi
            level="timeSensitive"
            echo -e "${YELLOW}========================================${NC}"
            echo -e "${YELLOW}Task interrupted by user${NC}"
            echo -e "${YELLOW}Duration: ${duration_formatted}${NC}"
            [ -n "$progress" ] && echo -e "${YELLOW}Progress: ${progress}${NC}"
            echo -e "${YELLOW}========================================${NC}"
            ;;
        error)
            title="❌ Task Failed"
            [ -n "$progress" ] && title="${title} [${progress}]"
            body="Host: ${HOSTNAME}
Duration: ${duration_formatted}
Exit Code: ${exit_code}"
            if [ -n "$progress" ]; then
                body="${body}
Mode: Multi-task
Progress: ${progress}"
            fi

            if [ -n "$error_msg" ]; then
                local error_preview
                error_preview=$(echo "$error_msg" | head -n 5 | cut -c 1-200)
                body="${body}

Error Preview:
${error_preview}"
            fi

            level="timeSensitive"
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}Task failed with exit code: ${exit_code}${NC}"
            echo -e "${RED}Duration: ${duration_formatted}${NC}"
            [ -n "$progress" ] && echo -e "${RED}Progress: ${progress}${NC}"
            if [ -n "$error_msg" ]; then
                echo -e "${RED}Error log saved to: ${error_log}${NC}"
                echo -e "${RED}Last error lines:${NC}"
                echo "$error_msg"
            fi
            echo -e "${RED}========================================${NC}"
            ;;
    esac

    send_bark_notification "$title" "$body" "$level"

    if [ -n "$error_log" ]; then
        if [ "$exit_reason" = "success" ]; then
            rm -f "$error_log"
        else
            if [ ! -s "$error_log" ]; then
                rm -f "$error_log"
            fi
        fi
    fi

    return "$exit_code"
}

# =============================================================================
# =============================================================================
# 任务执行与信号处理
# =============================================================================

on_interrupt() {
    STOP_ALL=1
    LAST_SIGNAL="INT"
}

on_terminate() {
    STOP_ALL=1
    LAST_SIGNAL="TERM"
}

trap 'on_interrupt' INT
trap 'on_terminate' TERM

run_task() {
    local task_command="$1"
    local task_index="$2"
    local total_tasks="$3"
    local is_multi="$4"

    local start_time
    start_time=$(date +%s)
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local error_log="${ERROR_LOG_DIR}/task_error_${timestamp}_${task_index}.log"

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Did-It-Work? 🤔${NC}"
    echo -e "${GREEN}Task notification enabled via BARK${NC}"
    echo -e "${GREEN}Host: ${HOSTNAME}${NC}"
    if [ "$is_multi" -eq 1 ]; then
        echo -e "${GREEN}Mode: Multi-task (${task_index}/${total_tasks})${NC}"
    else
        echo -e "${GREEN}Mode: Single-task${NC}"
    fi
    echo -e "${GREEN}Command: ${task_command}${NC}"
    echo -e "${GREEN}Start time: $(date)${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    local exit_status=0
    if [ -n "$NO_PIPE" ]; then
        eval "$task_command"
        exit_status=$?
    else
        eval "$task_command" 2>&1 | tee >(grep -i "error\|exception\|traceback\|failed" > "$error_log" || true)
        exit_status=${PIPESTATUS[0]}
    fi

    cleanup_and_notify "$exit_status" "$start_time" "$error_log" "$task_command" "$task_index" "$total_tasks" "$is_multi"
    return "$exit_status"
}

# =============================================================================
# 参数解析与主流程
# =============================================================================

# 解析选项
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tasks-file)
            TASKS_FILE="$2"
            shift 2
            ;;
        --continue-on-failure)
            CONTINUE_ON_FAILURE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

if [ -n "$TASKS_FILE" ]; then
    load_tasks_from_file "$TASKS_FILE"
else
    TASK_COMMAND="$*"
    if [ -z "$TASK_COMMAND" ]; then
        print_usage
        exit 1
    fi
    TASKS+=("$TASK_COMMAND")
fi

TOTAL_TASKS=${#TASKS[@]}
if [ "$TOTAL_TASKS" -eq 0 ]; then
    print_usage
    exit 1
fi

IS_MULTI=0
if [ -n "$TASKS_FILE" ] || [ "$TOTAL_TASKS" -gt 1 ]; then
    IS_MULTI=1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}Dry run mode. Tasks to execute:${NC}"
    for idx in "${!TASKS[@]}"; do
        printf "  [%d/%d] %s\n" $((idx + 1)) "$TOTAL_TASKS" "${TASKS[$idx]}"
    done
    exit 0
fi

OVERALL_STATUS=0
for idx in "${!TASKS[@]}"; do
    if [ "$STOP_ALL" -eq 1 ]; then
        echo -e "${YELLOW}Stop signal received, skipping remaining tasks.${NC}"
        if [ "$OVERALL_STATUS" -eq 0 ]; then
            OVERALL_STATUS=130
        fi
        break
    fi

    task_number=$((idx + 1))
    run_task "${TASKS[$idx]}" "$task_number" "$TOTAL_TASKS" "$IS_MULTI"
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        OVERALL_STATUS=$exit_code
        if [ "$CONTINUE_ON_FAILURE" -ne 1 ]; then
            echo -e "${YELLOW}Stopping queue due to failure/interruption at task ${task_number}/${TOTAL_TASKS}${NC}"
            break
        fi
    fi

    if [ "$STOP_ALL" -eq 1 ]; then
        echo -e "${YELLOW}Stop signal received, ending remaining tasks.${NC}"
        break
    fi
done

exit "$OVERALL_STATUS"
