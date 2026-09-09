#!/usr/bin/env bash
set -uo pipefail

# GitHub personal private repository migration helper v5.3
# Human-facing flow: Chinese, one-shot per repo, batch capable.
# Parent shell deliberately does NOT use `set -e`; each repository runs in an
# isolated strict subshell so one repository cannot silently terminate the whole batch.

exec 3<&0
exec 4>&2
umask 077

GH_API_VERSION="${GH_API_VERSION:-2026-03-10}"
SCRIPT_VERSION="5.3"
STATE_FORMAT_VERSION="7"

ui() { printf '%s\n' "$*"; }
ui_blank() { printf '\n'; }
ui_step() { printf '\n▶ %s\n' "$*"; }

prompt_line() {
  local var_name="$1" label="$2" default="${3:-}" value
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$label" "$default" >&4
  else
    printf '%s: ' "$label" >&4
  fi
  IFS= read -r value <&3 || value=''
  [ -n "$value" ] || value="$default"
  printf -v "$var_name" '%s' "$value"
}

prompt_hidden_token() {
  local var_name="$1" label="$2" current
  eval "current=\${${var_name}:-}"
  if [ -z "$current" ]; then
    printf '%s: ' "$label" >&4
    IFS= read -r -s current <&3 || current=''
    printf '\n' >&4
    [ -n "$current" ] || return 1
    printf -v "$var_name" '%s' "$current"
  fi
}

confirm() {
  local question="$1" default_yes="${2:-0}" reply suffix
  if [ "$default_yes" = "1" ]; then suffix='[Y/n]'; else suffix='[y/N]'; fi
  printf '%s %s ' "$question" "$suffix" >&4
  IFS= read -r reply <&3 || reply=''
  case "$reply" in
    y|Y|yes|YES|Yes) return 0 ;;
    n|N|no|NO|No) return 1 ;;
    '') [ "$default_yes" = "1" ] ;;
    *) return 1 ;;
  esac
}

check_dependencies_cn() {
  local missing='' cmd
  for cmd in git gh jq git-lfs; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  if [ -n "$missing" ]; then
    ui "❌ 缺少必要工具：${missing# }"
    ui 'Mac 请执行：brew install gh jq git-lfs'
    return 1
  fi
  ui '✓ 运行环境已就绪。'
}

src_api() {
  GH_TOKEN="$SRC_TOKEN" GH_PROMPT_DISABLED=1 gh api \
    -H 'Accept: application/vnd.github+json' \
    -H "X-GitHub-Api-Version: $GH_API_VERSION" "$@"
}

dst_api() {
  GH_TOKEN="$DST_TOKEN" GH_PROMPT_DISABLED=1 gh api \
    -H 'Accept: application/vnd.github+json' \
    -H "X-GitHub-Api-Version: $GH_API_VERSION" "$@"
}

same_ci() {
  local a b
  a=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  b=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  [ "$a" = "$b" ]
}

print_startup_intro_cn() {
  ui 'GitHub 私有仓库迁移工具'
  ui '====================='
  ui '用途：把一个或多个个人账号下的 GitHub 私有仓库迁到另一个个人账号。'
  ui '每个仓库会自动完成：代码与历史复制 → 常用 Actions 配置迁移 → 最终同步 → Secret 检查 → 安全恢复 Actions。'
  ui '成功范围不包含 Issues/PR/Discussions、Stars、GitHub Projects、Actions 运行历史、Release 页面/附件、Wiki 内容、Pages 配置等 GitHub 托管状态。'
  ui '只有必须由你决定的事项才会停下来询问；Git/GitHub 的详细输出只写日志。'
  ui_blank
  ui '需要两个 Classic PAT：'
  ui '  - 源账号：repo'
  ui '  - 目标账号：repo + workflow'
  ui '完成一个仓库后，会明确告诉你结果，并询问是否继续迁下一个；下一仓库可复用同一组 PAT。'
  ui_blank
}

check_classic_scope() {
  # Best-effort proactive validation. Classic PAT responses expose X-OAuth-Scopes.
  # If the header is absent, do not reject (GitHub may change header behavior).
  local token="$1" needed="$2" tmp scopes
  tmp=$(mktemp "${TMPDIR:-/tmp}/gh-migrate-scope.XXXXXX") || return 0
  if GH_TOKEN="$token" GH_PROMPT_DISABLED=1 gh api -i user >"$tmp" 2>/dev/null; then
    scopes=$(tr '[:upper:]' '[:lower:]' <"$tmp" | awk '/^x-oauth-scopes:/ {sub(/^[^:]*:[[:space:]]*/,""); gsub(/\r/,""); print; exit}')
    if [ -n "$scopes" ]; then
      printf '%s' "$scopes" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -Fx "$needed" >/dev/null 2>&1 || {
        rm -f "$tmp"
        return 1
      }
    fi
  fi
  rm -f "$tmp"
  return 0
}

authenticate_accounts_cn() {
  local src_login dst_login

  if ! prompt_hidden_token SRC_TOKEN '源账号 PAT（输入隐藏）'; then
    ui '❌ 源账号 PAT 不能为空。'
    return 1
  fi
  if ! src_login=$(GH_TOKEN="$SRC_TOKEN" GH_PROMPT_DISABLED=1 gh api user --jq .login 2>/dev/null); then
    ui '❌ 源账号 PAT 无法认证。'
    return 1
  fi
  if ! check_classic_scope "$SRC_TOKEN" repo; then
    ui '❌ 源账号 PAT 缺少 repo 权限。'
    return 1
  fi
  SRC_LOGIN="$src_login"
  ui "✓ 源账号：$SRC_LOGIN"

  if ! prompt_hidden_token DST_TOKEN '目标账号 PAT（输入隐藏）'; then
    ui '❌ 目标账号 PAT 不能为空。'
    return 1
  fi
  if ! dst_login=$(GH_TOKEN="$DST_TOKEN" GH_PROMPT_DISABLED=1 gh api user --jq .login 2>/dev/null); then
    ui '❌ 目标账号 PAT 无法认证。'
    return 1
  fi
  if ! check_classic_scope "$DST_TOKEN" repo; then
    ui '❌ 目标账号 PAT 缺少 repo 权限。'
    return 1
  fi
  if ! check_classic_scope "$DST_TOKEN" workflow; then
    ui '❌ 目标账号 PAT 缺少 workflow 权限。'
    return 1
  fi
  DST_LOGIN="$dst_login"
  ui "✓ 目标账号：$DST_LOGIN"

  if same_ci "$SRC_LOGIN" "$DST_LOGIN"; then
    ui '⚠ 源账号和目标账号相同；仅当你确实要在同一账号内复制仓库时才继续。'
  fi
}

setup_pair_context() {
  SRC_OWNER=${SRC_REPO%%/*}
  SRC_NAME=${SRC_REPO#*/}
  DST_OWNER=${DST_REPO%%/*}
  DST_NAME=${DST_REPO#*/}
  STATE_DIR="./gh-migrate-${SRC_OWNER}-${SRC_NAME}-to-${DST_OWNER}-${DST_NAME}"
}

prompt_repo_pair_cn() {
  local src_input dst_input default_dst
  prompt_line src_input '源仓库名（只填仓库名即可）'
  [ -n "$src_input" ] || { ui '❌ 必须填写源仓库名。'; return 1; }
  case "$src_input" in
    */*) SRC_REPO="$src_input" ;;
    *) SRC_REPO="$SRC_LOGIN/$src_input" ;;
  esac

  if ! same_ci "${SRC_REPO%%/*}" "$SRC_LOGIN"; then
    ui '❌ 本工具当前只支持源 PAT 本人名下的个人仓库。'
    return 1
  fi

  default_dst=${SRC_REPO#*/}
  prompt_line dst_input '目标仓库名' "$default_dst"
  case "$dst_input" in
    */*) DST_REPO="$dst_input" ;;
    *) DST_REPO="$DST_LOGIN/$dst_input" ;;
  esac

  if ! same_ci "${DST_REPO%%/*}" "$DST_LOGIN"; then
    ui '❌ 本工具当前只支持迁到目标 PAT 本人名下的个人仓库。'
    return 1
  fi

  if same_ci "$SRC_REPO" "$DST_REPO"; then
    ui '❌ 源仓库和目标仓库不能是同一个仓库。'
    return 1
  fi

  setup_pair_context
}

prepare_stale_state_cn() {
  # Only treat an API 404 as "destination missing". Network/rate-limit/auth
  # failures must never be mistaken for deletion.
  local current_id='' expected_id='' backup errf

  [ -d "$STATE_DIR" ] || return 0
  [ -f "$STATE_DIR/destination-repository-id" ] || return 0

  expected_id=$(cat "$STATE_DIR/destination-repository-id" 2>/dev/null || true)
  errf=$(mktemp "${TMPDIR:-/tmp}/gh-migrate-dstcheck.XXXXXX") || return 1
  if current_id=$(dst_api "repos/$DST_REPO" --jq .id 2>"$errf"); then
    rm -f "$errf"
    if [ -n "$expected_id" ] && [ "$current_id" != "$expected_id" ]; then
      ui '❌ 检测到同名目标仓库，但它不是之前迁移记录中的那个仓库。'
      ui '为避免覆盖现有仓库，本次不会继续。'
      return 1
    fi
    return 0
  fi

  if ! grep -q 'HTTP 404' "$errf" 2>/dev/null; then
    ui '❌ 暂时无法确认目标仓库状态（可能是网络、GitHub API 或权限问题）。'
    ui '本次不会假设仓库已被删除，也不会改动旧迁移记录。'
    rm -f "$errf"
    return 1
  fi
  rm -f "$errf"

  ui_blank
  ui '⚠ 检测到旧迁移记录，但目标仓库已经不存在。'
  if ! confirm '是否备份旧记录并从头重新迁移这个仓库？' 1; then
    ui '已跳过这个仓库。'
    return 2
  fi

  backup="${STATE_DIR}.stale-$(date '+%Y%m%d-%H%M%S')"
  if ! mv "$STATE_DIR" "$backup"; then
    ui '❌ 无法备份旧迁移记录，请检查当前目录权限。'
    return 1
  fi
  ui "✓ 旧迁移记录已备份：$backup"
  return 0
}

# ---------------- Repository-isolated strict execution ----------------

repo_log() {
  [ -n "${LOG_FILE:-}" ] || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

best_effort_disable_actions_after_failure() {
  FAILSAFE_ACTIONS_RESULT='not-needed'
  [ "${TARGET_READY:-0}" = '1' ] || return 0
  [ "${MIGRATION_SUCCESS:-0}" = '1' ] && return 0

  printf '{"enabled":false}\n' >"$STATE_DIR/.failsafe-actions-disabled.json" 2>/dev/null || true
  if dst_api -X PUT "repos/$DST_REPO/actions/permissions" --input "$STATE_DIR/.failsafe-actions-disabled.json" >>"${LOG_FILE:-/dev/null}" 2>&1; then
    FAILSAFE_ACTIONS_RESULT='disabled'
  else
    FAILSAFE_ACTIONS_RESULT='unknown'
  fi
  rm -f "$STATE_DIR/.failsafe-actions-disabled.json" 2>/dev/null || true
}

print_failure_safety_cn() {
  case "${FAILSAFE_ACTIONS_RESULT:-not-needed}" in
    disabled) ui '   为安全起见，目标仓库 Actions 已重新/继续保持关闭。' ;;
    unknown)  ui '   ⚠ 无法确认目标 Actions 是否关闭，请立即到 GitHub 检查。' ;;
    *)        ui '   如果目标仓库已创建，本工具不会主动把未完成迁移标记为成功。' ;;
  esac
}

repo_die() {
  local msg="$1"
  trap - ERR
  [ -z "${RUN_RESULT_FILE:-}" ] || printf 'failure\n' >"$RUN_RESULT_FILE" 2>/dev/null || true
  repo_log "ERROR: $msg"
  best_effort_disable_actions_after_failure
  ui_blank
  ui "❌ 当前仓库没有完成：${SRC_REPO#*/}"
  ui "   $SRC_REPO → $DST_REPO"
  ui "   原因：$msg"
  print_failure_safety_cn
  ui '   修正问题后重新运行同一个脚本即可继续。'
  [ -z "${LOG_FILE:-}" ] || ui "   详细日志：$LOG_FILE"
  exit 1
}

