#!/usr/bin/env bash
# =============================================================================
# grok-3p — codex-3p 同款思路：共用官方 home，只把「模型/鉴权」切到中转
#
# 保持（你明确要求过的）：
#   1. effort 与官方真实元数据一致（从 CLI 内嵌 + models_cache 抄，不猜名字）
#   2. 新模型在最上面（按 /models 的 created 降序 → 3p-00 / 3p-01 …）
#   3. 直连中转 SSE（无本地推理反代 → 可流式）
#
# 与官方一致的部分：
#   共用 ~/.grok（session / skills / UI / marketplace / bundled …）
#   启动时注入 [model."3p-NN-…"]，退出时还原 config.toml（不污染 `grok`）
#   GROK_AUTH_PATH → 不存在的文件，躲开 0.2.106 JWT 盖 key → 401
#
# 顶部两行改成你的中转：
export RELAY_BASE_URL="https://YOUR_RELAY_HOST/v1"
export RELAY_API_KEY="sk-YOUR_RELAY_KEY"
# =============================================================================

set -euo pipefail

GROK_HOME_DIR="${GROK_HOME_DIR:-$HOME/.grok}"
AUTH_3P_PATH="${GROK_3P_AUTH_PATH:-$GROK_HOME_DIR/auth.3p-disabled}"
ENV_FILE="${GROK_3P_ENV_FILE:-$GROK_HOME_DIR/thirdparty.env}"
LEGACY_ENV_FILE="${HOME}/.grok-3p/relay.env"
CONFIG_PATH="${GROK_HOME_DIR}/config.toml"
# Snapshot of official config while 3p is running (restored on exit / next start)
SNAP_PATH="${GROK_HOME_DIR}/config.toml.pre-3p"
SNAP_META="${GROK_HOME_DIR}/config.toml.pre-3p.pid"
SYNC_STATE="${GROK_HOME_DIR}/3p-sync-state"
GROK_BIN=""
# 1 = we own a snapshot that must be restored
OWNS_SNAP=0

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
  load_dotenv "$LEGACY_ENV_FILE"
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
  if [[ -x "$GROK_HOME_DIR/bin/grok" ]]; then
    GROK_BIN="$GROK_HOME_DIR/bin/grok"
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
  [[ -n "$GROK_BIN" ]] || die "grok binary missing"
}

write_env() {
  mkdir -p "$GROK_HOME_DIR"
  umask 077
  cat > "$ENV_FILE" <<EOF
# Third-party credentials for grok-3p (like ~/.codex/thirdparty.env)
RELAY_BASE_URL=${RELAY_BASE_URL}
RELAY_API_KEY=${RELAY_API_KEY}
EOF
  chmod 600 "$ENV_FILE"
}

# Restore official config if a previous 3p run crashed mid-flight.
restore_config_if_needed() {
  if [[ -f "$SNAP_PATH" ]]; then
    cp -p "$SNAP_PATH" "$CONFIG_PATH"
    rm -f "$SNAP_PATH" "$SNAP_META"
    echo "grok-3p: restored official config.toml from crash snapshot" >&2
  fi
}

take_config_snapshot() {
  restore_config_if_needed
  [[ -f "$CONFIG_PATH" ]] || die "missing $CONFIG_PATH — 请先至少启动过一次官方 grok"
  cp -p "$CONFIG_PATH" "$SNAP_PATH"
  echo "$$" > "$SNAP_META"
  OWNS_SNAP=1
}

restore_config() {
  if [[ "$OWNS_SNAP" == "1" && -f "$SNAP_PATH" ]]; then
    cp -p "$SNAP_PATH" "$CONFIG_PATH"
    rm -f "$SNAP_PATH" "$SNAP_META"
    OWNS_SNAP=0
  fi
}

