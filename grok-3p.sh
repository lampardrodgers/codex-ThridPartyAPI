#!/usr/bin/env bash
# =============================================================================
# grok-3p — 第三方中转专用（可与官方 grok 同时开）
#
# 为什么不能共用 ~/.grok/config.toml：
#   运行时注入会让裸 `grok` 也读到中转模型 → JWT 打中转 → 401。
#   你要「grok + grok-3p 同时开」，就必须隔离配置目录。
#
# 做法（仍尽量像官方）：
#   - GROK_HOME = ~/.grok-3p（独立 config / session / 无 auth.json）
#   - 从 ~/.grok 链接 bin/bundled/skills/docs…，UI 偏好抄官方
#   - 模型：3p-NN 按 created 新→旧；effort 抄 CLI 内嵌真实元数据
#   - 直连中转（无本地推理反代）→ 可 SSE 流式
#   - 官方 ~/.grok 永不改写 → `grok` 与 `grok-3p` 可并行
#
# 顶部两行改成你的中转：
export RELAY_BASE_URL="https://YOUR_RELAY_HOST/v1"
export RELAY_API_KEY="sk-YOUR_RELAY_KEY"
# =============================================================================

set -euo pipefail

OFFICIAL="${GROK_OFFICIAL_HOME:-$HOME/.grok}"
G3P="${GROK_HOME_3P:-$HOME/.grok-3p}"
ENV_FILE="${GROK_3P_ENV_FILE:-$G3P/thirdparty.env}"
# also accept older names
LEGACY_ENV_A="${G3P}/relay.env"
LEGACY_ENV_B="${OFFICIAL}/thirdparty.env"
CONFIG_PATH="${G3P}/config.toml"
SYNC_STATE="${G3P}/3p-sync-state"
GROK_BIN=""

die() { echo "grok-3p: $*" >&2; exit 1; }

load_dotenv() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" != *=* ]] && continue
    local k="${line%%=*}"
    local v="${line#*=}"
    k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    case "$k" in
      RELAY_BASE_URL|RELAY_API_KEY|XAI_API_KEY|GROK_MODELS_BASE_URL)
        if [[ -z "${!k:-}" ]] || [[ "${!k}" == *"YOUR_RELAY"* ]]; then
          export "$k=$v"
        fi
        ;;
    esac
  done < "$f"
}

need_creds() {
  load_dotenv "$ENV_FILE"
  load_dotenv "$LEGACY_ENV_A"
  load_dotenv "$LEGACY_ENV_B"
  if [[ -z "${RELAY_API_KEY:-}" || "$RELAY_API_KEY" == *"YOUR_RELAY"* ]]; then
    RELAY_API_KEY="${XAI_API_KEY:-${RELAY_API_KEY:-}}"
  fi
  if [[ -z "${RELAY_BASE_URL:-}" || "$RELAY_BASE_URL" == *"YOUR_RELAY"* ]]; then
    RELAY_BASE_URL="${GROK_MODELS_BASE_URL:-${RELAY_BASE_URL:-}}"
  fi
  [[ -n "${RELAY_BASE_URL:-}" && -n "${RELAY_API_KEY:-}" ]] || die \
    "设置顶部 RELAY_BASE_URL / RELAY_API_KEY，或写入 $ENV_FILE"
  [[ "$RELAY_BASE_URL" != *"YOUR_RELAY"* && "$RELAY_API_KEY" != *"YOUR_RELAY"* ]] || die \
    "请改成真实 URL 与 KEY"
  RELAY_BASE_URL="${RELAY_BASE_URL%/}"
}

find_grok() {
  if [[ -x "$OFFICIAL/bin/grok" ]]; then
    GROK_BIN="$OFFICIAL/bin/grok"
  elif [[ -x "$HOME/.local/bin/grok" ]]; then
    GROK_BIN="$HOME/.local/bin/grok"
  elif [[ -x "$HOME/.npm-global/bin/grok" ]]; then
    GROK_BIN="$HOME/.npm-global/bin/grok"
  elif [[ -x /opt/homebrew/bin/grok ]]; then
    GROK_BIN=/opt/homebrew/bin/grok
  elif [[ -x /usr/local/bin/grok ]]; then
    GROK_BIN=/usr/local/bin/grok
  elif command -v grok >/dev/null 2>&1; then
    local hit
    hit="$(command -v grok)"
    [[ "$(basename "$hit")" != "grok-3p" ]] && GROK_BIN="$hit" || GROK_BIN=""
  else
    GROK_BIN=""
  fi
}