repo_unexpected_error() {
  local code=$?
  trap - ERR
  [ -z "${RUN_RESULT_FILE:-}" ] || printf 'failure\n' >"$RUN_RESULT_FILE" 2>/dev/null || true
  repo_log "UNEXPECTED ERROR: step=${CURRENT_STEP:-unknown} exit=$code"
  best_effort_disable_actions_after_failure
  ui_blank
  ui "❌ 当前仓库没有完成：${SRC_REPO#*/}"
  ui "   $SRC_REPO → $DST_REPO"
  ui "   失败位置：${CURRENT_STEP:-执行过程中出现异常}"
  print_failure_safety_cn
  [ -z "${LOG_FILE:-}" ] || ui "   详细日志：$LOG_FILE"
  exit "$code"
}

make_askpass() {
  ASKPASS_FILE=$(mktemp "${TMPDIR:-/tmp}/gh-migrate-askpass.XXXXXX") || repo_die '无法创建临时认证文件'
  cat >"$ASKPASS_FILE" <<'ASK'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) printf '%s\n' "$GH_MIGRATE_TOKEN" ;;
  *) printf '\n' ;;
esac
ASK
  chmod 700 "$ASKPASS_FILE"
}

git_with_token() {
  local token="$1"
  shift
  GH_MIGRATE_TOKEN="$token" \
  GIT_ASKPASS="$ASKPASS_FILE" \
  GIT_TERMINAL_PROMPT=0 \
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=credential.helper \
  GIT_CONFIG_VALUE_0= \
    "$@"
}

repo_cleanup() {
  [ -n "${ASKPASS_FILE:-}" ] && rm -f "$ASKPASS_FILE" || true
  [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR" || true
}

critical_src_json() {
  local endpoint="$1" out="$2" desc="$3"
  if ! src_api "$endpoint" >"$out" 2>"$out.err"; then
    cat "$out.err" >>"$LOG_FILE" 2>/dev/null || true
    rm -f "$out.err"
    repo_die "无法读取源仓库的${desc}；不能把“读取失败”当成“没有配置”"
  fi
  rm -f "$out.err"
}

critical_dst_json() {
  local endpoint="$1" out="$2" desc="$3"
  if ! dst_api "$endpoint" >"$out" 2>"$out.err"; then
    cat "$out.err" >>"$LOG_FILE" 2>/dev/null || true
    rm -f "$out.err"
    repo_die "无法读取目标仓库的${desc}"
  fi
  rm -f "$out.err"
}

critical_paginate() {
  # Usage: critical_paginate src|dst endpoint jq_filter outfile description
  local side="$1" endpoint="$2" filter="$3" out="$4" desc="$5" tmp
  tmp="$out.stream"
  : >"$tmp"
  if [ "$side" = src ]; then
    if ! src_api --paginate "$endpoint" --jq "$filter" >"$tmp" 2>"$out.err"; then
      cat "$out.err" >>"$LOG_FILE" 2>/dev/null || true
      rm -f "$tmp" "$out.err"
      repo_die "无法读取源仓库的${desc}；不能把“读取失败”当成“0 项”"
    fi
  else
    if ! dst_api --paginate "$endpoint" --jq "$filter" >"$tmp" 2>"$out.err"; then
      cat "$out.err" >>"$LOG_FILE" 2>/dev/null || true
      rm -f "$tmp" "$out.err"
      repo_die "无法读取目标仓库的${desc}"
    fi
  fi
  rm -f "$out.err"
  if [ -s "$tmp" ]; then
    jq -s '.' "$tmp" >"$out" || repo_die "解析${desc}失败"
  else
    printf '[]\n' >"$out"
  fi
  rm -f "$tmp"
}

http_status_from_error_file() {
  local f="$1"
  grep -Eo 'HTTP [0-9]{3}' "$f" 2>/dev/null | tail -n 1 | awk '{print $2}' || true
}

short_error_from_file() {
  local f="$1" detail
  detail=$(grep -E '(^gh:|HTTP [0-9]{3}|^[[:space:]]*message:)' "$f" 2>/dev/null | tail -n 1 | sed -E 's/^gh:[[:space:]]*//' || true)
  [ -n "$detail" ] || detail=$(tail -n 1 "$f" 2>/dev/null || true)
  printf '%s' "$detail" | cut -c1-220
}

http_reason_cn() {
  case "${1:-unknown}" in
    401) printf '认证失败' ;;
    403) printf '权限、仓库策略或套餐限制' ;;
    404) printf '资源或功能在当前仓库上下文不可见' ;;
    409) printf '当前仓库状态不允许该操作' ;;
    422) printf 'GitHub 拒绝了当前参数或配置组合' ;;
    5??) printf 'GitHub 服务端异常' ;;
    unknown|'') printf '未取得明确 HTTP 状态' ;;
    *) printf 'GitHub API 返回异常状态' ;;
  esac
}

source_is_private_personal_repo() {
  [ -f "$STATE_DIR/source-repository.json" ] || return 1
  jq -e '.private == true and (.owner.type // "") == "User"' "$STATE_DIR/source-repository.json" >/dev/null 2>&1
}

write_review_unreadable_marker() {
  local out="$1" label="$2" endpoint="$3" status="$4" detail="$5"
  jq -nc     --arg label "$label" --arg endpoint "$endpoint" --arg status "$status" --arg detail "$detail"     '{label:$label,endpoint:$endpoint,http_status:$status,detail:$detail}' >"$out.unreadable"
}

review_paginate() {
  # Review-only information is classified into three states:
  #   readable -> authoritative data;
  #   not applicable -> feature is unavailable in this repository context and is
  #                     intentionally NOT shown to the user;
  #   unreadable -> an actual uncertainty, reported with the exact category/reason.
  local endpoint="$1" filter="$2" out="$3" label="$4" feature="${5:-generic}" tmp status detail
  tmp="$out.stream"
  rm -f "$out.unreadable" "$out.not-applicable"
  : >"$tmp"
  if ! src_api --paginate "$endpoint" --jq "$filter" >"$tmp" 2>"$out.err"; then
    status=$(http_status_from_error_file "$out.err")
    detail=$(short_error_from_file "$out.err")
    cat "$out.err" >>"$LOG_FILE" 2>/dev/null || true

    # GitHub documents Rulesets as unavailable for private repositories on the
    # Free personal plan. We deliberately do not request read:user merely to
    # discover the billing plan. For an owner-authenticated private personal
    # repository, a 404 from the repository Rulesets endpoint means the feature
    # is unavailable in this repository context; there is therefore nothing
    # actionable to migrate, so do not alarm the user.
    if [ "$feature" = 'rulesets' ] && [ "$status" = '404' ] && source_is_private_personal_repo; then
      printf '[]\n' >"$out"
      printf 'feature unavailable in this private personal repository context (HTTP 404)\n' >"$out.not-applicable"
      rm -f "$tmp" "$out.err"
      repo_log "REVIEW-ONLY not-applicable: ${label} (${endpoint}) HTTP 404; suppressed from user report"
      return 0
    fi

    write_review_unreadable_marker "$out" "$label" "$endpoint" "${status:-unknown}" "$detail"
    printf '[]\n' >"$out"
    rm -f "$tmp" "$out.err"
    repo_log "REVIEW-ONLY unreadable: ${label} (${endpoint}) HTTP ${status:-unknown}"
    return 0
  fi
  rm -f "$out.err"
  if [ -s "$tmp" ]; then jq -s '.' "$tmp" >"$out"; else printf '[]\n' >"$out"; fi
  rm -f "$tmp"
}

run_logged() {
  local desc="$1" tmp detail
  shift
  tmp=$(mktemp "${TMPDIR:-/tmp}/gh-migrate-command.XXXXXX") || repo_die "$desc"
  if "$@" >"$tmp" 2>&1; then
    cat "$tmp" >>"$LOG_FILE" 2>/dev/null || true
    rm -f "$tmp"
    return 0
  fi

  cat "$tmp" >>"$LOG_FILE" 2>/dev/null || true
  # `gh api` normally emits a concise `gh: ... (HTTP NNN)` line. Surface only
  # one short diagnostic line; PATs are never part of gh's normal error text.
  detail=$(grep -E '(^gh:|HTTP [0-9]{3}|^[[:space:]]*message:)' "$tmp" 2>/dev/null | tail -n 1 | sed -E 's/^gh:[[:space:]]*//' || true)
  [ -n "$detail" ] || detail=$(tail -n 1 "$tmp" 2>/dev/null || true)
  rm -f "$tmp"
  if [ -n "$detail" ]; then
    detail=$(printf '%s' "$detail" | cut -c1-240)
    repo_die "${desc}；GitHub 返回：${detail}"
  fi
  repo_die "$desc"
}

