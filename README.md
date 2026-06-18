# Codex Third-Party API

给官方 `codex` 额外加几个独立入口，用不同命令切换不同 API。

## 功能

- `codex`：继续使用官方 Codex 登录态
- `codex-3p`：使用通用第三方 OpenAI 兼容接口
- `codex-deepseek`：使用 DeepSeek API
- `codex-glm`：使用 GLM Coding Plan API
- `codex-deepseek-stats`：查看 DeepSeek 推理强度、隐藏思考字符数、缓存命中率
- `codex-glm-stats`：查看 GLM 推理强度、隐藏思考字符数、输出字符数

DeepSeek 和 GLM 的官方接口是 Chat Completions 协议，而当前 Codex 需要 Responses 协议，所以本仓库提供了 `codex-chat-bridge` 做本地转换。

`codex-chat-bridge` 不需要手动运行。安装后执行 `codex-deepseek` 或 `codex-glm` 时，启动脚本会自动拉起 bridge，Codex 退出后会自动关闭。

## 前提

先确认官方 Codex 已经可用：

```bash
codex --version
```

并且至少启动过一次官方 `codex`，让本机生成 `~/.codex/config.toml`。

## 安装 DeepSeek

打开 `codex-deepseek`，只需要改脚本最上面的配置：

```bash
DEEPSEEK_API_KEY="YOUR-DEEPSEEK-API-KEY"
DEEPSEEK_BASE_URL="https://api.deepseek.com"
DEEPSEEK_DEFAULT_MODEL="deepseek-v4-pro"
```

然后执行：

```bash
chmod +x ./codex-deepseek
./codex-deepseek
```

安装后会生成：

- `~/.local/bin/codex-deepseek`
- `~/.local/bin/codex-deepseek-stats`
- `~/.codex/deepseek.env`
- `~/.codex/bin/codex-chat-bridge`

## 安装 GLM Coding Plan

打开 `codex-glm`，只需要改脚本最上面的配置：

```bash
GLM_API_KEY="YOUR-GLM-API-KEY"
GLM_BASE_URL="https://api.z.ai/api/coding/paas/v4"
GLM_DEFAULT_MODEL="glm-5.2"
```

然后执行：

```bash
chmod +x ./codex-glm
./codex-glm
```

GLM Coding Plan 要使用这个专属端点：

```text
https://api.z.ai/api/coding/paas/v4
```

不要改成通用端点 `https://api.z.ai/api/paas/v4`，否则不会走 Coding Plan 额度。

安装后会生成：

- `~/.local/bin/codex-glm`
- `~/.local/bin/codex-glm-stats`
- `~/.codex/glm.env`
- `~/.codex/bin/codex-chat-bridge`

## 安装通用第三方接口

如果你有其他 OpenAI 兼容接口，打开 `codex-thirdparty`，修改顶部：

```bash
THIRDPARTY_BASE_URL="YOUR-BASE-URL"
THIRDPARTY_API_KEY="YOUR-API-KEY"
```

然后执行：

```bash
chmod +x ./codex-thirdparty
./codex-thirdparty
```

安装后使用：

```bash
codex-3p
```

## 日常使用

官方 Codex：

```bash
codex
```

DeepSeek：

```bash
codex-deepseek
```

GLM Coding Plan：

```bash
codex-glm
```

强制使用更高推理强度：

```bash
codex-deepseek -c model_reasoning_effort='"xhigh"'
codex-glm -c model_reasoning_effort='"xhigh"'
```

也可以直接执行一次性任务：

```bash
codex-deepseek exec "只回复：ok"
codex-glm exec "只回复：ok"
```

## 查询推理和缓存

DeepSeek 最近 5 条记录：

```bash
codex-deepseek-stats
```

DeepSeek 最近 20 条记录：

```bash
codex-deepseek-stats 20
```

实时观察 DeepSeek：

```bash
codex-deepseek-stats -w
```

GLM 用法相同：

```bash
codex-glm-stats
codex-glm-stats 20
codex-glm-stats -w
```

示例输出：

```text
responses completed model=deepseek-v4-pro reasoning_effort=max reasoning_chars=636 output_chars=48 cache_hit_tokens=10368 cache_miss_tokens=8 cache_hit_rate=99.92%
```

字段含义：

- `reasoning_effort`：实际发给供应商的推理强度，当前是 `high` 或 `max`
- `reasoning_chars`：供应商返回的隐藏思考字符数，只记录数量，不记录正文
- `output_chars`：最终回复字符数
- `cache_hit_tokens` / `cache_miss_tokens`：DeepSeek prompt cache 命中和未命中 token
- `cache_hit_rate`：DeepSeek 缓存命中率

Codex TUI 本身不显示 `reasoning_content` 和缓存 usage，所以需要通过 stats 脚本查看。

## 推理强度映射

DeepSeek 和 GLM 这里按两档处理：

```text
low    -> high
medium -> high
high   -> high
xhigh  -> max
```

所以真正有明显区别的是 `high` 和 `xhigh`。

## 换 Key 或换模型

重新打开对应安装脚本，修改顶部配置，再执行一次即可：

```bash
./codex-deepseek
./codex-glm
./codex-thirdparty
```

真实 API key 会写到本机 `~/.codex/*.env`，不要提交这些文件。

## 注意事项

- `codex-chat-bridge` 是内部转换脚本，不要手动运行。
- `codex-deepseek` / `codex-glm` 会自动启动和关闭 bridge。
- `codex`、`codex-deepseek`、`codex-glm` 的会话列表可能显示在一起，但不同 provider 的历史会话不建议互相 resume。
- 仓库只提交去敏安装脚本和说明，不提交真实 API key、本地 env、日志和私有副本。
