# Did-It-Work? 🤔

有时候模型训练起来了人就走了，但是很有可能没多久就报错了... 它真的work了吗？ 如 work

所以我们需要一个能实时通知的工具，比如 BARK

配合 Claude 简单实现了一个脚本，这个脚本不仅可以在模型训练结束时发送通知，还可以在报错时及时发送消息，附上报错信息

## 快速开始

### 1. 配置 BARK Device Key

编辑配置文件 `script/.bark_config`：

```bash
BARK_DEVICE_KEY="你的设备key"
BARK_SERVER="https://api.day.app"
```

> 获取 Device Key：下载 BARK App 或访问 https://bark.day.app/

### 2. 运行训练（带通知）

```bash
./script/train_with_notification.sh ./script/train/libero/train_libero_100.sh
```

或包装任意命令：
```bash
./script/train_with_notification.sh "torchrun --nproc_per_node=8 train.py --args..."
```

---

## 功能特性

### ✅ 三种通知场景

| 场景                  | 标题                   | 内容                               | 优先级        |
| --------------------- | ---------------------- | ---------------------------------- | ------------- |
| **正常完成**          | ✅ Training Completed   | 主机名、时长、命令                 | active        |
| **手动中断** (Ctrl+C) | ⚠️ Training Interrupted | 主机名、时长、原因                 | timeSensitive |
| **训练报错**          | ❌ Training Failed      | 主机名、时长、退出码、**错误预览** | timeSensitive |

### 📋 错误日志

**智能日志管理**：
- 自动捕获 stderr 中的 `error`、`exception`、`traceback`、`failed` 关键词
- 保存位置：`./error_logs/training_error_YYYYMMDD_HHMMSS.log`
- 时间戳命名：易于识别和追溯
- 推送中显示错误预览（前5行，最多200字符）
- 智能清理：成功时删除空日志，失败时保留完整日志

**日志目录结构**：
```
./error_logs/
├── training_error_20251203_154634.log  ← 最新错误
├── training_error_20251203_093022.log
└── training_error_20251202_210145.log
```

### 🌐 UTF-8 支持

- 完整支持中文、Emoji 等多字节字符
- 使用 `xxd` 进行正确的 URL 编码

---

## 使用示例

### 示例 1：正式训练
```bash
./script/train_with_notification.sh ./script/train/libero/train_libero_100.sh
```

### 示例 2：测试通知（成功场景）
```bash
./script/train_with_notification.sh "echo '训练完成 ✅'; sleep 2"
```

### 示例 3：测试通知（失败场景）
```bash
./script/train_with_notification.sh "echo 'Error: CUDA OOM' >&2; exit 1"
```

### 示例 4：测试中断（Ctrl+C）
```bash
./script/train_with_notification.sh "sleep 60"
# 按 Ctrl+C 中断
```

---

## 推送消息示例

### ✅ 正常完成
```
✅ Training Completed

Host: zxy-A800
Duration: 02:30:45
Command: ./script/train/libero/train_libero_100.sh
```

### ❌ 训练失败
```
❌ Training Failed

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
⚠️ Training Interrupted

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
chmod +x script/train_with_notification.sh
chmod +x script/train/libero/*.sh
```

### Q: 错误信息不完整
查看完整错误日志（在项目根目录）：
```bash
ls -lt error_logs/  # 查看所有错误日志
cat error_logs/training_error_*.log  # 查看最新日志
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

修改脚本 L197：
```bash
grep -i "error\|exception\|traceback\|failed\|your_keyword"
```

### 调整错误预览长度

修改脚本 L183：
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
- 长时间训练（>1小时）
- 无人值守训练
- 多个实验并行运行

⚠️ **注意事项**：
- 定期清理 `error_logs/` 目录（建议保留最近30天）
- 测试通知后再用于实际训练
- 确保网络连接稳定（推送需要网络）
- 将 `error_logs/` 添加到 `.gitignore`

🎯 **最佳实践**：
- 使用描述性的训练脚本名称
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