validate_or_record_source_identity() {
  local source_json="$STATE_DIR/source-repository.json" current expected
  critical_src_json "repos/$SRC_REPO" "$source_json" '仓库信息'
  [ "$(jq -r '.private' "$source_json")" = 'true' ] || repo_die '源仓库不是 Private；本工具当前只处理私有仓库'
  current=$(jq -r '.id' "$source_json")
  if [ -f "$STATE_DIR/source-repository-id" ]; then
    expected=$(cat "$STATE_DIR/source-repository-id")
    [ "$current" = "$expected" ] || repo_die '源仓库 ID 与旧迁移记录不一致，可能是同名仓库被删除后重建'
  else
    printf '%s\n' "$current" >"$STATE_DIR/source-repository-id"
  fi
}

create_or_validate_destination() {
  local current expected created_json="$STATE_DIR/destination-repository.json" errf
  errf="$STATE_DIR/.destination-check.err"

  if current=$(dst_api "repos/$DST_REPO" --jq .id 2>"$errf"); then
    rm -f "$errf"
    [ -f "$STATE_DIR/destination-repository-id" ] || repo_die '目标仓库已经存在，但不是本工具记录的迁移目标；为避免覆盖已停止'
    expected=$(cat "$STATE_DIR/destination-repository-id")
    [ "$current" = "$expected" ] || repo_die '目标仓库 ID 与迁移记录不一致；为避免操作错误仓库已停止'
    TARGET_READY=1
    return 0
  fi

  if ! grep -q 'HTTP 404' "$errf" 2>/dev/null; then
    cat "$errf" >>"$LOG_FILE" 2>/dev/null || true
    rm -f "$errf"
    repo_die '无法确认目标仓库是否存在；不会把 API/网络错误当成“仓库不存在”'
  fi
  rm -f "$errf"

  [ ! -f "$STATE_DIR/destination-repository-id" ] || repo_die '迁移记录显示目标仓库曾存在，但当前已不存在；请回到向导选择重新开始'

  if ! dst_api -X POST user/repos -f name="$DST_NAME" -F private=true -F auto_init=false >"$created_json" 2>>"$LOG_FILE"; then
    repo_die '创建目标 Private 仓库失败'
  fi
  jq -r '.id' "$created_json" >"$STATE_DIR/destination-repository-id"
  TARGET_READY=1

  # A newly created destination must never inherit completion/progress markers
  # from a stale local directory that happened to lack its identity file.
  rm -f "$STATE_DIR/INITIAL_MIGRATE_DONE" "$STATE_DIR/FINAL_SYNC_DONE" \
        "$STATE_DIR/REVIEW_ACCEPTED" "$STATE_DIR/MIGRATION_COMPLETE_V5" "$STATE_DIR/MIGRATION_COMPLETE_V51" \
        "$STATE_DIR/MIGRATION_COMPLETE_V52" "$STATE_DIR/MIGRATION_COMPLETE_V53" "$STATE_DIR/STATE_FORMAT_VERSION"
  repo_log "Created destination repository id=$(cat "$STATE_DIR/destination-repository-id")"
}

disable_destination_actions() {
  printf '{"enabled":false}\n' >"$STATE_DIR/actions-disabled.json"
  run_logged '无法关闭目标仓库 Actions' \
    dst_api -X PUT "repos/$DST_REPO/actions/permissions" --input "$STATE_DIR/actions-disabled.json"
}

copy_git_and_lfs() {
  local label="$1" src_url dst_url
  src_url="https://github.com/$SRC_REPO.git"
  dst_url="https://github.com/$DST_REPO.git"

  make_askpass
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gh-repo-migrate.XXXXXX") || repo_die '无法创建临时工作目录'

  repo_log "$label: git clone --bare"
  (
    cd "$WORK_DIR"
    git_with_token "$SRC_TOKEN" git clone --bare "$src_url" repo.git
  ) >>"$LOG_FILE" 2>&1 || repo_die '从源仓库复制 Git 历史失败'

  (
    cd "$WORK_DIR/repo.git"
    git for-each-ref --format='delete %(refname)' refs/pull | git update-ref --stdin || true
  ) >>"$LOG_FILE" 2>&1

  repo_log "$label: git lfs fetch --all"
  (
    cd "$WORK_DIR/repo.git"
    git_with_token "$SRC_TOKEN" git lfs fetch --all
  ) >>"$LOG_FILE" 2>&1 || repo_die '读取源仓库 Git LFS 对象失败'

  repo_log "$label: git push --mirror"
  (
    cd "$WORK_DIR/repo.git"
    git_with_token "$DST_TOKEN" git push --mirror "$dst_url"
  ) >>"$LOG_FILE" 2>&1 || repo_die '向目标仓库写入 Git 历史失败'

  repo_log "$label: git lfs push --all"
  (
    cd "$WORK_DIR/repo.git"
    git_with_token "$DST_TOKEN" git lfs push --all "$dst_url"
  ) >>"$LOG_FILE" 2>&1 || repo_die '向目标仓库写入 Git LFS 对象失败'

  rm -rf "$WORK_DIR"; WORK_DIR=''
  rm -f "$ASKPASS_FILE"; ASKPASS_FILE=''
}

verify_git_refs() {
  local src_url dst_url
  src_url="https://github.com/$SRC_REPO.git"
  dst_url="https://github.com/$DST_REPO.git"
  make_askpass
  git_with_token "$SRC_TOKEN" git ls-remote --heads --tags "$src_url" | LC_ALL=C sort >"$STATE_DIR/verify-source-refs.txt" 2>>"$LOG_FILE" || repo_die '读取源仓库分支/标签失败'
  git_with_token "$DST_TOKEN" git ls-remote --heads --tags "$dst_url" | LC_ALL=C sort >"$STATE_DIR/verify-destination-refs.txt" 2>>"$LOG_FILE" || repo_die '读取目标仓库分支/标签失败'
  if ! diff -u "$STATE_DIR/verify-source-refs.txt" "$STATE_DIR/verify-destination-refs.txt" >"$STATE_DIR/verify-refs.diff"; then
    repo_die '源、目标分支/标签不一致；已停止恢复 Actions'
  fi
  rm -f "$STATE_DIR/verify-refs.diff" "$ASKPASS_FILE"
  ASKPASS_FILE=''
}

snapshot_actions_policy() {
  critical_src_json "repos/$SRC_REPO/actions/permissions" "$STATE_DIR/actions-permissions.json" 'Actions 开关/允许策略'
  critical_src_json "repos/$SRC_REPO/actions/permissions/workflow" "$STATE_DIR/actions-workflow-permissions.json" 'GITHUB_TOKEN 默认权限'
  critical_src_json "repos/$SRC_REPO/actions/permissions/access" "$STATE_DIR/actions-access.json" 'reusable workflow 访问级别'

  rm -f "$STATE_DIR/actions-selected-actions.json"
  if [ "$(jq -r '.allowed_actions // ""' "$STATE_DIR/actions-permissions.json")" = 'selected' ]; then
    critical_src_json "repos/$SRC_REPO/actions/permissions/selected-actions" "$STATE_DIR/actions-selected-actions.json" 'Actions allowlist'
  fi
}

