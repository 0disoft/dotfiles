#################################################################
# 1-Click Developer Tool Updater Function (dev-up)
#################################################################

function dev-up() {
  # 현재 쉘 상태 백업 (dev-up 종료 후 원복)
  local __dev_up_old_opts __dev_up_old_trap_int __dev_up_old_trap_term
  __dev_up_old_opts="$(set +o)"
  __dev_up_old_trap_int="$(trap -p INT 2>/dev/null || true)"
  __dev_up_old_trap_term="$(trap -p TERM 2>/dev/null || true)"

  # 1. Trap 설정: 중간에 강제 종료되어도 뒷정리 수행
  trap '_dev_up_cleanup; return 130' INT
  trap '_dev_up_cleanup; return 143' TERM

  set -uo pipefail

  local -a task_summaries=()
  local -a version_changes=()
  local -a temp_files=()

  # -----------------------------------------------------------
  # Helper Functions
  # -----------------------------------------------------------
  _dev_up_cleanup() {
    # 먼저 trap과 set 옵션부터 원복 (dev-up 끝난 뒤 Ctrl+C 안전)
    eval "$__dev_up_old_opts" 2>/dev/null || true
    if [ -n "$__dev_up_old_trap_int" ]; then eval "$__dev_up_old_trap_int" || true; else trap - INT; fi
    if [ -n "$__dev_up_old_trap_term" ]; then eval "$__dev_up_old_trap_term" || true; else trap - TERM; fi

    # 임시 파일 삭제
    if [ ${#temp_files[@]} -gt 0 ]; then
      rm -f "${temp_files[@]}" 2>/dev/null || true
    fi

    # 함수 해제 (global namespace 오염 방지)
    unset -f _log _ok _skip _fail _has _has_timeout_gnu _run _ver1 _record_change
    unset -f _state_dir _npm_global_update_due _npm_global_update_stamp _npm_view_version
    unset -f _bun_global_node_modules _bun_global_pkg_version _ensure_bun_global_pinned
    unset -f _bun_list_globals _bun_snapshot_globals _append_version_changes_from_files
    unset -f _bun_check_and_trust_allowlist
    unset -f _dev_up_cleanup
  }

  _log()  { printf "\n==> %s\n" "$*"; }
  _ok()   { printf "  ✓ %s\n" "$1"; task_summaries+=("✓ $1: ${2}s"); }
  _skip() { printf "  ... %s (skipping)\n" "$*"; task_summaries+=("... $*: SKIPPED"); }
  _fail() { printf "  ✗ %s (FAILED)\n" "$1"; task_summaries+=("✗ $1: ${2}s (FAILED)"); }
  _has()  { command -v "$1" >/dev/null 2>&1; }

  # Windows timeout.exe(pause)와 GNU timeout 구분
  _has_timeout_gnu() {
    _has timeout && timeout --version 2>&1 | grep -q "GNU coreutils"
  }

  _run() {
    local title="$1"; shift
    _log "$title"

    local start_time end_time duration
    start_time=$(date +%s)

    if "$@"; then
      end_time=$(date +%s)
      duration=$((end_time - start_time))
      _ok "$title" "$duration"
      return 0
    else
      end_time=$(date +%s)
      duration=$((end_time - start_time))
      _fail "$title" "$duration"
      return 1
    fi
  }

  _ver1() {
    local out
    out="$("$@" 2>/dev/null | head -n 1 | tr -d '\r')"
    printf '%s' "$out"
  }

  _record_change() {
    local prefix="$1"
    local name="$2"
    local before="$3"
    local after="$4"

    if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
      version_changes+=("${prefix} ${name} ${before} -> ${after}")
    fi
  }

  _state_dir() {
    printf '%s\n' "${DEV_UP_STATE_DIR:-$HOME/.cache/dev-up}"
  }

  _npm_global_update_due() {
    if [ "${DEV_UP_NPM_GLOBAL_FORCE:-0}" -eq 1 ]; then
      return 0
    fi

    local interval_days
    interval_days="${DEV_UP_NPM_GLOBAL_INTERVAL_DAYS:-7}"
    if ! printf '%s' "$interval_days" | grep -Eq '^[0-9]+$'; then
      interval_days=7
    fi

    local sd stamp now last interval
    sd="$(_state_dir)"
    mkdir -p "$sd" >/dev/null 2>&1 || true
    stamp="${sd}/npm-global-update.ts"

    now=$(date +%s)
    interval=$((interval_days * 86400))

    if [ ! -f "$stamp" ]; then
      return 0
    fi

    last="$(cat "$stamp" 2>/dev/null | tr -d '\r\n' || true)"
    if ! printf '%s' "$last" | grep -Eq '^[0-9]+$'; then
      return 0
    fi

    if [ $((now - last)) -ge "$interval" ]; then
      return 0
    fi

    return 1
  }

  _npm_global_update_stamp() {
    local sd now
    sd="$(_state_dir)"
    mkdir -p "$sd" >/dev/null 2>&1 || true
    now=$(date +%s)
    printf '%s' "$now" > "${sd}/npm-global-update.ts" 2>/dev/null || true
  }

  _npm_view_version() {
    local pkg="$1"
    local out=""

    if ! _has npm; then
      return 0
    fi

    if _has_timeout_gnu; then
      out="$(timeout 5 npm view "$pkg" version 2>/dev/null | tr -d '\r\n' || true)"
    else
      out="$(npm view "$pkg" version 2>/dev/null | tr -d '\r\n' || true)"
    fi

    if printf '%s' "$out" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
      printf '%s' "$out"
    else
      printf ""
    fi
  }

  _bun_global_node_modules() {
    local bin_g
    bin_g="$(bun pm bin -g 2>/dev/null | tr -d '\r\n' || true)"

    if [ -n "$bin_g" ]; then
      local bun_root
      bun_root="$(dirname "$bin_g")"
      printf '%s/install/global/node_modules\n' "$bun_root"
      return 0
    fi

    printf '%s/.bun/install/global/node_modules\n' "$HOME"
  }

  _bun_global_pkg_version() {
    local pkg="$1"
    local nm pj line ver

    nm="$(_bun_global_node_modules)"
    pj="${nm}/${pkg}/package.json"

    if [ ! -f "$pj" ]; then
      printf ""
      return 0
    fi

    line="$(grep -m1 "\"version\"" "$pj" 2>/dev/null || true)"
    ver="$(printf '%s\n' "$line" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
    printf '%s' "$ver"
  }

  _ensure_bun_global_pinned() {
    local label="$1"
    local pkg="$2"
    local target="$3"

    local installed
    installed="$(_bun_global_pkg_version "$pkg")"

    if [ -n "$installed" ] && [ "$installed" = "$target" ]; then
      _ok "${label} 최신 확인 (이미 ${installed})" 0
      return 0
    fi

    if [ "${DEV_UP_BUN_FORCE_REINSTALL:-0}" -eq 1 ]; then
      _run "${label} 설치 (${pkg}@${target}, force)" bun install -g "${pkg}@${target}" --force
    else
      _run "${label} 설치 (${pkg}@${target})" bun install -g "${pkg}@${target}"
    fi
  }

  _bun_list_globals() {
    local nm="$1"
    [ -d "$nm" ] || return 0

    local d base s sbase
    while IFS= read -r d; do
      base="$(basename "$d")"

      if [ "${base#@}" != "$base" ]; then
        while IFS= read -r s; do
          sbase="$(basename "$s")"
          printf '%s/%s\n' "$base" "$sbase"
        done < <(find "$d" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
      else
        printf '%s\n' "$base"
      fi
    done < <(find "$nm" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
  }

  _bun_snapshot_globals() {
    local nm="$1"
    local out_file="$2"

    : > "$out_file"
    [ -d "$nm" ] || return 0

    local pkg pj ver line
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      pj="${nm}/${pkg}/package.json"

      ver="unknown"
      if [ -f "$pj" ]; then
        line="$(grep -m1 "\"version\"" "$pj" 2>/dev/null || true)"
        ver="$(printf '%s\n' "$line" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
        [ -n "$ver" ] || ver="unknown"
      fi

      printf '%s\t%s\n' "$pkg" "$ver" >> "$out_file"
    done < <(_bun_list_globals "$nm" | sort)
  }

  _append_version_changes_from_files() {
    local before_file="$1"
    local after_file="$2"
    local prefix="$3"

    local -A before=()
    local -A after=()

    local name ver
    while IFS=$'\t' read -r name ver; do
      [ -n "$name" ] || continue
      before["$name"]="$ver"
    done < "$before_file"

    while IFS=$'\t' read -r name ver; do
      [ -n "$name" ] || continue
      after["$name"]="$ver"
    done < "$after_file"

    for name in "${!after[@]}"; do
      local b="${before[$name]:-}"
      local a="${after[$name]:-}"
      if [ -n "$b" ] && [ -n "$a" ] && [ "$b" != "unknown" ] && [ "$a" != "unknown" ] && [ "$b" != "$a" ]; then
        version_changes+=("${prefix} ${name} ${b} -> ${a}")
      fi
    done
  }

  # 글로벌로 설치된 특정 패키지 폴더에서 untrusted 검사 후 allowlist만 trust
  _bun_check_and_trust_allowlist() {
    local bun_global_nm="$1"
    local parent_pkg="$2"
    shift 2
    local -a allowlist=("$@")

    local pkg_dir="${bun_global_nm}/${parent_pkg}"
    [ -d "$pkg_dir" ] || return 0

    local out
    out="$(
      cd "$pkg_dir" 2>/dev/null && bun pm untrusted 2>/dev/null || true
    )"

    if [ -z "$out" ]; then
      return 0
    fi

    local -a to_trust=()
    local dep
    for dep in "${allowlist[@]}"; do
      if printf '%s\n' "$out" | grep -Eq "(\\\\|/)node_modules(\\\\|/)${dep}(\\\\|/)" || printf '%s\n' "$out" | grep -Eq "(^|[[:space:]])${dep}([[:space:]]|$)"; then
        to_trust+=("$dep")
      fi
    done

    if [ "${#to_trust[@]}" -gt 0 ]; then
      bun_untrusted_detected=1
      _run "Bun trust (${parent_pkg})" bash -lc "cd \"${pkg_dir}\" && bun pm trust ${to_trust[*]}"
    fi
  }

  # -----------------------------------------------------------
  # Main Logic
  # -----------------------------------------------------------

  local pnpm_warning_detected=0
  local bun_untrusted_detected=0

  local start_ts
  start_ts=$(date +%s)

  # 1. Deno
  if _has deno; then
    local deno_before deno_after
    deno_before="$(_ver1 deno --version)"
    _run "Deno 업그레이드" deno upgrade
    deno_after="$(_ver1 deno --version)"
    _record_change "[tool]" "deno" "$deno_before" "$deno_after"
  else
    _skip "Deno가 설치되어 있지 않습니다."
  fi

  # 2. Bun
  if _has bun; then
    local bun_before_runtime bun_after_runtime
    bun_before_runtime="$(_ver1 bun --version)"
    _run "Bun 런타임 업그레이드" bun upgrade
    bun_after_runtime="$(_ver1 bun --version)"
    _record_change "[tool]" "bun" "$bun_before_runtime" "$bun_after_runtime"

    _run "Bun 글로벌 패키지 업데이트" bun update -g

    # Codex / Gemini CLI
    local codex_target codex_latest
    codex_target="latest"
    codex_latest="$(_npm_view_version "@openai/codex")"
    if [ -n "$codex_latest" ]; then
      codex_target="$codex_latest"
      _ensure_bun_global_pinned "Codex CLI" "@openai/codex" "$codex_target"
    else
      _run "Codex CLI 설치 (@openai/codex@latest)" bun install -g "@openai/codex@latest"
    fi

    local gemini_target gemini_latest
    gemini_target="latest"
    gemini_latest="$(_npm_view_version "@google/gemini-cli")"
    if [ -n "$gemini_latest" ]; then
      gemini_target="$gemini_latest"
      _ensure_bun_global_pinned "Gemini CLI" "@google/gemini-cli" "$gemini_target"
    else
      _run "Gemini CLI 설치 (@google/gemini-cli@latest)" bun install -g "@google/gemini-cli@latest"
    fi

    # Bun Force Latest All Logic
    if [ "${DEV_UP_BUN_FORCE_LATEST_ALL:-0}" -eq 1 ]; then
      local bun_global_nm
      bun_global_nm="$(_bun_global_node_modules)"

      local bun_before bun_after
      bun_before="$(mktemp)"
      bun_after="$(mktemp)"
      temp_files+=("$bun_before" "$bun_after")

      _bun_snapshot_globals "$bun_global_nm" "$bun_before"

      if [ "${DEV_UP_BUN_FORCE_LATEST_COLD:-0}" -eq 1 ]; then
        _log "Bun 캐시 정리"
        if bun pm cache rm >/dev/null 2>&1; then
          printf "  ✓ bun pm cache rm\n"
        else
          rm -rf "${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}" >/dev/null 2>&1 || true
          printf "  ... bun pm cache rm 실패, 캐시 디렉터리 삭제 시도\n"
        fi
      fi

      _log "Bun 전역 패키지 최신 강제 설치"
      local force_start force_end force_ok
      force_start=$(date +%s)
      force_ok=1

      local pkg latest
      while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue

        if [ "${DEV_UP_BUN_FORCE_LATEST_NPM:-0}" -eq 1 ]; then
          latest="$(_npm_view_version "$pkg")"
          if [ -n "$latest" ]; then
            bun install -g "${pkg}@${latest}" >/dev/null 2>&1 || force_ok=0
          else
            bun install -g "${pkg}@latest" >/dev/null 2>&1 || force_ok=0
          fi
        else
          bun install -g "${pkg}@latest" >/dev/null 2>&1 || force_ok=0
        fi
      done < <(_bun_list_globals "$bun_global_nm" | sort)

      force_end=$(date +%s)
      if [ "$force_ok" -eq 1 ]; then
        _ok "Bun 전역 패키지 최신 강제 설치" "$((force_end - force_start))"
      else
        _fail "Bun 전역 패키지 최신 강제 설치" "$((force_end - force_start))"
      fi

      _bun_snapshot_globals "$bun_global_nm" "$bun_after"
      _append_version_changes_from_files "$bun_before" "$bun_after" "[bun]"
    else
      _skip "Bun 전역 패키지 최신 강제 설치 (DEV_UP_BUN_FORCE_LATEST_ALL=1 로 활성화)"
    fi

    # Bun postinstall 차단 자동 복구 (전역에서 가장 자주 터지는 케이스만)
    local bun_global_nm
    bun_global_nm="$(_bun_global_node_modules)"

    if [ -d "$bun_global_nm/wrangler" ]; then
      _bun_check_and_trust_allowlist "$bun_global_nm" "wrangler" "esbuild" "workerd"
    fi
    if [ -d "$bun_global_nm/vercel" ]; then
      _bun_check_and_trust_allowlist "$bun_global_nm" "vercel" "esbuild" "sharp"
    fi

    if [ "$bun_untrusted_detected" -eq 0 ]; then
      _ok "Bun postinstall 차단 검사 (주요 툴 기준)" 0
    fi
  else
    _skip "Bun이 설치되어 있지 않습니다."
  fi

  # 3. Rust
  if _has rustup; then
    local rust_before rust_after
    rust_before=""
    if _has rustc; then rust_before="$(_ver1 rustc --version)"; fi
    _run "Rust Toolchain 업데이트" rustup update
    rust_after=""
    if _has rustc; then rust_after="$(_ver1 rustc --version)"; fi
    _record_change "[tool]" "rustc" "$rust_before" "$rust_after"
  else
    _skip "rustup이 설치되어 있지 않습니다."
  fi

  # 4. Julia
  if _has juliaup; then
    local julia_before julia_after
    julia_before=""
    if _has julia; then julia_before="$(_ver1 julia --version)"; fi
    _run "Juliaup 자체 업데이트" juliaup self update
    _run "Julia 채널 업데이트" juliaup update
    julia_after=""
    if _has julia; then julia_after="$(_ver1 julia --version)"; fi
    _record_change "[tool]" "julia" "$julia_before" "$julia_after"
  else
    _skip "Juliaup이 설치되어 있지 않습니다."
  fi

  # 5. Flutter
  if _has flutter; then
    local flutter_before flutter_after
    flutter_before="$(_ver1 flutter --version)"
    _run "Flutter SDK 업그레이드" flutter upgrade
    flutter_after="$(_ver1 flutter --version)"
    _record_change "[tool]" "flutter" "$flutter_before" "$flutter_after"
  else
    _skip "Flutter가 설치되어 있지 않습니다."
  fi

  # 6. Python Ecosystem (uv & pip)
  local python_cmd=""
  if _has py; then python_cmd="py"
  elif _has python3; then python_cmd="python3"
  elif _has python; then python_cmd="python"
  fi

  if _has uv; then
    local uv_before uv_after
    uv_before="$(_ver1 uv --version)"

    local uv_path
    uv_path="$(command -v uv 2>/dev/null || true)"

    local uv_is_pip=0
    if printf '%s' "$uv_path" | grep -qi "Python" && printf '%s' "$uv_path" | grep -qi "Scripts"; then
      uv_is_pip=1
    fi

    if [ "$uv_is_pip" -eq 1 ]; then
      if [ -n "$python_cmd" ]; then
        _run "uv 업그레이드 (pip 설치본, via $python_cmd)" "$python_cmd" -m pip install --upgrade uv
      else
        _skip "Python 런타임을 찾을 수 없어 uv(pip) 업그레이드를 건너뜁니다."
      fi
    else
      _run "uv 자체 업그레이드" uv self update
    fi

    _run "uv 글로벌 도구 전체 업그레이드" uv tool upgrade --all
    uv_after="$(_ver1 uv --version)"
    _record_change "[tool]" "uv" "$uv_before" "$uv_after"
  else
    _skip "uv가 설치되어 있지 않습니다."
  fi

  local pip_before pip_after
  pip_before=""
  if [ -n "$python_cmd" ]; then
    pip_before="$(_ver1 "$python_cmd" -m pip --version)"
    _run "Python pip 업그레이드 (via $python_cmd)" "$python_cmd" -m pip install --upgrade pip
    pip_after="$(_ver1 "$python_cmd" -m pip --version)"
    _record_change "[tool]" "pip" "$pip_before" "$pip_after"
  fi

  # 7. Node.js Ecosystem
  if _has npm; then
    local npm_before npm_after
    npm_before="$(_ver1 npm -v)"
    _run "npm 자체 업데이트" npm install -g npm@latest --no-fund --no-audit
    npm_after="$(_ver1 npm -v)"
    _record_change "[tool]" "npm" "$npm_before" "$npm_after"

    if _npm_global_update_due; then
      if _run "npm 글로벌 패키지 업데이트 (7일 주기)" npm update -g --no-fund --no-audit; then
        _npm_global_update_stamp
      fi
    else
      _skip "npm 글로벌 패키지 업데이트 (7일 주기 미도래)"
    fi
  else
    _skip "npm이 설치되어 있지 않습니다."
  fi

  if _has corepack; then
    if ! _run "Corepack (pnpm@latest 설정)" corepack use pnpm@latest; then
      _run "Corepack enable pnpm" corepack enable pnpm
      _run "Corepack prepare pnpm@latest --activate" corepack prepare pnpm@latest --activate
    fi
  else
    _skip "Corepack이 설치되어 있지 않습니다."
  fi

  # 8. pnpm
  if _has pnpm; then
    local pnpm_start_time
    pnpm_start_time=$(date +%s)
    local pnpm_log
    pnpm_log=$(mktemp)
    temp_files+=("$pnpm_log")

    if pnpm update -g --latest 2>&1 | tee "$pnpm_log"; then
      _ok "pnpm 글로벌 패키지 업데이트" "$(( $(date +%s) - pnpm_start_time ))"
    else
      _fail "pnpm 글로벌 패키지 업데이트" "$(( $(date +%s) - pnpm_start_time ))"
    fi

    if grep -Fq "Ignored build scripts" "$pnpm_log"; then
      pnpm_warning_detected=1
    fi
  else
    _skip "pnpm이 설치되어 있지 않습니다."
  fi

  # 9. Winget
  if _has winget; then
    local gh_start_time
    gh_start_time=$(date +%s)

    _log "Winget (GitHub CLI) 업그레이드"
    if winget upgrade --id GitHub.cli --accept-source-agreements --accept-package-agreements; then
      _ok "Winget (GitHub CLI) 완료" "$(( $(date +%s) - gh_start_time ))"
    else
      _fail "Winget (GitHub CLI) 실패 (권한 확인 필요)" "$(( $(date +%s) - gh_start_time ))"
    fi

    _log "Winget (Starship) 업그레이드"
    local starship_start_time
    starship_start_time=$(date +%s)
    if winget upgrade --id Starship.Starship --accept-source-agreements --accept-package-agreements; then
      _ok "Winget (Starship) 완료" "$(( $(date +%s) - starship_start_time ))"
    else
      _fail "Winget (Starship) 실패 (권한 확인 필요)" "$(( $(date +%s) - starship_start_time ))"
    fi
  else
    _skip "Winget이 설치되어 있지 않습니다."
  fi

  # 10. Chocolatey
  if _has choco; then
    _log "Chocolatey 패키지 업그레이드"

    if choco upgrade chocolatey -y; then
      _ok "Choco (Self)" 0
    else
      _fail "Choco (Self) 실패 (관리자 권한 필요)" 0
    fi

    if choco upgrade dart-sdk -y; then
      _ok "Choco (Dart SDK)" 0
    else
      _fail "Choco (Dart SDK) 실패" 0
    fi
  else
    _skip "Chocolatey가 설치되어 있지 않습니다."
  fi

  # 요약 출력
  _log "⏱️ 작업별 소요 시간 요약"
  local summary
  for summary in "${task_summaries[@]}"; do
    printf "  %s\n" "$summary"
  done

  local end_ts
  end_ts=$(date +%s)
  _log "✅ 모든 작업 완료! (총 소요 시간: $((end_ts - start_ts))초)"

  if [ "$pnpm_warning_detected" -eq 1 ]; then
    printf "\n  💡 pnpm 경고: 'pnpm approve-builds -g' 확인 필요\n"
  fi
  if [ "$bun_untrusted_detected" -eq 1 ]; then
    printf "\n  💡 Bun 경고: untrusted lifecycle scripts 감지됨\n"
  fi

  printf "\n"
  if [ "${#version_changes[@]}" -gt 0 ]; then
    _log "⬆️ 이번 실행에서 버전이 바뀐 것들"
    local vc
    for vc in "${version_changes[@]}"; do
      printf "  %s\n" "$vc"
    done
  else
    _log "⬆️ 이번 실행에서 버전 변경 없음"
  fi

  # 정리 함수 호출 (Trap 때문에 명시적으로 호출)
  _dev_up_cleanup
}
