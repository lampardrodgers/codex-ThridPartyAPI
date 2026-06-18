# Codex Third-Party API

给官方 `codex` 增加第三方 API 入口。官方入口保留，第三方入口单独运行，互不覆盖。

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

DeepSeek 不是 Codex API，本仓库用本地 bridge 做协议转换。

只需要在 `codex-deepseek` 顶部填 key：

```bash
DEEPSEEK_API_KEY="YOUR-DEEPSEEK-API-KEY"
```

然后执行：

```bash
chmod +x ./codex-deepseek
./codex-deepseek
```

安装时需要仓库里的 `codex-chat-bridge` 和 `codex-deepseek` 放在同一目录。脚本会自动安装 bridge，不需要手动运行 bridge。

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

安装时需要仓库里的 `codex-chat-bridge` 和 `codex-glm` 放在同一目录。脚本会自动安装 bridge，不需要手动运行 bridge。

使用：

```bash
codex-glm
```

GLM 默认使用 Coding Plan 专属端点：

```text
https://api.z.ai/api/coding/paas/v4
```

默认不用改。改成通用端点可能不会走 Coding Plan 额度。

## 日常命令

```bash
codex              # 官方 OpenAI / ChatGPT 登录态
codex-3p           # 第三方 Codex API / Codex 中转
codex-deepseek     # DeepSeek API
codex-glm          # GLM Coding Plan API
```

一次性执行：

```bash
codex-3p exec "只回复：ok"
codex-deepseek exec "只回复：ok"
codex-glm exec "只回复：ok"
```

强制更高推理强度：

```bash
codex-deepseek -c model_reasoning_effort='"xhigh"'
codex-glm -c model_reasoning_effort='"xhigh"'
```

DeepSeek/GLM 当前映射：

```text
low / medium / high -> high
xhigh               -> max
```

## 查询状态

DeepSeek：

```bash
codex-deepseek-stats       # 最近 5 条
codex-deepseek-stats 20    # 最近 20 条
codex-deepseek-stats -w    # 实时观察
```

GLM：

```bash
codex-glm-stats
codex-glm-stats 20
codex-glm-stats -w
```

DeepSeek 日志会显示缓存命中率：

```text
cache_hit_tokens=10368 cache_miss_tokens=8 cache_hit_rate=99.92%
```

## bridge 说明

`codex-chat-bridge` 是内部转换脚本，不需要手动运行。

- `codex-deepseek` 会自动启动和关闭 bridge
- `codex-glm` 会自动启动和关闭 bridge
- `codex-3p` 不走这个 bridge，直接面向第三方 Codex API / Codex 中转

## 换 key

重新修改对应脚本顶部 key，再执行一次安装脚本即可：

```bash
./codex-thirdparty
./codex-deepseek
./codex-glm
```

真实 key 会写入本机 `~/.codex/*.env`。不要提交这些文件。

## 前提

本机已经安装并启动过官方 Codex：

```bash
codex --version
```

至少运行过一次官方 `codex`，确保存在：

```text
~/.codex/config.toml
```