copy_repository_metadata() {
  local patch="$STATE_DIR/repository-patch.json"
  local dstrepo="$STATE_DIR/destination-repository-after-metadata.json"
  local diffs status detail errf

  rm -f "$STATE_DIR/review-metadata-warning" "$STATE_DIR/review-metadata-warning.json" \
        "$STATE_DIR/review-topics-warning" "$STATE_DIR/review-topics-warning.json"

  jq '{
      description, homepage, has_issues, has_projects, has_discussions,
      allow_squash_merge, allow_merge_commit, allow_rebase_merge, allow_auto_merge,
      allow_update_branch, delete_branch_on_merge,
      squash_merge_commit_title, squash_merge_commit_message,
      merge_commit_title, merge_commit_message,
      web_commit_signoff_required, default_branch
    } | with_entries(select(.value != null))' \
    "$STATE_DIR/source-repository.json" >"$patch"

  # Mutation failure is not itself reported to the user: verify actual drift
  # afterwards, so a harmless/partial API quirk does not become a false alarm.
  if ! dst_api -X PATCH "repos/$DST_REPO" --input "$patch" >>"$LOG_FILE" 2>&1; then
    repo_log 'Repository metadata PATCH returned non-zero; verifying actual destination drift before reporting.'
  fi

  errf="$STATE_DIR/.metadata-verify.err"
  if ! dst_api "repos/$DST_REPO" >"$dstrepo" 2>"$errf"; then
    status=$(http_status_from_error_file "$errf")
    detail=$(short_error_from_file "$errf")
    cat "$errf" >>"$LOG_FILE" 2>/dev/null || true
    rm -f "$errf"
    repo_die "无法验证目标仓库基础设置${status:+（HTTP ${status}）}${detail:+：${detail}}"
  fi
  rm -f "$errf"

  # The default branch is a core repository invariant, not an optional drift.
  # If the broad metadata PATCH was rejected because of some secondary field,
  # retry this core setting independently before failing the migration.
  local src_default dst_default
  src_default=$(jq -r '.default_branch // ""' "$STATE_DIR/source-repository.json")
  dst_default=$(jq -r '.default_branch // ""' "$dstrepo")
  if [ "$src_default" != "$dst_default" ]; then
    run_logged '无法单独设置目标仓库默认分支' \
      dst_api -X PATCH "repos/$DST_REPO" -f default_branch="$src_default"
    critical_dst_json "repos/$DST_REPO" "$dstrepo" '默认分支最终状态'
    dst_default=$(jq -r '.default_branch // ""' "$dstrepo")
    [ "$src_default" = "$dst_default" ] || repo_die "目标仓库默认分支未能设置为源仓库的 '${src_default}'"
  fi

  diffs=$(jq -nc \
    --slurpfile s "$STATE_DIR/source-repository.json" \
    --slurpfile d "$dstrepo" '
      ["description","homepage","has_issues","has_projects","has_discussions",
       "allow_squash_merge","allow_merge_commit","allow_rebase_merge","allow_auto_merge","allow_update_branch",
       "delete_branch_on_merge","squash_merge_commit_title","squash_merge_commit_message",
       "merge_commit_title","merge_commit_message","web_commit_signoff_required"]
      | map(select(($s[0][.] // null) != ($d[0][.] // null)))')
  if [ "$(printf '%s' "$diffs" | jq 'length')" -gt 0 ]; then
    jq -nc --argjson fields "$diffs" \
      '{label:"仓库基础设置",kind:"drift",fields:$fields}' >"$STATE_DIR/review-metadata-warning.json"
    repo_log "REVIEW drift: repository metadata fields=$(printf '%s' "$diffs" | jq -c '.')"
  fi

  # Topics: again report actual drift/uncertainty, not merely a failed PUT.
  errf="$STATE_DIR/.topics-source.err"
  if src_api "repos/$SRC_REPO/topics" >"$STATE_DIR/topics.json" 2>"$errf"; then
    rm -f "$errf"
    if ! dst_api -X PUT "repos/$DST_REPO/topics" --input "$STATE_DIR/topics.json" >>"$LOG_FILE" 2>&1; then
      repo_log 'Topics PUT returned non-zero; verifying actual destination topics before reporting.'
    fi

    errf="$STATE_DIR/.topics-destination.err"
    if dst_api "repos/$DST_REPO/topics" >"$STATE_DIR/destination-topics.json" 2>"$errf"; then
      rm -f "$errf"
      if ! jq -e -n \
        --slurpfile s "$STATE_DIR/topics.json" --slurpfile d "$STATE_DIR/destination-topics.json" \
        '((($s[0].names // [])|sort) == (($d[0].names // [])|sort))' >/dev/null; then
        jq -nc '{label:"Topics",kind:"drift"}' >"$STATE_DIR/review-topics-warning.json"
        repo_log 'REVIEW drift: Topics differ after copy attempt.'
      fi
    else
      status=$(http_status_from_error_file "$errf")
      detail=$(short_error_from_file "$errf")
      cat "$errf" >>"$LOG_FILE" 2>/dev/null || true
      rm -f "$errf"
      jq -nc --arg status "${status:-unknown}" --arg detail "$detail" \
        '{label:"Topics",kind:"unreadable",side:"destination",http_status:$status,detail:$detail}' >"$STATE_DIR/review-topics-warning.json"
    fi
  else
    status=$(http_status_from_error_file "$errf")
    detail=$(short_error_from_file "$errf")
    cat "$errf" >>"$LOG_FILE" 2>/dev/null || true
    rm -f "$errf"
    jq -nc --arg status "${status:-unknown}" --arg detail "$detail" \
      '{label:"Topics",kind:"unreadable",side:"source",http_status:$status,detail:$detail}' >"$STATE_DIR/review-topics-warning.json"
  fi
}

upsert_repo_variable() {
  local name="$1" value="$2" enc errf status detail
  enc=$(printf '%s' "$name" | jq -sRr @uri)
  errf="$STATE_DIR/.repo-var-exists.err"
  if dst_api "repos/$DST_REPO/actions/variables/$enc" >/dev/null 2>"$errf"; then
    rm -f "$errf"
    dst_api -X PATCH "repos/$DST_REPO/actions/variables/$enc" -f name="$name" -f value="$value" >>"$LOG_FILE" 2>&1 || repo_die "复制 Repository Variable '$name' 失败"
    return 0
  fi

  status=$(http_status_from_error_file "$errf")
  if [ "$status" != '404' ]; then
    detail=$(short_error_from_file "$errf")
    cat "$errf" >>"$LOG_FILE" 2>/dev/null || true
    rm -f "$errf"
    repo_die "无法确认 Repository Variable '${name}' 是否已存在${status:+（HTTP ${status}）}${detail:+：${detail}}"
  fi
  cat "$errf" >>"$LOG_FILE" 2>/dev/null || true
  rm -f "$errf"
  dst_api -X POST "repos/$DST_REPO/actions/variables" -f name="$name" -f value="$value" >>"$LOG_FILE" 2>&1 || repo_die "创建 Repository Variable '$name' 失败"
}

upsert_env_variable() {
  local env="$1" name="$2" value="$3" e n errf status detail
  e=$(printf '%s' "$env" | jq -sRr @uri)
  n=$(printf '%s' "$name" | jq -sRr @uri)
  errf="$STATE_DIR/.env-var-exists.err"
  if dst_api "repos/$DST_REPO/environments/$e/variables/$n" >/dev/null 2>"$errf"; then
    rm -f "$errf"
    dst_api -X PATCH "repos/$DST_REPO/environments/$e/variables/$n" -f name="$name" -f value="$value" >>"$LOG_FILE" 2>&1 || repo_die "复制 Environment Variable '$env/$name' 失败"
    return 0
  fi

  status=$(http_status_from_error_file "$errf")
  if [ "$status" != '404' ]; then
    detail=$(short_error_from_file "$errf")
    cat "$errf" >>"$LOG_FILE" 2>/dev/null || true
    rm -f "$errf"
    repo_die "无法确认 Environment Variable '${env}/${name}' 是否已存在${status:+（HTTP ${status}）}${detail:+：${detail}}"
  fi
  cat "$errf" >>"$LOG_FILE" 2>/dev/null || true
  rm -f "$errf"
  dst_api -X POST "repos/$DST_REPO/environments/$e/variables" -f name="$name" -f value="$value" >>"$LOG_FILE" 2>&1 || repo_die "创建 Environment Variable '$env/$name' 失败"
}

ensure_destination_environment_exists() {
  # IMPORTANT: never PUT an already-existing environment. PUT is an update API
  # for protection rules; repeating an empty PUT after manual repair could drift
  # those rules. Only a confirmed HTTP 404 is treated as "missing".
  local env="$1" e errf
  e=$(printf '%s' "$env" | jq -sRr @uri)
  errf="$STATE_DIR/.environment-exists.err"
  if dst_api "repos/$DST_REPO/environments/$e" >/dev/null 2>"$errf"; then
    rm -f "$errf"
    return 0
  fi
  if ! grep -q 'HTTP 404' "$errf" 2>/dev/null; then
    cat "$errf" >>"$LOG_FILE" 2>/dev/null || true
    rm -f "$errf"
    repo_die "无法确认目标 Environment '$env' 是否存在；不会把 API/网络错误当成“不存在”"
  fi
  cat "$errf" >>"$LOG_FILE" 2>/dev/null || true
  rm -f "$errf"
  dst_api -X PUT "repos/$DST_REPO/environments/$e" >>"$LOG_FILE" 2>&1 || repo_die "创建 Environment '$env' 失败"
}

list_source_environments() {
  # GitHub docs currently restrict Environments in private repositories to
  # eligible paid plans. For a validated owner token, HTTP 404 on this specific
  # endpoint is treated as "feature unavailable" rather than "zero by accident".
  # Other errors (403/rate limit/network/etc.) remain blocking.
  local out="$STATE_DIR/environments.json" tmp="$STATE_DIR/environments.json.stream" err="$STATE_DIR/environments.json.err"
  : >"$tmp"
  rm -f "$STATE_DIR/ENVIRONMENTS_FEATURE_UNAVAILABLE"
  if src_api --paginate "repos/$SRC_REPO/environments?per_page=100" --jq '.environments[]' >"$tmp" 2>"$err"; then
    rm -f "$err"
    if [ -s "$tmp" ]; then jq -s '.' "$tmp" >"$out"; else printf '[]\n' >"$out"; fi
    rm -f "$tmp"
    return 0
  fi
  if grep -q 'HTTP 404' "$err" 2>/dev/null && source_is_private_personal_repo; then
    cat "$err" >>"$LOG_FILE" 2>/dev/null || true
    printf '[]\n' >"$out"
    printf 'feature unavailable in this private personal repository context (HTTP 404)\n' >"$STATE_DIR/ENVIRONMENTS_FEATURE_UNAVAILABLE"
    rm -f "$tmp" "$err"
    repo_log 'Environments endpoint returned 404 for a private personal repository; treated as feature unavailable and suppressed from user report.'
    return 0
  fi
  cat "$err" >>"$LOG_FILE" 2>/dev/null || true
  rm -f "$tmp" "$err"
  repo_die '无法读取源仓库的 Environments；不能把读取失败当成“没有 Environment”'
}

snapshot_and_copy_core_state() {
  local erow env e envvars envsecrets vrow name value sname

  critical_src_json "repos/$SRC_REPO" "$STATE_DIR/source-repository.json" '仓库信息'
  snapshot_actions_policy
  copy_repository_metadata

  critical_paginate src "repos/$SRC_REPO/actions/variables?per_page=100" '.variables[]' "$STATE_DIR/repo-variables.json" 'Repository Variables'
  while IFS= read -r vrow; do
    [ -n "$vrow" ] || continue
    name=$(printf '%s' "$vrow" | jq -r '.name')
    value=$(printf '%s' "$vrow" | jq -r '.value')
    upsert_repo_variable "$name" "$value"
  done < <(jq -c '.[]' "$STATE_DIR/repo-variables.json")

  critical_paginate src "repos/$SRC_REPO/actions/secrets?per_page=100" '.secrets[]' "$STATE_DIR/repo-secrets.json" 'Actions Repository Secrets 名称'
  critical_paginate src "repos/$SRC_REPO/dependabot/secrets?per_page=100" '.secrets[]' "$STATE_DIR/dependabot-secrets.json" 'Dependabot Secrets 名称'
  list_source_environments

  : >"$STATE_DIR/environment-secret-requirements.jsonl"
  : >"$STATE_DIR/environment-protection-review.txt"

  while IFS= read -r erow; do
    [ -n "$erow" ] || continue
    env=$(printf '%s' "$erow" | jq -r '.name')
    e=$(printf '%s' "$env" | jq -sRr @uri)
    ensure_destination_environment_exists "$env"

    if printf '%s' "$erow" | jq -e '((.protection_rules // []) | length > 0) or (.deployment_branch_policy != null)' >/dev/null; then
      printf '%s\n' "$env" >>"$STATE_DIR/environment-protection-review.txt"
    fi

    envvars="$STATE_DIR/.envvars-$(printf '%s' "$env" | shasum | awk '{print $1}').json"
    critical_paginate src "repos/$SRC_REPO/environments/$e/variables?per_page=100" '.variables[]' "$envvars" "Environment '$env' Variables"
    while IFS= read -r vrow; do
      [ -n "$vrow" ] || continue
      name=$(printf '%s' "$vrow" | jq -r '.name')
      value=$(printf '%s' "$vrow" | jq -r '.value')
      upsert_env_variable "$env" "$name" "$value"
    done < <(jq -c '.[]' "$envvars")
    rm -f "$envvars"

    envsecrets="$STATE_DIR/.envsecrets-$(printf '%s' "$env" | shasum | awk '{print $1}').json"
    critical_paginate src "repos/$SRC_REPO/environments/$e/secrets?per_page=100" '.secrets[]' "$envsecrets" "Environment '$env' Secrets 名称"
    while IFS= read -r sname; do
      [ -n "$sname" ] || continue
      jq -nc --arg environment "$env" --arg secret "$sname" '{environment:$environment,secret:$secret}' >>"$STATE_DIR/environment-secret-requirements.jsonl"
    done < <(jq -r '.[].name' "$envsecrets")
    rm -f "$envsecrets"
  done < <(jq -c '.[]' "$STATE_DIR/environments.json")

  if [ -s "$STATE_DIR/environment-secret-requirements.jsonl" ]; then
    jq -s '.' "$STATE_DIR/environment-secret-requirements.jsonl" >"$STATE_DIR/environment-secrets.json"
  else
    printf '[]\n' >"$STATE_DIR/environment-secrets.json"
  fi
  rm -f "$STATE_DIR/environment-secret-requirements.jsonl"

  export_review_only_state
}

detect_source_wiki_state() {
  local wiki_url tmp err status detail
  rm -f "$STATE_DIR/WIKI_CONTENT_PRESENT" "$STATE_DIR/wiki-unreadable.json"

  # has_wiki can be true even when a private-repo plan does not expose the Wiki
  # feature, so only report Wiki when the actual .wiki.git repository has refs.
  [ "$(jq -r '.has_wiki // false' "$STATE_DIR/source-repository.json")" = 'true' ] || return 0

  wiki_url="https://github.com/${SRC_REPO}.wiki.git"
  tmp="$STATE_DIR/.wiki-refs.tmp"
  err="$STATE_DIR/.wiki-refs.err"
  make_askpass
  if git_with_token "$SRC_TOKEN" git ls-remote "$wiki_url" >"$tmp" 2>"$err"; then
    if [ -s "$tmp" ]; then
      printf 'wiki refs exist\n' >"$STATE_DIR/WIKI_CONTENT_PRESENT"
      repo_log 'REVIEW asset: source Wiki content exists and is not migrated.'
    fi
    rm -f "$tmp" "$err" "$ASKPASS_FILE"
    ASKPASS_FILE=''
    return 0
  fi

  # A not-initialized or plan-unavailable Wiki returns Repository not found.
  # There is no accessible Wiki content to migrate, so this is not actionable.
  if grep -qi 'Repository not found' "$err" 2>/dev/null; then
    cat "$err" >>"$LOG_FILE" 2>/dev/null || true
    rm -f "$tmp" "$err" "$ASKPASS_FILE"
    ASKPASS_FILE=''
    repo_log 'REVIEW Wiki: no accessible .wiki.git repository; suppressed from user report.'
    return 0
  fi

  status=$(http_status_from_error_file "$err")
  detail=$(short_error_from_file "$err")
  cat "$err" >>"$LOG_FILE" 2>/dev/null || true
  jq -nc --arg status "${status:-unknown}" --arg detail "$detail" \
    '{label:"Wiki",kind:"unreadable",http_status:$status,detail:$detail}' >"$STATE_DIR/wiki-unreadable.json"
  rm -f "$tmp" "$err" "$ASKPASS_FILE"
  ASKPASS_FILE=''
}

export_review_only_state() {
  local branch enc tmp err status detail
  review_paginate "repos/$SRC_REPO/rulesets?per_page=100" '.[]' "$STATE_DIR/rulesets-summary.json" 'Rulesets' 'rulesets'
  review_paginate "repos/$SRC_REPO/branches?per_page=100" '.[]' "$STATE_DIR/branches.json" '分支列表' 'branches'
  review_paginate "repos/$SRC_REPO/collaborators?affiliation=all&per_page=100" '.[]' "$STATE_DIR/collaborators.json" '协作者' 'collaborators'
  review_paginate "repos/$SRC_REPO/hooks?per_page=100" '.[]' "$STATE_DIR/webhooks.json" 'Webhooks' 'webhooks'
  review_paginate "repos/$SRC_REPO/keys?per_page=100" '.[]' "$STATE_DIR/deploy-keys.json" 'Deploy keys' 'deploy-keys'
  review_paginate "repos/$SRC_REPO/releases?per_page=100" '.[]' "$STATE_DIR/releases.json" 'Releases' 'releases'

  printf '[]\n' >"$STATE_DIR/branch-protections.json"
  rm -f "$STATE_DIR/branch-protections.jsonl" "$STATE_DIR/branch-protections-unreadable.jsonl" \
        "$STATE_DIR/branch-protections-unreadable.json"
  if [ ! -f "$STATE_DIR/branches.json.unreadable" ]; then
    while IFS= read -r branch; do
      [ -n "$branch" ] || continue
      enc=$(printf '%s' "$branch" | jq -sRr @uri)
      tmp="$STATE_DIR/.bp.tmp"
      err="$STATE_DIR/.bp.err"
      if src_api "repos/$SRC_REPO/branches/$enc/protection" >"$tmp" 2>"$err"; then
        jq --arg branch "$branch" '. + {branch_name:$branch}' "$tmp" >>"$STATE_DIR/branch-protections.jsonl"
      else
        status=$(http_status_from_error_file "$err")
        detail=$(short_error_from_file "$err")
        cat "$err" >>"$LOG_FILE" 2>/dev/null || true
        jq -nc --arg branch "$branch" --arg status "${status:-unknown}" --arg detail "$detail" \
          '{branch:$branch,http_status:$status,detail:$detail}' >>"$STATE_DIR/branch-protections-unreadable.jsonl"
        repo_log "REVIEW-ONLY unreadable: branch protection '${branch}' HTTP ${status:-unknown}"
      fi
      rm -f "$tmp" "$err"
    done < <(jq -r '.[] | select(.protected == true) | .name' "$STATE_DIR/branches.json")
  fi
  if [ -s "$STATE_DIR/branch-protections.jsonl" ]; then
    jq -s '.' "$STATE_DIR/branch-protections.jsonl" >"$STATE_DIR/branch-protections.json"
    rm -f "$STATE_DIR/branch-protections.jsonl"
  fi
  if [ -s "$STATE_DIR/branch-protections-unreadable.jsonl" ]; then
    jq -s '.' "$STATE_DIR/branch-protections-unreadable.jsonl" >"$STATE_DIR/branch-protections-unreadable.json"
    rm -f "$STATE_DIR/branch-protections-unreadable.jsonl"
  fi

  detect_source_wiki_state
}

json_len() {
  local f="$1"
  [ -f "$f" ] || { printf '0'; return; }
  jq 'length' "$f" 2>/dev/null || printf '0'
}

check_secret_names() {
  local missing=0 out row env sec e s hash
  rm -f "$STATE_DIR/.missing-repo-secrets" "$STATE_DIR/.missing-dependabot-secrets" "$STATE_DIR/.missing-env-secrets.jsonl"

  out="$STATE_DIR/.dst-repo-secrets.json"
  critical_paginate dst "repos/$DST_REPO/actions/secrets?per_page=100" '.secrets[]' "$out" 'Actions Repository Secrets 名称'
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    jq -e --arg n "$s" '.[] | select(.name == $n)' "$out" >/dev/null || printf '%s\n' "$s" >>"$STATE_DIR/.missing-repo-secrets"
  done < <(jq -r '.[].name' "$STATE_DIR/repo-secrets.json")
  rm -f "$out"
  [ ! -s "$STATE_DIR/.missing-repo-secrets" ] || missing=1

  out="$STATE_DIR/.dst-dependabot-secrets.json"
  critical_paginate dst "repos/$DST_REPO/dependabot/secrets?per_page=100" '.secrets[]' "$out" 'Dependabot Secrets 名称'
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    jq -e --arg n "$s" '.[] | select(.name == $n)' "$out" >/dev/null || printf '%s\n' "$s" >>"$STATE_DIR/.missing-dependabot-secrets"
  done < <(jq -r '.[].name' "$STATE_DIR/dependabot-secrets.json")
  rm -f "$out"
  [ ! -s "$STATE_DIR/.missing-dependabot-secrets" ] || missing=1

  while IFS= read -r env; do
    [ -n "$env" ] || continue
    e=$(printf '%s' "$env" | jq -sRr @uri)
    hash=$(printf '%s' "$env" | shasum | awk '{print $1}')
    out="$STATE_DIR/.dst-env-secrets-$hash.json"
    critical_paginate dst "repos/$DST_REPO/environments/$e/secrets?per_page=100" '.secrets[]' "$out" "Environment '$env' Secrets 名称"
  done < <(jq -r '.[].environment' "$STATE_DIR/environment-secrets.json" | LC_ALL=C sort -u)

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    env=$(printf '%s' "$row" | jq -r '.environment')
    sec=$(printf '%s' "$row" | jq -r '.secret')
    hash=$(printf '%s' "$env" | shasum | awk '{print $1}')
    out="$STATE_DIR/.dst-env-secrets-$hash.json"
    jq -e --arg n "$sec" '.[] | select(.name == $n)' "$out" >/dev/null || \
      jq -nc --arg environment "$env" --arg secret "$sec" '{environment:$environment,secret:$secret}' >>"$STATE_DIR/.missing-env-secrets.jsonl"
  done < <(jq -c '.[]' "$STATE_DIR/environment-secrets.json")
  rm -f "$STATE_DIR"/.dst-env-secrets-*.json 2>/dev/null || true
  [ ! -s "$STATE_DIR/.missing-env-secrets.jsonl" ] || missing=1

  return "$missing"
}

secret_missing_count() {
  local n=0 c
  for f in "$STATE_DIR/.missing-repo-secrets" "$STATE_DIR/.missing-dependabot-secrets" "$STATE_DIR/.missing-env-secrets.jsonl"; do
    if [ -s "$f" ]; then
      c=$(wc -l <"$f" | tr -d ' ')
      n=$((n + c))
    fi
  done
  printf '%s' "$n"
}

set_secret_cn() {
  local type="$1" name="$2" env="${3:-}" value
  case "$type" in
    actions) printf '  %s：' "$name" >&4 ;;
    environment) printf '  %s / %s：' "$env" "$name" >&4 ;;
    dependabot) printf '  Dependabot / %s：' "$name" >&4 ;;
  esac
  IFS= read -r -s value <&3 || value=''
  printf '\n' >&4
  [ -n "$value" ] || return 0
  case "$type" in
    actions)
      printf '%s' "$value" | GH_TOKEN="$DST_TOKEN" GH_PROMPT_DISABLED=1 gh secret set "$name" -R "$DST_REPO" >>"$LOG_FILE" 2>&1 || repo_die "写入 Secret '$name' 失败"
      ;;
    environment)
      printf '%s' "$value" | GH_TOKEN="$DST_TOKEN" GH_PROMPT_DISABLED=1 gh secret set "$name" -R "$DST_REPO" --env "$env" >>"$LOG_FILE" 2>&1 || repo_die "写入 Environment Secret '$env/$name' 失败"
      ;;
    dependabot)
      printf '%s' "$value" | GH_TOKEN="$DST_TOKEN" GH_PROMPT_DISABLED=1 gh secret set "$name" -R "$DST_REPO" --app dependabot >>"$LOG_FILE" 2>&1 || repo_die "写入 Dependabot Secret '$name' 失败"
      ;;
  esac
  value=''
}