install_cli() {
  find_grok
  [[ -n "$GROK_BIN" ]] && return 0
  curl -fsSL https://x.ai/cli/install.sh | bash
  find_grok
  [[ -n "$GROK_BIN" ]] || die "grok binary missing — 请先安装官方 Grok Build CLI"
}

# One-time / each start: mirror official assets, never touch official config.
bootstrap_home() {
  mkdir -p "$G3P"

  # Heavy/shared trees → symlink to official install (same binary, skills assets, docs)
  for name in bin bundled docs vendor completions marketplace-cache downloads; do
    if [[ -e "$OFFICIAL/$name" ]]; then
      if [[ -L "$G3P/$name" ]]; then
        : # already linked
      elif [[ -e "$G3P/$name" ]]; then
        : # keep local copy
      else
        ln -s "$OFFICIAL/$name" "$G3P/$name" 2>/dev/null || true
      fi
    fi
  done

  # skills: ensure each skill exists (copy or link missing)
  if [[ -d "$OFFICIAL/skills" ]]; then
    mkdir -p "$G3P/skills"
    local d base
    for d in "$OFFICIAL/skills"/*; do
      [[ -e "$d" ]] || continue
      base=$(basename "$d")
      if [[ ! -e "$G3P/skills/$base" ]]; then
        cp -a "$d" "$G3P/skills/$base" 2>/dev/null || ln -s "$d" "$G3P/skills/$base" 2>/dev/null || true
      fi
    done
  fi

  # CRITICAL: no official login in 3p home (JWT → relay 401)
  rm -f "$G3P/auth.json" 2>/dev/null || true
}

write_env() {
  mkdir -p "$G3P"
  umask 077
  cat > "$ENV_FILE" <<EOF
# Third-party credentials for grok-3p (isolated home; official ~/.grok untouched)
RELAY_BASE_URL=${RELAY_BASE_URL}
RELAY_API_KEY=${RELAY_API_KEY}
EOF
  chmod 600 "$ENV_FILE"
  # keep legacy path in sync for old notes
  cat > "$LEGACY_ENV_A" <<EOF
RELAY_BASE_URL=${RELAY_BASE_URL}
RELAY_API_KEY=${RELAY_API_KEY}
EOF
  chmod 600 "$LEGACY_ENV_A"
}

# Ensure any leftover same-home injection is cleaned from official home.
cleanup_official_if_polluted() {
  local snap="${OFFICIAL}/config.toml.pre-3p"
  local cfg="${OFFICIAL}/config.toml"
  if [[ -f "$snap" ]]; then
    cp -p "$snap" "$cfg"
    rm -f "$snap" "${OFFICIAL}/config.toml.pre-3p.pid"
    echo "grok-3p: cleaned leftover inject; restored official ~/.grok/config.toml" >&2
  elif [[ -f "$cfg" ]] && grep -q 'injected by grok-3p' "$cfg" 2>/dev/null; then
    # snap missing but still injected — strip model overrides back to safe default
    python3 - "$cfg" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
t = p.read_text()
# keep only sections before first injected marker or first [model.
if "injected by grok-3p" in t:
    t = t.split("# --- injected by grok-3p")[0].rstrip() + "\n"
if not re.search(r'(?m)^\[models\]', t):
    t += "\n[models]\ndefault = \"grok-4.5\"\ndefault_reasoning_effort = \"high\"\n"
else:
    # ensure default not 3p-
    t = re.sub(r'(?m)^(default\s*=\s*)"3p-[^"]*"', r'\1"grok-4.5"', t)
# drop any remaining [model."3p- or bare 3p blocks if marker path failed
if '3p-00-' in t:
    # rewrite minimal safe config from non-model headers
    lines = []
    skip = False
    for line in t.splitlines():
        if re.match(r'^\[model\.', line) or re.match(r'^\[\[model\.', line):
            skip = True
            continue
        if skip:
            if re.match(r'^\[', line) and not re.match(r'^\[\[?model\.', line):
                skip = False
            else:
                continue
        if skip:
            continue
        lines.append(line)
    body = "\n".join(lines).rstrip() + "\n"
    if not re.search(r'(?m)^\[models\]', body):
        body += "\n[models]\ndefault = \"grok-4.5\"\ndefault_reasoning_effort = \"high\"\n"
    p.write_text(body)
else:
    p.write_text(t if t.endswith("\n") else t + "\n")
print("grok-3p: scrubbed 3p models from official config", file=__import__("sys").stderr)
PY
  fi
}

sync_models() {
  local force="${1:-0}"
  local ttl="${GROK_3P_SYNC_TTL:-300}"
  if [[ "$force" != "1" && -f "$SYNC_STATE" && -f "$CONFIG_PATH" ]]; then
    local last now
    last=$(cat "$SYNC_STATE" 2>/dev/null || echo 0)
    now=$(date +%s)
    if (( now - last < ttl )) && grep -q '\[model\."3p-00-' "$CONFIG_PATH" 2>/dev/null; then
      return 0
    fi
  fi

  RELAY_BASE_URL="$RELAY_BASE_URL" RELAY_API_KEY="$RELAY_API_KEY" \
  G3P="$G3P" OFFICIAL="$OFFICIAL" CONFIG_PATH="$CONFIG_PATH" SYNC_STATE="$SYNC_STATE" \
  python3 <<'PY'
import json, os, re, sys, time
from pathlib import Path
from urllib.request import Request, urlopen

base = os.environ["RELAY_BASE_URL"].rstrip("/")
key = os.environ["RELAY_API_KEY"]
g3p = Path(os.environ["G3P"])
official = Path(os.environ["OFFICIAL"])
config_path = Path(os.environ["CONFIG_PATH"])
g3p.mkdir(parents=True, exist_ok=True)

req = Request(base + "/models", headers={"Authorization": f"Bearer {key}", "User-Agent": "grok-3p"})
with urlopen(req, timeout=30) as r:
    payload = json.loads(r.read().decode())
items = [m for m in (payload.get("data") or payload.get("models") or []) if isinstance(m, dict) and m.get("id")]
if not items:
    print("grok-3p: empty /models", file=sys.stderr)
    sys.exit(1)

def created(m):
    try:
        c = int(m.get("created") or 0)
    except Exception:
        return 0
    return c // 1000 if c > 10_000_000_000 else c

items.sort(key=lambda m: (-created(m), str(m["id"])))

# effort meta from official binary + models_cache (never guess names)
meta = {}
bin_path = official / "bin" / "grok"
if bin_path.is_file():
    text = bin_path.read_bytes().decode("utf-8", errors="ignore")
    marker = '"default": "grok-4.5"'
    best = None
    for m in re.finditer(re.escape(marker), text):
        i = m.start()
        while i > 0 and text[i] != "{":
            i -= 1
        if text[i] != "{":
            continue
        depth, j = 0, i
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        chunk = text[i:j]
        if '"models"' in chunk and "reasoning_efforts" in chunk:
            if best is None or len(chunk) > len(best):
                best = chunk
    if best:
        try:
            for m in json.loads(best).get("models") or []:
                if isinstance(m, dict) and m.get("id"):
                    meta[str(m["id"])] = m
        except Exception:
            pass

cache = official / "models_cache.json"
if cache.is_file():
    try:
        raw = json.loads(cache.read_text())
        models = raw.get("models") or {}
        if isinstance(models, dict):
            for k, v in models.items():
                info = v.get("info") if isinstance(v, dict) and "info" in v else v
                if not isinstance(info, dict):
                    continue
                mid = str(info.get("id") or k)
                if mid not in meta or (info.get("reasoning_efforts") and not meta[mid].get("reasoning_efforts")):
                    meta[mid] = {**meta.get(mid, {}), **info}
        elif isinstance(models, list):
            for info in models:
                if not isinstance(info, dict):
                    continue
                mid = str(info.get("id") or info.get("slug") or "")
                if not mid:
                    continue
                if mid not in meta or (info.get("reasoning_efforts") and not meta.get(mid, {}).get("reasoning_efforts")):
                    meta[mid] = {**meta.get(mid, {}), **info}
    except Exception:
        pass

def toml_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

# Preserve UI-ish knobs from official config (read-only)
official_txt = ""
ocfg = official / "config.toml"
if ocfg.is_file():
    official_txt = ocfg.read_text(encoding="utf-8")

def extract_section(txt: str, header: str) -> list:
    m = re.search(rf'(?ms)^{re.escape(header)}\s*\n(.*?)(?=^\[|\Z)', txt)
    if not m:
        return []
    lines = [header]
    for line in m.group(1).splitlines():
        lines.append(line.rstrip())
    while lines and lines[-1].strip() == "":
        lines.pop()
    lines.append("")
    return lines

def extract_array_tables(txt: str, prefix: str) -> list:
    out = []
    for m in re.finditer(rf'(?ms)^\[\[{re.escape(prefix)}(?:\.[^\]]+)?\]\]\s*\n.*?(?=^\[|\Z)', txt):
        out.append(m.group(0).rstrip() + "\n")
    return out

preserved: list = []
for hdr in ("[cli]", "[marketplace]", "[ui]", "[terminal]", "[hooks]"):
    part = extract_section(official_txt, hdr)
    if part:
        preserved.extend(part)
for block in extract_array_tables(official_txt, "marketplace"):
    preserved.append(block.rstrip())
    preserved.append("")

if not any(l.startswith("[ui]") for l in preserved):
    preserved.extend(["[ui]", 'permission_mode = "always-approve"', "yolo = false", ""])
if not any(l.startswith("[cli]") for l in preserved):
    preserved.extend(["[cli]", 'installer = "internal"', ""])

default_effort = "high"
m_eff = re.search(r'(?m)^\s*default_reasoning_effort\s*=\s*"([^"]+)"', official_txt)
if m_eff:
    default_effort = m_eff.group(1)

body: list = []
default_section = None
effort_n = 0

for i, m in enumerate(items):
    mid = str(m["id"])
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", mid)
    section = f"3p-{i:02d}-{safe}"
    if default_section is None:
        default_section = section

    info = meta.get(mid) or {}
    efforts = info.get("reasoning_efforts")
    supports = (
        info.get("supports_reasoning_effort") is True
        and isinstance(efforts, list)
        and len(efforts) > 0
    )
    de = (info.get("reasoning_effort") or default_effort) if supports else None
    ctx = info.get("context_window")
    backend = info.get("api_backend")
    label = info.get("system_prompt_label") or info.get("name")
    if not isinstance(ctx, int) or ctx <= 0:
        ctx = 500000 if "4.5" in mid else (
            256000 if re.search(r"4\.3|4\.20|build|multi-agent", mid) else 128000
        )
    if backend not in ("responses", "chat_completions", "messages"):
        backend = "responses" if (supports or re.search(r"grok-4|grok-build", mid)) else "chat_completions"

    name = f"{i:02d} · {mid}"
    body.append(f'[model."{section}"]')
    body.append(f"model = {toml_str(mid)}")
    body.append(f"base_url = {toml_str(base)}")
    body.append(f"name = {toml_str(name)}")
    body.append(f"api_key = {toml_str(key)}")
    body.append('env_key = "RELAY_API_KEY"')
    body.append(f"api_backend = {toml_str(backend)}")
    body.append(f"context_window = {int(ctx)}")
    if label:
        body.append(f"system_prompt_label = {toml_str(str(label))}")
    if supports:
        effort_n += 1
        body.append("supports_reasoning_effort = true")
        body.append(f"reasoning_effort = {toml_str(str(de))}")
        body.append("")
        for lvl in efforts:
            if not isinstance(lvl, dict):
                continue
            eid = str(lvl.get("id") or lvl.get("value") or "")
            if not eid:
                continue
            body.append(f'[[model."{section}".reasoning_efforts]]')
            body.append(f"id = {toml_str(eid)}")
            body.append(f"value = {toml_str(str(lvl.get('value') or eid))}")
            body.append(f"label = {toml_str(str(lvl.get('label') or eid))}")
            body.append(f"description = {toml_str(str(lvl.get('description') or ''))}")
            body.append(f"default = {'true' if lvl.get('default') else 'false'}")
            body.append("")
    else:
        body.append("supports_reasoning_effort = false")
        body.append("")

# bare-id aliases for -m grok-4.5 convenience (only ids with official meta)
seen = set()
for m in items:
    mid = str(m["id"])
    if mid not in meta or mid in seen:
        continue
    if not re.fullmatch(r"[A-Za-z0-9._-]+", mid):
        continue
    seen.add(mid)
    info = meta[mid]
    efforts = info.get("reasoning_efforts")
    supports = (
        info.get("supports_reasoning_effort") is True
        and isinstance(efforts, list)
        and len(efforts) > 0
    )
    de = info.get("reasoning_effort") or default_effort
    ctx = info.get("context_window") or 256000
    backend = info.get("api_backend") or ("responses" if supports or "4." in mid else "chat_completions")
    label = info.get("system_prompt_label") or info.get("name")
    body.append(f'[model."{mid}"]')
    body.append(f"model = {toml_str(mid)}")
    body.append(f"base_url = {toml_str(base)}")
    body.append(f"name = {toml_str(mid + ' (3p)')}")
    body.append(f"api_key = {toml_str(key)}")
    body.append('env_key = "RELAY_API_KEY"')
    body.append(f"api_backend = {toml_str(backend)}")
    body.append(f"context_window = {int(ctx) if isinstance(ctx, int) else 256000}")
    if label:
        body.append(f"system_prompt_label = {toml_str(str(label))}")
    if supports:
        body.append("supports_reasoning_effort = true")
        body.append(f"reasoning_effort = {toml_str(str(de))}")
        body.append("")
        for lvl in efforts:
            if not isinstance(lvl, dict):
                continue
            eid = str(lvl.get("id") or lvl.get("value") or "")
            if not eid:
                continue
            body.append(f'[[model."{mid}".reasoning_efforts]]')
            body.append(f"id = {toml_str(eid)}")
            body.append(f"value = {toml_str(str(lvl.get('value') or eid))}")
            body.append(f"label = {toml_str(str(lvl.get('label') or eid))}")
            body.append(f"description = {toml_str(str(lvl.get('description') or ''))}")
            body.append(f"default = {'true' if lvl.get('default') else 'false'}")
            body.append("")
    else:
        body.append("supports_reasoning_effort = false")
        body.append("")

lines = list(preserved)
lines.append("# grok-3p isolated home — official ~/.grok is never modified")
lines.append("[models]")
lines.append(f'default = {toml_str(default_section or "3p-00-grok-4.5")}')
lines.append(f'default_reasoning_effort = {toml_str(default_effort)}')
lines.append("")
lines.extend(body)

config_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
Path(os.environ["SYNC_STATE"]).write_text(str(int(time.time())))
print(
    f"synced models={len(items)} effort_models={effort_n} default={default_section} "
    f"newest={items[0].get('id')} home={g3p}",
    file=sys.stderr,
)
PY
}

apply_runtime_env() {
  export GROK_HOME="$G3P"
  # Never load official auth.json
  export GROK_AUTH_PATH="${G3P}/auth.3p-disabled"
  # Do not use models_base_url — ordered 3p-NN catalog lives in our config
  unset GROK_MODELS_BASE_URL 2>/dev/null || true
  unset GROK_MODELS_LIST_URL 2>/dev/null || true
  unset GROK_XAI_API_BASE_URL 2>/dev/null || true
  unset XAI_API_BASE_URL 2>/dev/null || true
  unset XAI_API_KEY 2>/dev/null || true
  unset GROK_CLI_CHAT_PROXY_BASE_URL 2>/dev/null || true
  export RELAY_BASE_URL RELAY_API_KEY
}

cmd_install() {
  need_creds
  install_cli
  cleanup_official_if_polluted
  bootstrap_home
  write_env
  sync_models 1
  mkdir -p "$HOME/.local/bin"
  local self
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  python3 - "$self" "$HOME/.local/bin/grok-3p" "$RELAY_BASE_URL" "$RELAY_API_KEY" <<'PY'
import os, sys
from pathlib import Path
src, dst, base, key = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
out, sb, sk = [], False, False
for line in Path(src).read_text().splitlines(True):
    if line.startswith("export RELAY_BASE_URL=") and not sb:
        out.append(f'export RELAY_BASE_URL="{base}"\n'); sb = True
    elif line.startswith("export RELAY_API_KEY=") and not sk:
        out.append(f'export RELAY_API_KEY="{key}"\n'); sk = True
    else:
        out.append(line)
Path(dst).write_text("".join(out))
os.chmod(dst, 0o755)
print("installed", dst)
PY
  local path_line='export PATH="$HOME/.local/bin:$PATH"' found_rc=0
  for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    found_rc=1
    if ! grep -Fqx "$path_line" "$rc" 2>/dev/null; then
      cat >> "$rc" <<'HOOK'

# >>> grok-3p single-script >>>
export PATH="$HOME/.local/bin:$PATH"
# <<< grok-3p single-script <<<
HOOK
    fi
  done
  if (( found_rc == 0 )); then
    case "${SHELL:-}" in
      */zsh) rc="$HOME/.zshrc" ;;
      */bash) rc="$HOME/.bashrc" ;;
      *) rc="$HOME/.profile" ;;
    esac
    cat >> "$rc" <<'HOOK'

