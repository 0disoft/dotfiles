#################################################################
# 1-Click Developer Tool Updater Function (dev-up)
#################################################################

function dev-up() {
  set -uo pipefail

  local -a task_summaries=()
  local -a version_changes=()

  _log()  { printf "\n==> %s\n" "$*"; }
  _ok()   { printf "  ✓ %s\n" "$1"; task_summaries+=("✓ $1: ${2}s"); }
  _skip() { printf "  ... %s (skipping)\n" "$*"; task_summaries+=("... $1: SKIPPED"); }
  _fail() { printf "  ✗ %s (FAILED)\n" "$1"; task_summaries+=("✗ $1: ${2}s (FAILED)"); }
  _has()  { command -v "$1" >/dev/null 2>&1; }

  _has_timeout_gnu() {
    command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1
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

  _bun_global_node_modules() {
    local bin_g
    bin_g="$(bun pm bin -g 2>/dev/null | tr -d '\r\n' || true)"
    if [ -n "$bin_g" ]; then
      local bun_home
      bun_home="$(dirname "$bin_g")"
      printf '%s/install/global/node_modules\n' "$bun_home"
      return 0
    fi
    printf '%s/.bun/install/global/node_modules\n' "$HOME"
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

    # codex, gemini는 항상 최신 강제
    # 최신 판정이 꼬일 때를 대비해서 npm이 있으면 버전 번호를 박아서 설치
    local codex_before codex_after codex_target codex_latest
    codex_before=""
    if _has codex; then codex_before="$(_ver1 codex --version)"; fi

    codex_target="latest"
    if _has npm; then
      if _has_timeout_gnu; then
        codex_latest="$(timeout 5 npm view @openai/codex version 2>/dev/null | tr -d '\r\n' || true)"
      else
        codex_latest="$(npm view @openai/codex version 2>/dev/null | tr -d '\r\n' || true)"
      fi
      if printf '%s' "$codex_latest" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
        codex_target="$codex_latest"
      fi
    fi

    _run "Codex CLI 강제 최신 설치 (@openai/codex@${codex_target})" bun install -g "@openai/codex@${codex_target}" --force
    codex_after=""
    if _has codex; then codex_after="$(_ver1 codex --version)"; fi
    _record_change "[bun]" "codex" "$codex_before" "$codex_after"

    local gemini_before gemini_after gemini_target gemini_latest
    gemini_before=""
    if _has gemini; then gemini_before="$(_ver1 gemini --version)"; fi
    if [ -z "$gemini_before" ] && _has gemini-cli; then gemini_before="$(_ver1 gemini-cli --version)"; fi

    gemini_target="latest"
    if _has npm; then
      if _has_timeout_gnu; then
        gemini_latest="$(timeout 5 npm view @google/gemini-cli version 2>/dev/null | tr -d '\r\n' || true)"
      else
        gemini_latest="$(npm view @google/gemini-cli version 2>/dev/null | tr -d '\r\n' || true)"
      fi
      if printf '%s' "$gemini_latest" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
        gemini_target="$gemini_latest"
      fi
    fi

    _run "Gemini CLI 강제 최신 설치 (@google/gemini-cli@${gemini_target})" bun install -g "@google/gemini-cli@${gemini_target}" --force
    gemini_after=""
    if _has gemini; then gemini_after="$(_ver1 gemini --version)"; fi
    if [ -z "$gemini_after" ] && _has gemini-cli; then gemini_after="$(_ver1 gemini-cli --version)"; fi
    _record_change "[bun]" "gemini" "$gemini_before" "$gemini_after"

    # bun 전역 전체를 최신으로 강제하고 싶으면 아래 플래그를 켜서 실행
    # DEV_UP_BUN_FORCE_LATEST_ALL=1 dev-up
    # DEV_UP_BUN_FORCE_LATEST_COLD=1 이면 캐시를 비우고 시작
    # DEV_UP_BUN_FORCE_LATEST_NPM=1 이면 npm view로 버전 번호를 박아서 설치
    if [ "${DEV_UP_BUN_FORCE_LATEST_ALL:-0}" -eq 1 ]; then
      local bun_global_nm
      bun_global_nm="$(_bun_global_node_modules)"

      local bun_before bun_after
      bun_before="$(mktemp)"
      bun_after="$(mktemp)"

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

        if [ "${DEV_UP_BUN_FORCE_LATEST_NPM:-0}" -eq 1 ] && _has npm; then
          if _has_timeout_gnu; then
            latest="$(timeout 5 npm view "$pkg" version 2>/dev/null | tr -d '\r\n' || true)"
          else
            latest="$(npm view "$pkg" version 2>/dev/null | tr -d '\r\n' || true)"
          fi

          if printf '%s' "$latest" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
            bun install -g "${pkg}@${latest}" --force >/dev/null 2>&1 || force_ok=0
          else
            bun install -g "${pkg}@latest" --force >/dev/null 2>&1 || force_ok=0
          fi
        else
          bun install -g "${pkg}@latest" --force >/dev/null 2>&1 || force_ok=0
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
      rm -f "$bun_before" "$bun_after"
    else
      _skip "Bun 전역 패키지 최신 강제 설치 (DEV_UP_BUN_FORCE_LATEST_ALL=1 로 활성화)"
    fi

    _log "Bun 전역 postinstall 스크립트 상태 확인"
    local bun_untrusted_output
    bun_untrusted_output="$(bun pm -g untrusted 2>/dev/null || true)"

    if printf '%s\n' "$bun_untrusted_output" | grep -Fq "lifecycle scripts blocked"; then
      bun_untrusted_detected=1
      printf "  ⚠️ Bun 전역에서 차단된 lifecycle 스크립트가 감지되었습니다.\n"
      printf "%s\n" "$bun_untrusted_output"

      local globals_out
      globals_out="$(bun pm ls -g 2>/dev/null || true)"

      local -a BUN_TRUST_ALLOWLIST=()
      local BUN_TRUST_SKIP_PKG="node-pty"

      if printf '%s\n' "$globals_out" | grep -Fq "wrangler@"; then
        BUN_TRUST_ALLOWLIST+=("esbuild" "workerd")
      fi

      if printf '%s\n' "$globals_out" | grep -Fq "vercel@"; then
        BUN_TRUST_ALLOWLIST+=("esbuild" "sharp")
      fi

      local -A _seen=()
      local -a BUN_TRUST_ALLOWLIST_UNIQ=()
      local p
      for p in "${BUN_TRUST_ALLOWLIST[@]}"; do
        if [ -z "${_seen[$p]+x}" ]; then
          _seen[$p]=1
          BUN_TRUST_ALLOWLIST_UNIQ+=("$p")
        fi
      done

      local -a bun_to_trust=()
      for p in "${BUN_TRUST_ALLOWLIST_UNIQ[@]}"; do
        if printf '%s\n' "$bun_untrusted_output" | grep -Eq "(\\\\|/)node_modules(\\\\|/)${p}(\\\\|/)"; then
          bun_to_trust+=("$p")
        fi
      done

      if printf '%s\n' "$bun_untrusted_output" | grep -Eq "(\\\\|/)node_modules(\\\\|/)${BUN_TRUST_SKIP_PKG}(\\\\|/)"; then
        printf "  ... %s는 자동 trust에서 제외했습니다. 필요할 때만 수동으로 처리하세요.\n" "$BUN_TRUST_SKIP_PKG"
      fi

      if [ "${#bun_to_trust[@]}" -gt 0 ]; then
        printf "  ... 자동 trust 후보(현재 전역 패키지 기준): %s\n" "${BUN_TRUST_ALLOWLIST_UNIQ[*]}"
        _run "Bun 전역 postinstall 신뢰 및 실행 (allowlist)" bun pm -g trust "${bun_to_trust[@]}"
      else
        _ok "Bun 전역 postinstall (allowlist 대상 없음)" 0
      fi
    else
      _ok "Bun 전역 postinstall 스크립트 상태 (차단 없음)" 0
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

    _log "Julia Toolchain 업데이트"
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
      if _has py; then
        _run "uv 업그레이드 (pip 설치본)" py -m pip install --upgrade uv
      elif _has python; then
        _run "uv 업그레이드 (pip 설치본)" python -m pip install --upgrade uv
      else
        _skip "Python 런타임이 없어 uv(pip) 업그레이드를 건너뜁니다."
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
  if _has py; then
    pip_before="$(_ver1 py -m pip --version)"
    _run "Python pip 업그레이드 (via py)" py -m pip install --upgrade pip
    pip_after="$(_ver1 py -m pip --version)"
    _record_change "[tool]" "pip" "$pip_before" "$pip_after"
  elif _has python; then
    pip_before="$(_ver1 python -m pip --version)"
    _run "Python pip 업그레이드 (via python)" python -m pip install --upgrade pip
    pip_after="$(_ver1 python -m pip --version)"
    _record_change "[tool]" "pip" "$pip_before" "$pip_after"
  fi

  # 7. Node.js Ecosystem (npm & corepack)
  if _has npm; then
    _log "npm 및 글로벌 패키지 업데이트"

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
      _skip "npm 글로벌 패키지 업데이트 (7일 주기, 아직 시점 아님. 강제는 DEV_UP_NPM_GLOBAL_FORCE=1 dev-up)"
    fi
  else
    _skip "npm이 설치되어 있지 않습니다."
  fi

  if _has corepack; then
    _run "Corepack (pnpm@latest 설정)" corepack use pnpm@latest
  else
    _skip "Corepack이 설치되어 있지 않습니다."
  fi

  # 8. pnpm
  if _has pnpm; then
    _log "pnpm 글로벌 패키지 업데이트"

    local pnpm_before pnpm_after
    pnpm_before="$(_ver1 pnpm --version)"

    local pnpm_start_time
    pnpm_start_time=$(date +%s)

    local pnpm_log
    pnpm_log=$(mktemp)

    if pnpm update -g --latest 2>&1 | tee "$pnpm_log"; then
      _ok "pnpm 글로벌 패키지 업데이트" "$(( $(date +%s) - pnpm_start_time ))"
    else
      _fail "pnpm 글로벌 패키지 업데이트" "$(( $(date +%s) - pnpm_start_time ))"
    fi

    if grep -Fq "Ignored build scripts" "$pnpm_log"; then
      pnpm_warning_detected=1
    fi

    rm -f "$pnpm_log"

    pnpm_after="$(_ver1 pnpm --version)"
    _record_change "[tool]" "pnpm" "$pnpm_before" "$pnpm_after"
  else
    _skip "pnpm이 설치되어 있지 않습니다."
  fi

  # 9. Winget
  if _has winget; then
    _log "Winget 패키지 업그레이드"

    local gh_before gh_after
    gh_before=""
    if _has gh; then gh_before="$(_ver1 gh --version)"; fi

    _log "Winget (GitHub CLI) 업그레이드"
    local gh_start_time
    gh_start_time=$(date +%s)
    if winget upgrade --id GitHub.cli --accept-source-agreements --accept-package-agreements; then
      _ok "Winget (GitHub CLI) 업그레이드" "$(( $(date +%s) - gh_start_time ))"
    else
      _ok "Winget (GitHub CLI) 업그레이드 (업데이트 없음)" "$(( $(date +%s) - gh_start_time ))"
    fi

    gh_after=""
    if _has gh; then gh_after="$(_ver1 gh --version)"; fi
    _record_change "[tool]" "gh" "$gh_before" "$gh_after"

    local starship_before starship_after
    starship_before=""
    if _has starship; then starship_before="$(_ver1 starship --version)"; fi

    _log "Winget (Starship) 업그레이드"
    local starship_start_time
    starship_start_time=$(date +%s)
    if winget upgrade --id Starship.Starship --accept-source-agreements --accept-package-agreements; then
      _ok "Winget (Starship) 업그레이드" "$(( $(date +%s) - starship_start_time ))"
    else
      _ok "Winget (Starship) 업그레이드 (업데이트 없음)" "$(( $(date +%s) - starship_start_time ))"
    fi

    starship_after=""
    if _has starship; then starship_after="$(_ver1 starship --version)"; fi
    _record_change "[tool]" "starship" "$starship_before" "$starship_after"
  else
    _skip "Winget이 설치되어 있지 않습니다."
  fi

  # 10. Chocolatey
  if _has choco; then
    _log "Chocolatey 패키지 업그레이드"

    _log "Choco (Self) 업그레이드"
    local choco_self_start_time
    choco_self_start_time=$(date +%s)
    if choco upgrade chocolatey -y; then
      _ok "Choco (Self) 업그레이드" "$(( $(date +%s) - choco_self_start_time ))"
    else
      _ok "Choco (Self) 업그레이드 (업데이트 없음)" "$(( $(date +%s) - choco_self_start_time ))"
    fi

    _log "Choco (Dart SDK) 업그레이드"
    local dart_start_time
    dart_start_time=$(date +%s)
    if choco upgrade dart-sdk -y; then
      _ok "Choco (Dart SDK) 업그레이드" "$(( $(date +%s) - dart_start_time ))"
    else
      _ok "Choco (Dart SDK) 업그레이드 (업데이트 없음)" "$(( $(date +%s) - dart_start_time ))"
    fi
  else
    _skip "Chocolatey가 설치되어 있지 않습니다."
  fi

  # 요약
  _log "⏱️ 작업별 소요 시간 요약"
  local summary
  for summary in "${task_summaries[@]}"; do
    printf "  %s\n" "$summary"
  done

  local end_ts
  end_ts=$(date +%s)
  _log "✅ 모든 작업 완료! (총 소요 시간: $((end_ts - start_ts))초)"

  if [ "$pnpm_warning_detected" -eq 1 ]; then
    printf "\n"
    printf "  💡 pnpm 경고 알림\n"
    printf "    로그에서 \"Ignored build scripts\"가 감지되었습니다.\n"
    printf "    'pnpm approve-builds -g'를 실행해 신뢰하는 빌드를 승인하세요.\n"
  fi

  if [ "$bun_untrusted_detected" -eq 1 ]; then
    printf "\n"
    printf "  💡 Bun 안내\n"
    printf "    trust --all 자동 실행을 하지 않습니다.\n"
    printf "    wrangler, vercel 전역 사용 여부에 따라 allowlist를 구성합니다.\n"
    printf "    node-pty는 자동 trust에서 제외합니다.\n"
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

  unset -f _log _ok _skip _fail _has _has_timeout_gnu _run _ver1 _record_change
  unset -f _state_dir _npm_global_update_due _npm_global_update_stamp
  unset -f _bun_global_node_modules _bun_list_globals _bun_snapshot_globals _append_version_changes_from_files
  unset task_summaries version_changes
}