handle_missing_secrets_cn() {
  local missing s row env sec
  if check_secret_names; then
    return 0
  fi
  missing=$(secret_missing_count)
  ui_blank
  ui "🔐 发现 $missing 个 Secret 需要在目标仓库重新填写。GitHub 不允许读取源 Secret 的值。"
  if ! confirm '现在逐个填写吗？' 1; then
    ui '⏸ 当前仓库尚未完成；目标 Actions 仍保持关闭。'
    ui '源仓库请继续保持不再修改，之后重新运行本工具即可继续。'
    [ -z "${RUN_RESULT_FILE:-}" ] || printf 'pause\n' >"$RUN_RESULT_FILE" 2>/dev/null || true
    exit 20
  fi
  ui '请输入 Secret 值（输入隐藏；直接回车表示暂时跳过）：'

  if [ -s "$STATE_DIR/.missing-repo-secrets" ]; then
    while IFS= read -r s; do [ -n "$s" ] && set_secret_cn actions "$s"; done <"$STATE_DIR/.missing-repo-secrets"
  fi
  if [ -s "$STATE_DIR/.missing-env-secrets.jsonl" ]; then
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      env=$(printf '%s' "$row" | jq -r '.environment')
      sec=$(printf '%s' "$row" | jq -r '.secret')
      set_secret_cn environment "$sec" "$env"
    done <"$STATE_DIR/.missing-env-secrets.jsonl"
  fi
  if [ -s "$STATE_DIR/.missing-dependabot-secrets" ]; then
    while IFS= read -r s; do [ -n "$s" ] && set_secret_cn dependabot "$s"; done <"$STATE_DIR/.missing-dependabot-secrets"
  fi

  if ! check_secret_names; then
    missing=$(secret_missing_count)
    ui_blank
    ui "⏸ 还有 $missing 个 Secret 未填写，当前仓库尚未完成。"
    ui '目标 Actions 仍保持关闭；源仓库请继续保持不再修改。'
    [ -z "${RUN_RESULT_FILE:-}" ] || printf 'pause\n' >"$RUN_RESULT_FILE" 2>/dev/null || true
    exit 20
  fi
}

