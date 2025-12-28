# Did-It-Work? 🤔

有时候把命令跑起来人就走了（训练、评测、实验脚本等），但很可能没多久就报错了…… 它真的 work 了吗？

所以需要一个能实时通知的工具，比如 BARK。

这里有一个通用的命令包装脚本：无论是模型训练还是任意任务，结束、报错或中断时都能推送状态，并附上错误信息。

## 快速开始

### 1. 配置 BARK Device Key

编辑配置文件 `script/.bark_config`：

```bash
BARK_DEVICE_KEY="你的设备key"
BARK_SERVER="https://api.day.app"
```

> 获取 Device Key：下载 BARK App 或访问 https://bark.day.app/

### 2. 运行任务/训练（带通知）

```bash
./script/task_with_notification.sh ./script/train/libero/train_libero_100.sh
```

或包装任意命令：
```bash
./script/task_with_notification.sh "torchrun --nproc_per_node=8 train.py --args..."
# 或运行其他任务（如数据处理、评测脚本）
./script/task_with_notification.sh "python run_experiment.py --config exp.yaml"
```

### 3. 运行多任务队列（串行，逐任务推送）

1) 准备任务文件（每行一条命令，支持 # 注释与空行）：
```bash
cat > tasks.txt <<'EOF'
echo first && sleep 1
python run_exp.py --config a.yaml
EOF
```

2) 执行队列：
```bash
./script/task_with_notification.sh --tasks-file tasks.txt
```

可选：
- `--continue-on-failure`：遇到失败也继续执行后续任务
- `--dry-run`：仅打印队列，不执行
- `NO_PIPE=1`：关闭所有任务的管道捕获（如命令对 stdout/stderr 有特殊要求）

---

## 功能特性

### ✅ 三种通知场景

| 场景                  | 标题                | 内容                               | 优先级        |
| --------------------- | ------------------- | ---------------------------------- | ------------- |
| **正常完成**          | ✅ Task Completed    | 主机名、时长、命令                 | active        |
| **手动中断** (Ctrl+C) | ⚠️ Task Interrupted  | 主机名、时长、原因                 | timeSensitive |
| **任务报错**          | ❌ Task Failed       | 主机名、时长、退出码、**错误预览** | timeSensitive |

### 🔁 多任务队列（串行执行）

- `--tasks-file` 读取命令列表，默认遇到失败/中断停止，可用 `--continue-on-failure` 继续
- 每个任务完成时单独推送，标题/正文显示 `Multi-task` 与进度（如 `1/3`），包含该任务耗时
- 支持 `--dry-run` 预览队列；`NO_PIPE=1` 全局关闭管道捕获

### 📋 错误日志

**智能日志管理**：
- 自动捕获 stderr 中的 `error`、`exception`、`traceback`、`failed` 关键词
- 保存位置：`./error_logs/task_error_YYYYMMDD_HHMMSS[_N].log`（多任务时带序号）
- 时间戳命名：易于识别和追溯
- 推送中显示错误预览（前5行，最多200字符）
- 智能清理：成功时删除空日志，失败时保留完整日志

**日志目录结构**：
```
./error_logs/
├── task_error_20251203_154634_1.log  ← 末尾数字为队列序号
├── task_error_20251203_093022.log
└── task_error_20251202_210145.log
```

### 🌐 UTF-8 支持

- 完整支持中文、Emoji 等多字节字符
- 使用 `xxd` 进行正确的 URL 编码

---

## 使用示例

### 示例 1：正式训练
```bash
./script/task_with_notification.sh ./script/train/libero/train_libero_100.sh
```

### 示例 2：测试通知（成功场景）
```bash
./script/task_with_notification.sh "echo '训练完成 ✅'; sleep 2"
```

### 示例 3：测试通知（失败场景）
```bash
./script/task_with_notification.sh "echo 'Error: CUDA OOM' >&2; exit 1"
```

