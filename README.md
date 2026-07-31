# Codex Third-Party API

给官方 `codex` 增加第三方 API 入口。官方入口保留，第三方入口单独运行，互不覆盖。

本仓库另含 **Grok Build CLI** 的中转启动器 `grok-3p`（见下文第 4 节）。

## 核心模式

### 1. `codex-3p`：第三方 Codex API / Codex 中转

`codex-3p` 面向第三方平台提供的 **Codex API / Codex 中转 / OpenAI Responses 兼容接口**。

适合这些场景：

- 第三方平台已经专门适配 Codex
- 中转站提供 Codex API
- 接口本身兼容 Responses API
- 你只想把官方 `codex` 和第三方入口分开使用

安装时只改 `codex-thirdparty` 顶部：

```bash
THIRDPARTY_BASE_URL="YOUR-BASE-URL"
THIRDPARTY_API_KEY="YOUR-API-KEY"
```

然后执行：

```bash
chmod +x ./codex-thirdparty
./codex-thirdparty
```

使用：

```bash
codex-3p
```

官方入口仍然是：

```bash
codex
```

### 2. `codex-deepseek`：DeepSeek 直连

DeepSeek 官方原生支持 Codex 使用的 Responses API。本脚本直连官方接口，不启动本地 bridge；每次运行 `codex-deepseek` 时会刷新官方可用模型及 reasoning effort。模型必须同时存在于官方 `/models` 和 Responses API Reference 中才会写入 Codex 目录，不支持 Responses API 的模型会被排除。

只需要在 `codex-deepseek` 顶部填 key：

```bash
DEEPSEEK_API_KEY="YOUR-DEEPSEEK-API-KEY"
```

然后执行：

```bash
chmod +x ./codex-deepseek
./codex-deepseek
```

使用：

```bash
codex-deepseek
```

### 3. `codex-glm`：GLM Coding Plan 直连

GLM Coding Plan 不是 Codex API，本仓库同样用本地 bridge 做协议转换。

只需要在 `codex-glm` 顶部填 key：

```bash
GLM_API_KEY="YOUR-GLM-API-KEY"
```

然后执行：

```bash
chmod +x ./codex-glm
./codex-glm
```

安装时需要仓库里的 `codex-glm-bridge` 和 `codex-glm` 放在同一目录。脚本会自动安装 GLM 专用 bridge，不需要手动运行。

使用：

```bash
codex-glm
```

GLM 默认使用 Coding Plan 专属端点：

```text
https://api.z.ai/api/coding/paas/v4
```

默认不用改。改成通用端点可能不会走 Coding Plan 额度。

### 4. `grok-3p`：Grok Build CLI 第三方中转

给官方 **Grok Build CLI**（`grok`）增加第三方中转入口。与 `codex-3p` 同思路：官方入口保留，中转入口单独跑。

| | **`grok`（官方）** | **`grok-3p`** |
|--|-------------------|---------------|
| 配置目录 | `~/.grok` | **`~/.grok-3p`（隔离）** |
| 登录 | 需要 | **不需要** |
| 同时开 | ✅ | ✅（互不改对方 config） |
| 模型 | 订阅目录 | 中转 `/models` → `3p-NN-…`（`created` 新→旧） |
| effort | 官方 | 抄 CLI 真实元数据（不猜名字） |
| 推理 | 官方 API | **直连中转**（无本地反代，可流式） |

安装：编辑 `grok-3p.sh` 顶部两行后执行：

```bash
export RELAY_BASE_URL="https://YOUR_RELAY_HOST/v1"
export RELAY_API_KEY="sk-YOUR_RELAY_KEY"

chmod +x ./grok-3p.sh
./grok-3p.sh install
./grok-3p.sh doctor
```

使用：

```bash
grok-3p                 # TUI
grok-3p models          # 3p-00 应为最新
grok-3p -p 'hi' -m 3p-00-grok-4.5 --reasoning-effort low

grok                    # 官方订阅，可与 grok-3p 同时开
```

凭证写在 `~/.grok-3p/thirdparty.env`。skills / bin / bundled 等从官方 symlink，session 在 `~/.grok-3p`。

**不要**再往官方 `~/.grok/config.toml` 里注入中转模型：否则另开的裸 `grok` 会带 JWT 打中转 → 401。

## 日常命令

```bash
codex              # 官方 OpenAI / ChatGPT 登录态
codex-3p           # 第三方 Codex API / Codex 中转
codex-deepseek     # DeepSeek API
codex-glm          # GLM Coding Plan API
grok               # 官方 Grok Build CLI 订阅
grok-3p            # Grok Build CLI 第三方中转
```

一次性执行：

```bash
codex-3p exec "只回复：ok"
codex-deepseek exec "只回复：ok"
codex-glm exec "只回复：ok"
grok-3p -p '只回复：ok' -m 3p-00-grok-4.5 --reasoning-effort low
```

指定推理强度：

```bash
codex-deepseek -c model_reasoning_effort='"max"'
codex-glm -c model_reasoning_effort='"xhigh"'
```

DeepSeek 的模型与 effort 列表会在每次启动时从官方 `/models` 和 Responses API Reference 刷新，并只保留两者交集；刷新失败时使用上次成功筛选的缓存。选择值会原样发送，不经过本地映射。GLM 当前映射：

模型目录在 Codex 进程启动时载入。更新或重新安装脚本后，已经打开的旧会话不会热更新；无需强制结束进程，正常退出旧会话并重新运行 `codex-deepseek` 即可。强制杀进程可能中断正在执行的任务。

```text
low / medium / high -> high
xhigh               -> max
```

## 查询状态

GLM：

```bash
codex-glm-stats
codex-glm-stats 20
codex-glm-stats -w
```

## bridge 说明

`codex-glm-bridge` 是 GLM 专用的内部转换脚本，不需要手动运行。

- `codex-deepseek` 直连 DeepSeek 官方 Responses API，不使用 bridge
- `codex-glm` 会自动启动和关闭 GLM 专用 bridge
- `codex-3p` 不走这个 bridge，直接面向第三方 Codex API / Codex 中转
- `grok-3p` 也不走这个 bridge，直连 Grok 兼容中转

## 换 key

重新修改对应脚本顶部 key，再执行一次安装脚本即可：

```bash
./codex-thirdparty
./codex-deepseek
./codex-glm
./grok-3p.sh install
```

真实 key 会写入本机：

- Codex 相关：`~/.codex/*.env`
- Grok 中转：`~/.grok-3p/thirdparty.env`

不要提交这些文件。

## 前提

**Codex 系列：** 本机已经安装并启动过官方 Codex：

```bash
codex --version
```

至少运行过一次官方 `codex`，确保存在：

```text
~/.codex/config.toml
```

**Grok 中转：** 本机已安装官方 Grok Build CLI（`~/.grok/bin/grok`）。`grok-3p` 不需要 `grok login`。