review_non_migrated_state_cn() {
  local envc bpc rsc collc hookc keyc relc wiki_present pages_enabled
  local known_count=0 unknown_count=0 known_lines='' unknown_lines=''
  local f label status detail reason meta_kind meta_fields topic_kind bpuc bp_examples

  if [ -f "$STATE_DIR/environment-protection-review.txt" ]; then
    envc=$(grep -c '.' "$STATE_DIR/environment-protection-review.txt" 2>/dev/null || true)
    [ -n "$envc" ] || envc=0
  else
    envc=0
  fi
  if [ -f "$STATE_DIR/branches.json.unreadable" ]; then
    bpc=0
  else
    bpc=$(jq '[.[] | select(.protected == true)] | length' "$STATE_DIR/branches.json" 2>/dev/null || printf '0')
  fi
  rsc=$(json_len "$STATE_DIR/rulesets-summary.json")
  collc=$(jq --arg owner "$(printf '%s' "$SRC_OWNER" | tr '[:upper:]' '[:lower:]')" \
    '[.[] | select(((.login // "") | ascii_downcase) != $owner)] | length' \
    "$STATE_DIR/collaborators.json" 2>/dev/null || printf '0')
  hookc=$(json_len "$STATE_DIR/webhooks.json")
  keyc=$(json_len "$STATE_DIR/deploy-keys.json")
  relc=$(json_len "$STATE_DIR/releases.json")
  wiki_present=0; [ -f "$STATE_DIR/WIKI_CONTENT_PRESENT" ] && wiki_present=1
  pages_enabled=$(jq -r '.has_pages // false' "$STATE_DIR/source-repository.json" 2>/dev/null || printf 'false')

  add_known() { known_count=$((known_count + 1)); known_lines="${known_lines}  - $1\n"; }
  add_unknown() { unknown_count=$((unknown_count + 1)); unknown_lines="${unknown_lines}  - $1\n"; }

  [ "$envc" -eq 0 ] || add_known "Environment 保护配置 ${envc} 个：不会自动复制；请按需核对部署分支/审批等设置。"
  [ "$bpc" -eq 0 ] || add_known "分支保护 ${bpc} 个：不会自动复制；目标仓库的 push/merge 约束可能不同。"
  [ "$rsc" -eq 0 ] || add_known "Ruleset ${rsc} 个：不会自动复制；目标仓库的分支、Tag 或 Push 规则可能不同。"
  [ "$collc" -eq 0 ] || add_known "协作者 ${collc} 个：不会自动邀请到目标仓库。"
  [ "$hookc" -eq 0 ] || add_known "Webhook ${hookc} 个：不会自动复制；Webhook Secret 无法从 GitHub 读回。"
  [ "$keyc" -eq 0 ] || add_known "Deploy key ${keyc} 个：不会自动复制，需要时请在目标仓库重新配置。"
  [ "$relc" -eq 0 ] || add_known "Release ${relc} 个：Git Tag 已迁移，但 Release 页面和附件不会自动重建。"
  [ "$wiki_present" -eq 0 ] || add_known 'Wiki：检测到实际 Wiki 内容；本工具不会复制 Wiki 页面/history。'
  [ "$pages_enabled" != 'true' ] || add_known 'GitHub Pages：源仓库已启用；Pages 的发布/域名等配置不会自动迁移。'

  # Exact review-only API uncertainties. Plan-limited/not-applicable feature
  # markers are deliberately absent here and therefore do not bother the user.
  for f in "$STATE_DIR"/*.unreadable; do
    [ -e "$f" ] || continue
    label=$(jq -r '.label // "未知配置"' "$f" 2>/dev/null || printf '未知配置')
    status=$(jq -r '.http_status // "unknown"' "$f" 2>/dev/null || printf 'unknown')
    detail=$(jq -r '.detail // ""' "$f" 2>/dev/null || true)
    if [ "$status" = 'unknown' ]; then
      add_unknown "${label}：GitHub API 读取失败，无法确认是否存在。${detail:+（${detail}）}"
    else
      reason=$(http_reason_cn "$status")
      add_unknown "${label}：无法读取（HTTP ${status}，${reason}），因此无法确认是否存在。"
    fi
  done

  if [ -f "$STATE_DIR/branch-protections-unreadable.json" ]; then
    bpuc=$(jq 'length' "$STATE_DIR/branch-protections-unreadable.json" 2>/dev/null || printf '0')
    if [ "$bpuc" -gt 0 ]; then
      bp_examples=$(jq -r '.[0:3] | map(.branch + "(HTTP " + (.http_status // "unknown") + ")") | join("、")' \
        "$STATE_DIR/branch-protections-unreadable.json" 2>/dev/null || true)
      add_unknown "有 ${bpuc} 个受保护分支的保护详情无法读取${bp_examples:+：${bp_examples}}。"
    fi
  fi

  if [ -f "$STATE_DIR/review-metadata-warning.json" ]; then
    meta_kind=$(jq -r '.kind // "unreadable"' "$STATE_DIR/review-metadata-warning.json" 2>/dev/null || printf 'unreadable')
    if [ "$meta_kind" = 'drift' ]; then
      meta_fields=$(jq -r '
        def cn: {description:"描述",homepage:"Homepage",has_issues:"Issues 开关",has_projects:"Projects 开关",
                 has_discussions:"Discussions 开关",allow_squash_merge:"Squash merge",allow_merge_commit:"Merge commit",
                 allow_rebase_merge:"Rebase merge",allow_auto_merge:"Auto-merge",allow_update_branch:"更新落后分支",
                 delete_branch_on_merge:"合并后删除分支",squash_merge_commit_title:"Squash 标题规则",
                 squash_merge_commit_message:"Squash 消息规则",merge_commit_title:"Merge 标题规则",
                 merge_commit_message:"Merge 消息规则",web_commit_signoff_required:"Web Commit Sign-off"};
        [.fields[] | (cn[.] // .)] | join("、")' "$STATE_DIR/review-metadata-warning.json" 2>/dev/null || true)
      add_known "仓库基础设置复制后仍有差异${meta_fields:+：${meta_fields}}。"
    else
      status=$(jq -r '.http_status // "unknown"' "$STATE_DIR/review-metadata-warning.json" 2>/dev/null || printf 'unknown')
      reason=$(http_reason_cn "$status")
      add_unknown "仓库基础设置：无法读取目标状态进行确认（HTTP ${status}，${reason}）。"
    fi
  fi

  if [ -f "$STATE_DIR/review-topics-warning.json" ]; then
    topic_kind=$(jq -r '.kind // "unreadable"' "$STATE_DIR/review-topics-warning.json" 2>/dev/null || printf 'unreadable')
    if [ "$topic_kind" = 'drift' ]; then
      add_known 'Topics：复制后仍与源仓库不一致。'
    else
      status=$(jq -r '.http_status // "unknown"' "$STATE_DIR/review-topics-warning.json" 2>/dev/null || printf 'unknown')
      label=$(jq -r '.side // "unknown"' "$STATE_DIR/review-topics-warning.json" 2>/dev/null || printf 'unknown')
      case "$label" in source) label='源仓库' ;; destination) label='目标仓库' ;; *) label='仓库' ;; esac
      reason=$(http_reason_cn "$status")
      add_unknown "Topics：无法读取${label}状态进行确认（HTTP ${status}，${reason}）。"
    fi
  fi

  if [ -f "$STATE_DIR/wiki-unreadable.json" ]; then
    status=$(jq -r '.http_status // "unknown"' "$STATE_DIR/wiki-unreadable.json" 2>/dev/null || printf 'unknown')
    reason=$(http_reason_cn "$status")
    add_unknown "Wiki：无法确认源仓库是否存在实际 Wiki 内容（HTTP ${status}，${reason}）。"
  fi

  if [ "$known_count" -eq 0 ] && [ "$unknown_count" -eq 0 ]; then
    return 0
  fi

  ui_blank
  if [ "$known_count" -gt 0 ]; then
    ui '⚠ 以下 GitHub 平台项目已确认存在迁移差异或不会由本工具自动迁移：'
    printf '%b' "$known_lines"
  fi
  if [ "$unknown_count" -gt 0 ]; then
    [ "$known_count" -eq 0 ] || ui_blank
    ui '⚠ 以下项目无法自动确认，需要你留意：'
    printf '%b' "$unknown_lines"
  fi
  ui '代码历史、分支、标签不受以上项目影响。'
  if ! confirm '你确认已了解并接受这些差异，继续完成迁移吗？' 0; then
    ui '⏸ 当前仓库尚未完成；目标 Actions 仍保持关闭。'
    ui '请先处理上面明确列出的项目；源仓库继续保持不再修改。'
    [ -z "${RUN_RESULT_FILE:-}" ] || printf 'pause\n' >"$RUN_RESULT_FILE" 2>/dev/null || true
    exit 21
  fi
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$STATE_DIR/REVIEW_ACCEPTED"
}

restore_actions_policy() {
  local desired_enabled source_allowed srcv dstv key
  local dst_perm="$STATE_DIR/.verify-actions-permissions.json"
  local dst_workflow="$STATE_DIR/.verify-actions-workflow.json"
  local dst_access="$STATE_DIR/.verify-actions-access.json"
  local dst_selected="$STATE_DIR/.verify-actions-selected.json"

  jq -e 'has("enabled") and has("allowed_actions")' "$STATE_DIR/actions-permissions.json" >/dev/null || repo_die '源 Actions 策略快照不完整'
  desired_enabled=$(jq -r '.enabled' "$STATE_DIR/actions-permissions.json")
  source_allowed=$(jq -r '.allowed_actions' "$STATE_DIR/actions-permissions.json")

  # Safety invariant: target Actions must be disabled before restoring any
  # subordinate policy. Do NOT combine this safety operation with copying the
  # source allowed_actions/sha_pinning policy. A minimal disable request has
  # already proven portable across ordinary personal repositories and avoids
  # turning an unnecessary staging PUT into a migration blocker.
  printf '{"enabled":false}\n' >"$STATE_DIR/.actions-keep-disabled.json"
  run_logged '无法保持目标 Actions 关闭' \
    dst_api -X PUT "repos/$DST_REPO/actions/permissions" --input "$STATE_DIR/.actions-keep-disabled.json"
  critical_dst_json "repos/$DST_REPO/actions/permissions" "$dst_perm" 'Actions 关闭状态'
  [ "$(jq -r '.enabled' "$dst_perm")" = 'false' ] || repo_die '目标 Actions 未能保持关闭；不会继续恢复策略'
  rm -f "$dst_perm"

  # These settings are independent of allowed_actions and can be restored while
  # Actions is still disabled.
  jq '{default_workflow_permissions,can_approve_pull_request_reviews} | with_entries(select(.value != null))' \
    "$STATE_DIR/actions-workflow-permissions.json" >"$STATE_DIR/.actions-workflow-body.json"
  run_logged '无法恢复 GITHUB_TOKEN 默认权限' \
    dst_api -X PUT "repos/$DST_REPO/actions/permissions/workflow" --input "$STATE_DIR/.actions-workflow-body.json"

  jq '{access_level}' "$STATE_DIR/actions-access.json" >"$STATE_DIR/.actions-access-body.json"
  run_logged '无法恢复 reusable workflow 访问级别' \
    dst_api -X PUT "repos/$DST_REPO/actions/permissions/access" --input "$STATE_DIR/.actions-access-body.json"

  # The selected-actions endpoint is only usable while the repository policy is
  # `selected`. Only this less-common case needs a staging policy change while
  # disabled. Keep the staging body minimal: enabled + allowed_actions only.
  if [ "$source_allowed" = 'selected' ]; then
    printf '{"enabled":false,"allowed_actions":"selected"}\n' >"$STATE_DIR/.actions-selected-stage.json"
    run_logged '无法在关闭状态下预置 selected Actions 策略' \
      dst_api -X PUT "repos/$DST_REPO/actions/permissions" --input "$STATE_DIR/.actions-selected-stage.json"
    critical_dst_json "repos/$DST_REPO/actions/permissions" "$dst_perm" 'selected Actions 预置状态'
    [ "$(jq -r '.enabled' "$dst_perm")" = 'false' ] || repo_die '预置 selected Actions 策略时目标 Actions 意外开启'
    [ "$(jq -r '.allowed_actions' "$dst_perm")" = 'selected' ] || repo_die 'selected Actions 策略预置后校验不一致'
    rm -f "$dst_perm"

    jq '{github_owned_allowed,verified_allowed,patterns_allowed} | with_entries(select(.value != null))' \
      "$STATE_DIR/actions-selected-actions.json" >"$STATE_DIR/.actions-selected-body.json"
    run_logged '无法恢复 Actions allowlist' \
      dst_api -X PUT "repos/$DST_REPO/actions/permissions/selected-actions" --input "$STATE_DIR/.actions-selected-body.json"
  fi

  # Final top-level policy is restored exactly once, as the last mutation that
  # can enable Actions. If this succeeds but any verification below fails, the
  # repository-level error trap will disable Actions again before returning to
  # the batch UI.
  jq --argjson enabled "$desired_enabled" \
    '{enabled:$enabled,allowed_actions,sha_pinning_required} | with_entries(select(.value != null))' \
    "$STATE_DIR/actions-permissions.json" >"$STATE_DIR/.actions-final.json"
  run_logged '无法恢复目标仓库最终 Actions 开关/策略' \
    dst_api -X PUT "repos/$DST_REPO/actions/permissions" --input "$STATE_DIR/.actions-final.json"

  critical_dst_json "repos/$DST_REPO/actions/permissions" "$dst_perm" 'Actions 最终状态'
  for key in enabled allowed_actions sha_pinning_required; do
    srcv=$(jq -c --arg k "$key" 'if has($k) then .[$k] else "__MISSING__" end' "$STATE_DIR/actions-permissions.json")
    [ "$srcv" = '"__MISSING__"' ] && continue
    dstv=$(jq -c --arg k "$key" 'if has($k) then .[$k] else "__MISSING__" end' "$dst_perm")
    [ "$srcv" = "$dstv" ] || repo_die "Actions 最终配置校验不一致（${key}）"
  done

  critical_dst_json "repos/$DST_REPO/actions/permissions/workflow" "$dst_workflow" 'GITHUB_TOKEN 最终权限'
  srcv=$(jq -cS '{default_workflow_permissions,can_approve_pull_request_reviews}' "$STATE_DIR/actions-workflow-permissions.json")
  dstv=$(jq -cS '{default_workflow_permissions,can_approve_pull_request_reviews}' "$dst_workflow")
  [ "$srcv" = "$dstv" ] || repo_die 'GITHUB_TOKEN 默认权限最终校验不一致'

  critical_dst_json "repos/$DST_REPO/actions/permissions/access" "$dst_access" 'reusable workflow 最终访问级别'
  srcv=$(jq -r '.access_level' "$STATE_DIR/actions-access.json")
  dstv=$(jq -r '.access_level' "$dst_access")
  [ "$srcv" = "$dstv" ] || repo_die 'reusable workflow 访问级别最终校验不一致'

  if [ "$source_allowed" = 'selected' ]; then
    critical_dst_json "repos/$DST_REPO/actions/permissions/selected-actions" "$dst_selected" 'Actions allowlist 最终状态'
    srcv=$(jq -cS '{github_owned_allowed,verified_allowed,patterns_allowed:((.patterns_allowed // [])|sort)}' "$STATE_DIR/actions-selected-actions.json")
    dstv=$(jq -cS '{github_owned_allowed,verified_allowed,patterns_allowed:((.patterns_allowed // [])|sort)}' "$dst_selected")
    [ "$srcv" = "$dstv" ] || repo_die 'Actions allowlist 最终校验不一致'
  fi

  rm -f "$STATE_DIR"/.actions-*.json "$dst_perm" "$dst_workflow" "$dst_access" "$dst_selected"
}

perform_initial_migration_if_needed() {
  if [ -f "$STATE_DIR/INITIAL_MIGRATE_DONE" ]; then
    ui '✓ 已识别此前的初始迁移进度。'
    return 0
  fi

  CURRENT_STEP='初始复制'
  ui_step '复制代码、Git 历史和 Actions 常用配置…'
  copy_git_and_lfs 'initial'
  snapshot_and_copy_core_state
  verify_git_refs
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$STATE_DIR/INITIAL_MIGRATE_DONE"
  ui '✓ 初始迁移完成，代码已校验一致。'
}

ensure_final_snapshot() {
  local state_version=''
  [ -f "$STATE_DIR/STATE_FORMAT_VERSION" ] && state_version=$(cat "$STATE_DIR/STATE_FORMAT_VERSION" 2>/dev/null || true)

  # Never trust FINAL_SYNC_DONE created by v3/v4 because those versions could
  # treat critical read failures as empty and could re-PUT existing environments.
  if [ "$state_version" != "$STATE_FORMAT_VERSION" ]; then
    rm -f "$STATE_DIR/FINAL_SYNC_DONE" "$STATE_DIR/REVIEW_ACCEPTED"
  fi

  if [ -f "$STATE_DIR/FINAL_SYNC_DONE" ]; then
    ui_blank
    if confirm '检测到已完成过最终同步。源仓库从那以后是否一直没有任何变化（包括代码、Secrets、Variables、Environment 等）？' 1; then
      CURRENT_STEP='确认最终同步仍有效'
      verify_git_refs
      ui '✓ 最终同步仍有效，无需重复推送。'
      return 0
    fi
    rm -f "$STATE_DIR/FINAL_SYNC_DONE" "$STATE_DIR/REVIEW_ACCEPTED"
  fi

  ui_blank
  ui '接下来是最终切换。'
  ui "从现在起请不要再修改源仓库 ${SRC_REPO}（包括代码、Secrets、Variables、Environment 等）。"
  if ! confirm '你已经停止对源仓库的一切修改了吗？' 0; then
    ui '⏸ 当前仓库尚未完成；目标 Actions 仍保持关闭。'
    [ -z "${RUN_RESULT_FILE:-}" ] || printf 'pause\n' >"$RUN_RESULT_FILE" 2>/dev/null || true
    exit 22
  fi

  CURRENT_STEP='最终同步和最终配置快照'
  ui_step '执行最终同步和一致性校验…'
  copy_git_and_lfs 'final'
  snapshot_and_copy_core_state
  verify_git_refs
  printf '%s\n' "$STATE_FORMAT_VERSION" >"$STATE_DIR/STATE_FORMAT_VERSION"
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$STATE_DIR/FINAL_SYNC_DONE"
  rm -f "$STATE_DIR/REVIEW_ACCEPTED"
  ui '✓ 源、目标分支和标签已最终校验一致。'
}

finalize_repository() {
  CURRENT_STEP='最终 Secret 校验'
  ui_step '检查 Secret…'
  if check_secret_names; then
    local total
    total=$(( $(json_len "$STATE_DIR/repo-secrets.json") + $(json_len "$STATE_DIR/environment-secrets.json") + $(json_len "$STATE_DIR/dependabot-secrets.json") ))
    if [ "$total" -eq 0 ]; then ui '✓ 无需补 Secret。'; else ui '✓ Secret 已齐全。'; fi
  else
    handle_missing_secrets_cn
    ui '✓ Secret 已齐全。'
  fi

  CURRENT_STEP='确认未自动迁移的平台配置'
  if [ ! -f "$STATE_DIR/REVIEW_ACCEPTED" ]; then
    review_non_migrated_state_cn
  fi

  CURRENT_STEP='最终一致性复核'
  verify_git_refs
  check_secret_names || repo_die '最终检查发现仍有 Secret 缺失'

  CURRENT_STEP='恢复 GitHub Actions'
  ui_step '安全恢复目标仓库 Actions…'
  restore_actions_policy

  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$STATE_DIR/MIGRATION_COMPLETE_V53"
  MIGRATION_SUCCESS=1
  ui_blank
  ui "✅ 已成功迁移仓库：${SRC_REPO#*/}"
  ui "   $SRC_REPO → $DST_REPO"
  ui '   代码历史 / 分支 / 标签：已最终校验一致'
  ui '   GitHub Actions 设置：已按源仓库恢复并再次校验通过'
  ui "   详细日志：$LOG_FILE"
}

