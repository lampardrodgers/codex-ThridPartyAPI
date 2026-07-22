# grok-3p

Grok Build CLI 的**第三方中转**启动器。思路对齐 **`codex-3p`**：**共用官方 home**，只换模型源；并保留你明确要求过的两点：

1. **effort 与官方真实元数据一致**（从 CLI 内嵌 `default_models` + `models_cache` 抄，**不猜名字**）
2. **新模型在最上面**（中转 `/models` 按 `created` 降序 → `3p-00` / `3p-01` …）

| | **`codex-3p`** | **`grok-3p`** |
|--|----------------|---------------|
| 配置目录 | 共用 `~/.codex` | 共用 **`~/.grok`** |
| 切换方式 | `-c model_provider=thirdparty` + catalog | 运行时注入 `[model."3p-NN-…"]`，退出还原 `config.toml` |
| effort | 从官方 cache 合成 catalog | 同上：官方同 id 的 `reasoning_efforts` |
| 顺序 | provider 列表 + priority | `created` 新→旧 → `3p-00` 最新 |
| 推理 | 中转 | **直连中转**（无本地反代，可 SSE 流式） |
| 官方命令 | `codex` 不动 | `grok` 不动（config 退出时还原） |

## 401 怎么躲的

CLI 0.2.106：读到 `auth.json` 的 session JWT 时，可能把 JWT 打到中转 → 401。  
`grok-3p` 设置 `GROK_AUTH_PATH` 指向**不存在的文件**，不加载 JWT；只用 `RELAY_API_KEY` + 每模型 `base_url`。

## 使用

```bash
# 编辑顶部两行 URL/KEY 后：
bash grok-3p.sh install
grok-3p doctor

grok-3p                 # TUI
grok-3p models          # 3p-00-grok-4.5 应在最前
grok-3p -p 'hi' -m 3p-00-grok-4.5 --reasoning-effort low

grok                    # 官方订阅（config 保持干净）
```

选模型用 **`3p-00-grok-4.5`**（`00 · grok-4.5`）。  
有官方 effort 元数据的模型（当前主要是 `grok-4.5`）在 TUI 里可选 High / Medium / Low，文案与官方一致。

## 运行时做了什么

1. 快照 `~/.grok/config.toml` → `config.toml.pre-3p`
2. 拉中转 `/models`，按 `created` 排序，写入 `3p-NN-*` 段 + 真实 effort
3. 保留你的 `[ui]` / `[marketplace]` / `[cli]`
4. 退出（或 Ctrl-C）时**还原**官方 config  
   - 若曾崩溃：下次 `grok-3p` / `grok-3p restore` 会自动还原

## 文件

| 路径 | 说明 |
|------|------|
| `grok-3p.sh` | 源脚本 |
| `~/.local/bin/grok-3p` | install 后的启动器 |
| `~/.grok/thirdparty.env` | 凭证（对标 `~/.codex/thirdparty.env`） |

## 刻意不做

| 不做 | 原因 |
|------|------|
| 本地推理反代 | SSE 缓冲 → 无流式 / Responding 卡住 |
| 只设 `GROK_MODELS_BASE_URL` 不写模型段 | 会丢掉 **排序** 与 **effort 菜单** |
| 按模型名猜 effort | 不准确；只抄官方同 id 元数据 |
| 永久改官方 `config.toml` | 会污染 `grok`；改为注入 + 退出还原 |
