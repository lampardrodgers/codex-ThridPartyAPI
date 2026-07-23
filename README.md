# grok-3p

Grok Build CLI 的**第三方中转**启动器。  
**可以和官方 `grok` 同时开**（互不抢配置）。

## 和官方怎么并存

| | **`grok`（官方）** | **`grok-3p`（本脚本）** |
|--|-------------------|-------------------------|
| 配置目录 | `~/.grok` | **`~/.grok-3p`（隔离）** |
| config.toml | 订阅 / login | 中转 `3p-NN-*`，**不改官方文件** |
| 登录 | 需要 | **不需要** |
| 同时开 | ✅ | ✅ |
| 模型顺序 | 官方 | `created` 新→旧（`3p-00` 最新） |
| effort | 官方 | 抄 CLI 真实元数据（不猜名字） |
| 推理 | 官方 API | **直连中转**（无本地反代，可流式） |

> 以前「注入同一份 `~/.grok/config.toml`」时，裸 `grok` 会读到中转模型却带 JWT → **401**。  
> 要同时开，必须隔离 home。skills / bin / bundled 等仍从官方 **symlink**，体验尽量一致。

## 使用

```bash
# 编辑顶部 RELAY_BASE_URL / RELAY_API_KEY 后：
bash grok-3p.sh install
grok-3p doctor

# 终端 A
grok

# 终端 B（同时）
grok-3p
```

选模型：`3p-00-grok-4.5`（`00 · grok-4.5`），effort 在 TUI 里选 High/Medium/Low。

```bash
grok-3p models
grok-3p -p 'hi' -m 3p-00-grok-4.5 --reasoning-effort low
```

## 硬需求（保留）

1. **effort = 官方真实值**（CLI 内嵌 + `models_cache`，不猜名字）  
2. **新模型在最上面**（`created` 降序 → `3p-00` / `3p-01` …）  
3. **直连中转 SSE**（无本地推理反代）

## 文件

| 路径 | 说明 |
|------|------|
| `grok-3p.sh` | 源脚本 |
| `~/.local/bin/grok-3p` | install 后的启动器 |
| `~/.grok-3p/` | 3p 专用 home |
| `~/.grok-3p/thirdparty.env` | 中转凭证 |
| `~/.grok/` | **仅官方**；本脚本不写 config |

## 刻意不做

| 不做 | 原因 |
|------|------|
| 改写官方 `~/.grok/config.toml` | 无法与 `grok` 并行 |
| 本地推理反代 | SSE 缓冲 / Responding 卡住 |
| 按模型名猜 effort | 不准确 |