run_repo_migration_strict() {
  set -Eeuo pipefail
  trap repo_unexpected_error ERR
  trap repo_cleanup EXIT

  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  STATE_DIR=$(cd "$STATE_DIR" && pwd)
  RUN_RESULT_FILE="$STATE_DIR/.last-run-result"
  rm -f "$RUN_RESULT_FILE"
  LOG_FILE="$STATE_DIR/migrate-$(date '+%Y%m%d-%H%M%S')-$$.log"
  : >"$LOG_FILE"
  chmod 600 "$LOG_FILE" || true
  repo_log "script=$SCRIPT_VERSION source=$SRC_REPO destination=$DST_REPO"
  TARGET_READY=0
  MIGRATION_SUCCESS=0
  FAILSAFE_ACTIONS_RESULT='not-needed'

  CURRENT_STEP='检查源仓库身份'
  validate_or_record_source_identity

  CURRENT_STEP='检查目标仓库身份'
  create_or_validate_destination

  # Only the current version's completion marker is trusted. Older v5.x builds
  # had weaker report classification / metadata coverage, so revalidate them once
  # rather than permanently inheriting an old false-positive completion state.
  if [ -f "$STATE_DIR/MIGRATION_COMPLETE_V53" ]; then
    ui_blank
    ui "✅ 仓库已经是完成状态：${SRC_REPO#*/}"
    ui "   $SRC_REPO → $DST_REPO"
    printf 'already\n' >"$RUN_RESULT_FILE"
    exit 10
  fi
  if [ -f "$STATE_DIR/MIGRATION_COMPLETE_V52" ] || [ -f "$STATE_DIR/MIGRATION_COMPLETE_V51" ] || [ -f "$STATE_DIR/MIGRATION_COMPLETE_V5" ]; then
    ui '✓ 检测到旧版完成记录；v5.3 会按当前规则重新校验一次，不直接沿用旧结论。'
    rm -f "$STATE_DIR/MIGRATION_COMPLETE_V52" "$STATE_DIR/MIGRATION_COMPLETE_V51" "$STATE_DIR/MIGRATION_COMPLETE_V5" \
          "$STATE_DIR/FINAL_SYNC_DONE" "$STATE_DIR/REVIEW_ACCEPTED" "$STATE_DIR/STATE_FORMAT_VERSION"
  fi

  CURRENT_STEP='关闭目标仓库 Actions'
  disable_destination_actions
  ACTIONS_CONFIRMED_DISABLED=1

  perform_initial_migration_if_needed
  ensure_final_snapshot
  finalize_repository
  printf 'success\n' >"$RUN_RESULT_FILE"
  exit 0
}