### 示例 4：测试中断（Ctrl+C）
```bash
./script/task_with_notification.sh "sleep 60"
# 按 Ctrl+C 中断
```

### 示例 5：通用任务（数据处理/评测等）
```bash
./script/task_with_notification.sh "python run_experiment.py --config exp.yaml"
./script/task_with_notification.sh "bash scripts/data_pipeline.sh --input data/raw"
```

### 示例 6：多任务队列（带进度通知）
```bash
cat > tasks.txt <<'EOF'
echo first && sleep 1
echo second && sleep 1
EOF

./script/task_with_notification.sh --tasks-file tasks.txt --continue-on-failure
# 先预览：./script/task_with_notification.sh --tasks-file tasks.txt --dry-run
```

---

## 推送消息示例

### ✅ 正常完成
```
✅ Task Completed

Host: zxy-A800
Duration: 02:30:45
Command: ./script/train/libero/train_libero_100.sh
```

### ❌ 任务失败
```
❌ Task Failed

Host: zxy-A800
Duration: 00:15:23
Exit Code: 1

Error Preview:
RuntimeError: CUDA out of memory
Traceback (most recent call last):
  File "train.py", line 295
```

### ⚠️ 手动中断
```
⚠️ Task Interrupted

Host: zxy-A800
Duration: 00:05:12
Reason: Manual interruption (Ctrl+C)
```

---

## 故障排除

### Q: 没有收到推送
**检查配置**：
```bash
cat script/.bark_config
```

**测试 BARK 服务**：
```bash
curl "https://api.day.app/你的key/测试标题/测试内容"
```

### Q: 推送显示乱码
确保使用最新版本脚本（支持 UTF-8 编码）

### Q: 权限问题
```bash
chmod +x script/task_with_notification.sh
chmod +x script/train/libero/*.sh
```

### Q: 错误信息不完整
查看完整错误日志（在项目根目录）：
```bash
ls -lt error_logs/  # 查看所有错误日志
cat error_logs/task_error_*.log  # 查看最新日志
```

### Q: 如何清理历史错误日志
```bash
# 删除7天前的日志
find error_logs/ -name "*.log" -mtime +7 -delete

# 删除所有日志
rm -rf error_logs/
```

---

## 高级配置

### 自定义错误捕获关键词

修改脚本中的 grep 关键词：
```bash
grep -i "error\|exception\|traceback\|failed\|your_keyword"
```

### 调整错误预览长度

修改脚本中的预览长度：
```bash
head -n 5   # 显示5行
cut -c 1-200  # 每行200字符
```

### 使用自建 BARK 服务器

编辑 `.bark_config`：
```bash
BARK_SERVER="https://your-bark-server.com"
```

---

## 安全建议

⚠️ `.bark_config` 包含敏感信息，建议加入 `.gitignore`：

```bash
echo "script/.bark_config" >> .gitignore
```

---

## 依赖项

脚本依赖以下系统工具（通常已预装）：
- `bash`
- `curl`
- `xxd`
- `grep`
- `sed`

检查依赖：
```bash
which bash curl xxd grep sed
```

---

## 最佳实践

✅ **推荐场景**：
- 长时间运行的命令（训练/评测/数据处理等 >1小时）
- 无人值守的实验或流水线
- 多个实验并行运行需要区分状态

⚠️ **注意事项**：
- 定期清理 `error_logs/` 目录（建议保留最近30天）
- 测试通知后再用于实际训练
- 确保网络连接稳定（推送需要网络）
- 将 `error_logs/` 添加到 `.gitignore`

🎯 **最佳实践**：
- 使用描述性的任务/训练脚本名称
- 为不同实验设置不同的通知消息
- 结合 screen/tmux 使用以防止 SSH 断开
- 重要实验的错误日志及时备份

**日志管理**：
```bash
# 添加到 .gitignore
echo "error_logs/" >> .gitignore

# 定期清理（保留30天）
find error_logs/ -name "*.log" -mtime +30 -delete
```