# Build 3p model sections: newest-first + real effort metadata.
# Writes over config.toml AFTER snapshot. Official sections (ui/marketplace/cli) preserved.
sync_models() {
  local force="${1:-0}"
  local ttl="${GROK_3P_SYNC_TTL:-300}"
  if [[ "$force" != "1" && -f "$SYNC_STATE" && -f "$CONFIG_PATH" ]]; then
    local last now
    last=$(cat "$SYNC_STATE" 2>/dev/null || echo 0)
    now=$(date +%s)
    # Only skip re-fetch if we're already inside a 3p-injected config
    if (( now - last < ttl )) && grep -q '\[model\."3p-00-' "$CONFIG_PATH" 2>/dev/null; then
      return 0
    fi
  fi

  RELAY_BASE_URL="$RELAY_BASE_URL" RELAY_API_KEY="$RELAY_API_KEY" \
  GROK_HOME_DIR="$GROK_HOME_DIR" CONFIG_PATH="$CONFIG_PATH" SNAP_PATH="$SNAP_PATH" \
  SYNC_STATE="$SYNC_STATE" \
  python3 <<'PY'
import json, os, re, sys, time
from pathlib import Path
from urllib.request import Request, urlopen

base = os.environ["RELAY_BASE_URL"].rstrip("/")
key = os.environ["RELAY_API_KEY"]
home = Path(os.environ["GROK_HOME_DIR"])
config_path = Path(os.environ["CONFIG_PATH"])
snap_path = Path(os.environ["SNAP_PATH"])
# Prefer official snapshot as template (ui/marketplace untouched source of truth)
template_path = snap_path if snap_path.is_file() else config_path

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

# 2) 新模型在最上面
items.sort(key=lambda m: (-created(m), str(m["id"])))

# 1) effort：只抄官方真实元数据（CLI 内嵌 default_models + models_cache），不猜
meta = {}
bin_path = home / "bin" / "grok"
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

cache = home / "models_cache.json"
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

# Preserve official non-model sections from snapshot/template
official_txt = template_path.read_text(encoding="utf-8") if template_path.is_file() else ""

def extract_section(txt: str, header: str) -> list[str]:
    """header like '[ui]' or '[[marketplace.sources]]' — take until next top-level table."""
    # For simple [section]
    m = re.search(rf'(?ms)^{re.escape(header)}\s*\n(.*?)(?=^\[|\Z)', txt)
    if not m:
        return []
    lines = [header]
    for line in m.group(1).splitlines():
        if line.strip().startswith("#") and not line.strip():
            continue
        lines.append(line.rstrip())
    # trim trailing blanks
    while lines and lines[-1].strip() == "":
        lines.pop()
    lines.append("")
    return lines

def extract_array_tables(txt: str, prefix: str) -> list[str]:
    """Keep all [[prefix...]] blocks (e.g. marketplace.sources)."""
    out = []
    for m in re.finditer(rf'(?ms)^\[\[{re.escape(prefix)}(?:\.[^\]]+)?\]\]\s*\n.*?(?=^\[|\Z)', txt):
        block = m.group(0).rstrip() + "\n"
        out.append(block)
    return out

preserved: list[str] = []
for hdr in ("[cli]", "[marketplace]", "[ui]", "[terminal]", "[hooks]"):
    part = extract_section(official_txt, hdr)
    if part:
        preserved.extend(part)
# marketplace.sources array tables (after [marketplace] body — re-append if present)
# extract_section already stopped before [[; grab them explicitly
for block in extract_array_tables(official_txt, "marketplace"):
    preserved.append(block.rstrip())
    preserved.append("")

if not any(l.startswith("[ui]") for l in preserved):
    preserved.extend([
        "[ui]",
        'permission_mode = "always-approve"',
        "yolo = false",
        "",
    ])
if not any(l.startswith("[cli]") for l in preserved):
    preserved.extend(["[cli]", 'installer = "internal"', ""])

# default effort from official [models] if any
default_effort = "high"
m_eff = re.search(r'(?m)^\s*default_reasoning_effort\s*=\s*"([^"]+)"', official_txt)
if m_eff:
    default_effort = m_eff.group(1)

body: list[str] = []
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
    # Only use official default effort when model actually supports it
    if supports:
        de = info.get("reasoning_effort") or default_effort
    else:
        de = None
    ctx = info.get("context_window")
    backend = info.get("api_backend")
    label = info.get("system_prompt_label") or info.get("name")
    if not isinstance(ctx, int) or ctx <= 0:
        # soft fallback for context only (NOT for effort levels)
        ctx = 500000 if "4.5" in mid else (
            256000 if re.search(r"4\.3|4\.20|build|multi-agent", mid) else 128000
        )
    if backend not in ("responses", "chat_completions", "messages"):
        backend = "responses" if (supports or re.search(r"grok-4|grok-build", mid)) else "chat_completions"

    # Display: NN · id  so picker order is obvious; section key 3p-NN- forces sort
    name = f"{i:02d} · {mid}"
    body.append(f'[model."{section}"]')
    body.append(f"model = {toml_str(mid)}")
    body.append(f"base_url = {toml_str(base)}")
    body.append(f"name = {toml_str(name)}")
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

# Optional bare-id aliases ONLY for ids that have official meta (effort menus),
# so -m grok-4.5 also works. Name suffix (3p) keeps them distinct from subscription
# if someone ever mixed lists — with AUTH_PATH empty, subscription isn't loaded.
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
lines.append("# --- injected by grok-3p (restored on exit); direct relay, no local proxy ---")
lines.append("[models]")
lines.append(f'default = {toml_str(default_section or "3p-00-grok-4.5")}')
lines.append(f'default_reasoning_effort = {toml_str(default_effort)}')
lines.append("")
lines.extend(body)

config_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
Path(os.environ["SYNC_STATE"]).write_text(str(int(time.time())))
print(
    f"synced models={len(items)} effort_models={effort_n} default={default_section} "
    f"newest={items[0].get('id')} order_by=created_desc",
    file=sys.stderr,
)
PY
}