# >>> grok-3p single-script >>>
export PATH="$HOME/.local/bin:$PATH"
# <<< grok-3p single-script <<<
HOOK
  fi
  echo "Install OK — 可同时开："
  echo "  grok      → ~/.grok     （官方订阅，login）"
  echo "  grok-3p   → ~/.grok-3p  （中转，无需 login）"
  echo "  凭证: $ENV_FILE"
}

cmd_doctor() {
  need_creds
  find_grok
  cleanup_official_if_polluted
  bootstrap_home
  echo "grok-3p doctor"
  echo "  official home:   $OFFICIAL  (never modified by grok-3p)"
  echo "  3p home:         $G3P"
  echo "  concurrent OK:   yes (isolated config)"
  echo "  RELAY_BASE_URL:  $RELAY_BASE_URL"
  echo "  RELAY_API_KEY:   ${RELAY_API_KEY:0:8}… (${#RELAY_API_KEY} chars)"
  echo "  env file:        $ENV_FILE$([ -f "$ENV_FILE" ] && echo ' [ok]' || echo ' [missing]')"
  echo "  grok binary:     ${GROK_BIN:-MISSING}"
  echo "  3p auth.json:    $([ -f "$G3P/auth.json" ] && echo 'PRESENT (bad)' || echo 'absent (good)')"
  echo "  official config: $([ -f "$OFFICIAL/config.toml" ] && (grep -q '3p-00-' "$OFFICIAL/config.toml" 2>/dev/null && echo 'STILL HAS 3p (bad)' || echo 'clean') || echo 'missing')"
  local code
  code=$(curl -sS -o /tmp/grok-3p-models.json -w '%{http_code}' \
    -H "Authorization: Bearer ${RELAY_API_KEY}" \
    "${RELAY_BASE_URL}/models" || echo err)
  echo "  GET /models:     HTTP $code"
  if [[ "$code" == "200" ]]; then
    python3 - <<'PY'
import json
from pathlib import Path
d=json.loads(Path("/tmp/grok-3p-models.json").read_text())
items=[m for m in (d.get("data") or d.get("models") or []) if isinstance(m, dict) and m.get("id")]
def created(m):
    try: c=int(m.get("created") or 0)
    except: return 0
    return c//1000 if c>10_000_000_000 else c
items.sort(key=lambda m: (-created(m), str(m["id"])))
print("  newest-first:")
for i,m in enumerate(items[:6]):
    print(f"    3p-{i:02d}  {m['id']}")
if len(items)>6:
    print(f"    … +{len(items)-6} more")
PY
  fi
}

cmd_run() {
  need_creds
  find_grok
  [[ -n "$GROK_BIN" ]] || install_cli
  cleanup_official_if_polluted
  bootstrap_home
  write_env
  rm -f "$G3P/auth.json" 2>/dev/null || true
  sync_models 0
  apply_runtime_env
  exec "$GROK_BIN" "$@"
}

case "${1:-}" in
  install) shift; cmd_install; exit 0 ;;
  doctor)  shift; cmd_doctor; exit 0 ;;
  sync)
    need_creds
    cleanup_official_if_polluted
    bootstrap_home
    write_env
    sync_models 1
    echo "grok-3p: models synced → $CONFIG_PATH"
    exit 0
    ;;
  restore)
    # compat: only cleans official if polluted
    cleanup_official_if_polluted
    echo "grok-3p: official home checked/cleaned (3p uses isolated $G3P)"
    exit 0
    ;;
esac

cmd_run "$@"