parent_failsafe_disable_actions_cn() {
  local runner_log="$1" tmp
  [ -f "$STATE_DIR/destination-repository-id" ] || return 0
  tmp="$STATE_DIR/.parent-failsafe-actions-disabled.json"
  printf '{"enabled":false}\n' >"$tmp"
  if dst_api -X PUT "repos/$DST_REPO/actions/permissions" --input "$tmp" >>"$runner_log" 2>&1; then
    ui '   为安全起见，目标仓库 Actions 已确认关闭。'
  else
    ui '   ⚠ 无法确认目标仓库 Actions 是否关闭，请到 GitHub 检查后再继续使用目标仓库。'
  fi
  rm -f "$tmp"
}

batch_migration_wizard() {
  local success_count=0 incomplete_count=0 success_lines='' incomplete_lines='' rc reuse runner_log

  print_startup_intro_cn
  check_dependencies_cn || return 1
  ui_blank
  authenticate_accounts_cn || return 1

  while :; do
    ui_blank
    if ! prompt_repo_pair_cn; then
      if ! confirm '仓库信息有误。还要重新输入一个仓库吗？' 1; then break; fi
      continue
    fi

    ui_blank
    ui "准备迁移：$SRC_REPO → $DST_REPO"

    prepare_stale_state_cn
    rc=$?
    if [ "$rc" -eq 2 ]; then
      if ! confirm '还要处理另一个仓库吗？' 0; then break; fi
      continue
    elif [ "$rc" -ne 0 ]; then
      incomplete_count=$((incomplete_count + 1))
      incomplete_lines="${incomplete_lines}  - $SRC_REPO → $DST_REPO\n"
      if ! confirm '还要继续处理另一个仓库吗？' 0; then break; fi
      continue
    fi

    # Run each repository in its own strict subshell. Raw shell/runtime diagnostics
    # go to a private runner log; human prompts use fd 4 and remain visible.
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    runner_log="$STATE_DIR/runner-$(date '+%Y%m%d-%H%M%S')-$$.log"
    : >"$runner_log"
    chmod 600 "$runner_log" 2>/dev/null || true
    rm -f "$STATE_DIR/.last-run-result"
    ( run_repo_migration_strict ) 2>>"$runner_log"
    rc=$?

    if [ "$rc" -ne 0 ] && [ "$rc" -ne 10 ]; then
      parent_failsafe_disable_actions_cn "$runner_log"
      if [ ! -s "$STATE_DIR/.last-run-result" ]; then
        ui_blank
        ui "❌ 当前仓库没有完成：${SRC_REPO#*/}"
        ui "   $SRC_REPO → $DST_REPO"
        ui '   原因：脚本内部执行异常；技术细节已收进诊断日志，没有把未完成状态当成成功。'
        ui "   诊断日志：$runner_log"
      fi
    fi

    case "$rc" in
      0)
        success_count=$((success_count + 1))
        success_lines="${success_lines}  - $SRC_REPO → $DST_REPO\n"
        ;;
      10)
        ;;
      *)
        incomplete_count=$((incomplete_count + 1))
        incomplete_lines="${incomplete_lines}  - $SRC_REPO → $DST_REPO\n"
        ;;
    esac

    ui_blank
    ui '—— 当前仓库处理结束 ——'
    if ! confirm '还要继续迁移下一个仓库吗？' 0; then
      break
    fi

    ui_blank
    if confirm "沿用上一组 PAT（${SRC_LOGIN} → ${DST_LOGIN}）吗？" 1; then
      ui "✓ 继续使用：$SRC_LOGIN → $DST_LOGIN"
    else
      unset SRC_TOKEN DST_TOKEN SRC_LOGIN DST_LOGIN
      ui '请输入下一组账号 PAT。'
      authenticate_accounts_cn || return 1
    fi
  done

  ui_blank
  ui '====================='
  if [ "$success_count" -gt 0 ]; then
    ui "✅ 本次共成功迁移 $success_count 个仓库："
    printf '%b' "$success_lines"
  else
    ui '本次没有新增完成的仓库。'
  fi
  if [ "$incomplete_count" -gt 0 ]; then
    ui "⚠ 另有 $incomplete_count 个仓库尚未完成："
    printf '%b' "$incomplete_lines"
    ui '这些目标仓库的 Actions 会保持关闭；重新运行本工具即可继续。'
  fi
}

if [ "${1:-}" = '--help' ] || [ "${1:-}" = '-h' ]; then
  cat <<'HELP'
GitHub 私有仓库迁移工具 v5.3

运行：
  chmod +x github-private-repo-migrate-v5.3.sh
  ./github-private-repo-migrate-v5.3.sh

前置：git、gh、jq、git-lfs
Classic PAT：源账号 repo；目标账号 repo + workflow
HELP
  exit 0
fi

if [ "$#" -ne 0 ]; then
  printf '本版面向交互使用，请直接运行：./github-private-repo-migrate-v5.3.sh\n' >&4
  exit 2
fi

batch_migration_wizard
