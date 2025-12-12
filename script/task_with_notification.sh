#!/bin/bash
# =============================================================================
# Did-It-Work? - Task Notification Wrapper
#
# 任务完成了吗？用 BARK 推送告诉你！
# 支持：正常完成、异常退出、手动中断（Ctrl+C）的实时通知
#
# 使用方法：
#   ./task_with_notification.sh "<your_command>" [args...]
#   NO_PIPE=1 ./task_with_notification.sh "<your_command>" [args...]
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

TASK_COMMAND="$@"
if [ -z "$TASK_COMMAND" ]; then
    echo -e "${RED}✗ Usage: $0 <command> [args...]${NC}"
    exit 1
fi

START_TIME=$(date +%s)
HOSTNAME=$(hostname)

# 创建错误日志目录（在当前目录下）
ERROR_LOG_DIR="./error_logs"
mkdir -p "$ERROR_LOG_DIR"

# 使用时间戳命名错误日志
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ERROR_LOG="${ERROR_LOG_DIR}/task_error_${TIMESTAMP}.log"

EXIT_STATUS=0
EXIT_REASON="unknown"

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
    local exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local duration_formatted=$(printf '%02d:%02d:%02d' $((duration/3600)) $((duration%3600/60)) $((duration%60)))
    
    # 读取错误日志
    local error_msg=""
    if [ -s "$ERROR_LOG" ]; then
        # 只取最后50行，避免消息过长
        error_msg=$(tail -n 50 "$ERROR_LOG" | head -n 20)
    fi
    
    # 确定退出状态
    if [ $exit_code -eq 0 ]; then
        EXIT_REASON="success"
    elif [ $exit_code -eq 130 ]; then
        EXIT_REASON="interrupted"  # Ctrl+C
    else
        EXIT_REASON="error"
    fi
    
    # 构建通知内容
    local title
    local body
    local level
    
    case "$EXIT_REASON" in
        success)
            title="✅ Task Completed"
            body="Host: ${HOSTNAME}
Duration: ${duration_formatted}
Command: ${TASK_COMMAND}"
            level="active"
            echo -e "${GREEN}========================================${NC}"
            echo -e "${GREEN}Task completed successfully!${NC}"
            echo -e "${GREEN}Duration: ${duration_formatted}${NC}"
            echo -e "${GREEN}========================================${NC}"
            ;;
        interrupted)
            title="⚠️ Task Interrupted"
            body="Host: ${HOSTNAME}
Duration: ${duration_formatted}
Reason: Manual interruption (Ctrl+C)"
            level="timeSensitive"
            echo -e "${YELLOW}========================================${NC}"
            echo -e "${YELLOW}Task interrupted by user${NC}"
            echo -e "${YELLOW}Duration: ${duration_formatted}${NC}"
            echo -e "${YELLOW}========================================${NC}"
            ;;
        error)
            title="❌ Task Failed"
            body="Host: ${HOSTNAME}
Duration: ${duration_formatted}
Exit Code: ${exit_code}"
            
            # 添加错误信息（如果有）
            if [ -n "$error_msg" ]; then
                # 截断错误信息以适应推送限制
                error_preview=$(echo "$error_msg" | head -n 5 | cut -c 1-200)
                body="${body}

Error Preview:
${error_preview}"
            fi
            
            level="timeSensitive"
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}Task failed with exit code: ${exit_code}${NC}"
            echo -e "${RED}Duration: ${duration_formatted}${NC}"
            if [ -n "$error_msg" ]; then
                echo -e "${RED}Error log saved to: ${ERROR_LOG}${NC}"
                echo -e "${RED}Last error lines:${NC}"
                echo "$error_msg"
            fi
            echo -e "${RED}========================================${NC}"
            ;;
    esac
    
    # 发送 BARK 通知
    send_bark_notification "$title" "$body" "$level"
    
    # 清理日志文件
    if [ "$EXIT_REASON" = "success" ]; then
        # 成功时删除空日志
        rm -f "$ERROR_LOG"
    else
        # 失败或中断时，如果日志为空也删除
        if [ ! -s "$ERROR_LOG" ]; then
            rm -f "$ERROR_LOG"
        fi
    fi
    
    exit $exit_code
}

# =============================================================================
# 信号处理
# =============================================================================

# 捕获退出信号
trap 'cleanup_and_notify' EXIT

# 捕获中断信号 (Ctrl+C)
trap 'exit 130' INT

# 捕获终止信号
trap 'exit 143' TERM

# =============================================================================
# 执行任务命令
# =============================================================================

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Did-It-Work? 🤔${NC}"
echo -e "${GREEN}Task notification enabled via BARK${NC}"
echo -e "${GREEN}Host: ${HOSTNAME}${NC}"
echo -e "${GREEN}Command: ${TASK_COMMAND}${NC}"
echo -e "${GREEN}Start time: $(date)${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ -n "$NO_PIPE" ]; then
  eval "$TASK_COMMAND"
  EXIT_STATUS=$?
else
  eval "$TASK_COMMAND" 2>&1 | tee >(grep -i "error\|exception\|traceback\|failed" > "$ERROR_LOG" || true)
  EXIT_STATUS=${PIPESTATUS[0]}
fi

exit $EXIT_STATUS