apply_runtime_env() {
  export GROK_HOME="$GROK_HOME_DIR"
  export GROK_AUTH_PATH="$AUTH_3P_PATH"
  if [[ -e "$AUTH_3P_PATH" ]]; then
    export GROK_AUTH_PATH="${AUTH_3P_PATH}.missing"
  fi
  # Per-model base_url handles inference (streaming). Do NOT set models_base_url:
  # that would replace our ordered 3p-NN catalog with raw /models order.
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
  write_env
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
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [[ -f "$rc" ]] || continue
    if ! grep -q 'grok-3p single-script' "$rc" 2>/dev/null; then
      cat >> "$rc" <<'HOOK'

# >>> grok-3p single-script >>>
export PATH="$HOME/.local/bin:$PATH"
# <<< grok-3p single-script <<<
HOOK
    fi
  done
  echo "Install OK."
  echo "  Official:     grok          (subscription, untouched config)"
  echo "  Third-party:  grok-3p       (same ~/.grok; 3p models + real effort; newest first)"
  echo "  Creds:        $ENV_FILE"
}

cmd_doctor() {
  need_creds
  find_grok
  restore_config_if_needed
  echo "grok-3p doctor"
  echo "  GROK_HOME (shared):  $GROK_HOME_DIR"
  echo "  GROK_AUTH_PATH:      $AUTH_3P_PATH (must not exist → no JWT)"
  echo "  RELAY_BASE_URL:      $RELAY_BASE_URL"
  echo "  RELAY_API_KEY:       ${RELAY_API_KEY:0:8}… (${#RELAY_API_KEY} chars)"
  echo "  env file:            $ENV_FILE$([ -f "$ENV_FILE" ] && echo ' [ok]' || echo ' [missing]')"
  echo "  grok binary:         ${GROK_BIN:-MISSING}"
  echo "  config snapshot:     $([ -f "$SNAP_PATH" ] && echo 'PRESENT (will restore)' || echo 'none')"
  echo "  official auth.json:  $([ -f "$GROK_HOME_DIR/auth.json" ] && echo present || echo absent) (ignored by grok-3p)"
  local code
  code=$(curl -sS -o /tmp/grok-3p-models.json -w '%{http_code}' \
    -H "Authorization: Bearer ${RELAY_API_KEY}" \
    "${RELAY_BASE_URL}/models" || echo err)
  echo "  GET /models:         HTTP $code"
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
for i,m in enumerate(items[:8]):
    print(f"    3p-{i:02d}  created={created(m)}  {m['id']}")
if len(items)>8:
    print(f"    … +{len(items)-8} more")
PY
  fi
}

cmd_run() {
  need_creds
  find_grok
  [[ -n "$GROK_BIN" ]] || install_cli
  write_env
  take_config_snapshot
  # Always force-sync when taking a fresh snapshot so order/effort are current
  sync_models 1
  apply_runtime_env

  # Restore official config no matter how we exit (incl. Ctrl-C)
  trap 'restore_config' EXIT INT TERM

  # Run in-process wait so trap fires (don't exec — trap wouldn't restore)
  set +e
  "$GROK_BIN" "$@"
  local rc=$?
  set -e
  restore_config
  trap - EXIT INT TERM
  exit "$rc"
}

case "${1:-}" in
  install) shift; cmd_install; exit 0 ;;
  doctor)  shift; cmd_doctor; exit 0 ;;
  sync)
    need_creds
    write_env
    take_config_snapshot
    sync_models 1
    # leave injected config? No — sync alone should not leave 3p config for official.
    # Write a preview then restore, or keep for inspection via GROK_3P_KEEP=1
    if [[ "${GROK_3P_KEEP:-0}" == "1" ]]; then
      echo "grok-3p: config left injected (GROK_3P_KEEP=1). Run: grok-3p restore"
      OWNS_SNAP=0  # don't auto-restore on shell exit of this subcommand... we still hold snap file
    else
      restore_config
      echo "grok-3p: models synced (preview restored; will re-inject on next grok-3p run)"
    fi
    exit 0
    ;;
  restore)
    OWNS_SNAP=1
    # force restore from snap if present
    if [[ -f "$SNAP_PATH" ]]; then
      cp -p "$SNAP_PATH" "$CONFIG_PATH"
      rm -f "$SNAP_PATH" "$SNAP_META"
      echo "grok-3p: restored $CONFIG_PATH"
    else
      echo "grok-3p: no snapshot to restore"
    fi
    exit 0
    ;;
esac

cmd_run "$@"
