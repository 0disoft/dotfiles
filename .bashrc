#################################################################
# 1-Click Developer Tool Updater Function (dev-up)
#################################################################

function dev-up() {
  set -uo pipefail

  local -a task_summaries=()

  _log()  { printf "\n==> %s\n" "$*"; }
  _ok()   { printf "  ✓ %s\n" "$1"; task_summaries+=("✓ $1: ${2}s"); }
  _skip() { printf "  ... %s (skipping)\n" "$*"; task_summaries+=("... $1: SKIPPED"); }
  _fail() { printf "  ✗ %s (FAILED)\n" "$1"; task_summaries+=("✗ $1: ${2}s (FAILED)"); }
  _has()  { command -v "$1" >/dev/null 2>&1; }

  _run() {
    local title="$1"; shift
    _log "$title"

    local start_time end_time duration
    start_time=$(date +%s)

    if "$@"; then
      end_time=$(date +%s)
      duration=$((end_time - start_time))
      _ok "$title" "$duration"
    else
      end_time=$(date +%s)
      duration=$((end_time - start_time))
      _fail "$title" "$duration"
    fi
  }

  local pnpm_warning_detected=0
  local bun_untrusted_detected=0

  local start_ts
  start_ts=$(date +%s)

  # 1. Deno
  if _has deno; then
    _run "Deno 업그레이드" deno upgrade
  else
    _skip "Deno가 설치되어 있지 않습니다."
  fi

  # 2. Bun
  if _has bun; then
    _run "Bun 런타임 업그레이드" bun upgrade
    _run "Bun 글로벌 패키지 업데이트" bun update -g

    _log "Bun 전역 postinstall 스크립트 상태 확인"
    local bun_untrusted_output
    bun_untrusted_output="$(bun pm -g untrusted 2>/dev/null || true)"

    if printf '%s\n' "$bun_untrusted_output" | grep -Fq "lifecycle scripts blocked"; then
      bun_untrusted_detected=1
      printf "  ⚠️ Bun 전역에서 차단된 lifecycle 스크립트가 감지되었습니다.\n"
      printf "%s\n" "$bun_untrusted_output"

      # 전역 패키지 목록을 기준으로 trust allowlist 자동 구성
      local globals_out
      globals_out="$(bun pm ls -g 2>/dev/null || true)"

      local -a BUN_TRUST_ALLOWLIST=()
      local BUN_TRUST_SKIP_PKG="node-pty"

      # wrangler -> workerd, esbuild
      if printf '%s\n' "$globals_out" | grep -Fq "wrangler@"; then
        BUN_TRUST_ALLOWLIST+=("esbuild" "workerd")
      fi

      # vercel -> esbuild, sharp
      if printf '%s\n' "$globals_out" | grep -Fq "vercel@"; then
        BUN_TRUST_ALLOWLIST+=("esbuild" "sharp")
      fi

      # 중복 제거
      local -A _seen=()
      local -a BUN_TRUST_ALLOWLIST_UNIQ=()
      local p
      for p in "${BUN_TRUST_ALLOWLIST[@]}"; do
        if [ -z "${_seen[$p]+x}" ]; then
          _seen[$p]=1
          BUN_TRUST_ALLOWLIST_UNIQ+=("$p")
        fi
      done

      # untrusted에 실제로 있는 것만 골라서 trust
      local -a bun_to_trust=()
      for p in "${BUN_TRUST_ALLOWLIST_UNIQ[@]}"; do
        if printf '%s\n' "$bun_untrusted_output" | grep -Fq "\\node_modules\\${p}"; then
          bun_to_trust+=("$p")
        fi
      done

      # node-pty는 자동 trust에서 제외
      if printf '%s\n' "$bun_untrusted_output" | grep -Fq "\\node_modules\\${BUN_TRUST_SKIP_PKG}"; then
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
    _run "Rust Toolchain 업데이트" rustup update
  else
    _skip "rustup이 설치되어 있지 않습니다."
  fi

  # 4. Julia
  if _has juliaup; then
    _log "Julia Toolchain 업데이트"
    _run "Juliaup 자체 업데이트" juliaup self update
    _run "Julia 채널 업데이트" juliaup update
  else
    _skip "Juliaup이 설치되어 있지 않습니다."
  fi

  # 5. Flutter
  if _has flutter; then
    _run "Flutter SDK 업그레이드" flutter upgrade
  else
    _skip "Flutter가 설치되어 있지 않습니다."
  fi

  # 6. Python Ecosystem (uv & pip)
  if _has uv; then
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
  else
    _skip "uv가 설치되어 있지 않습니다."
  fi

  # pip 업그레이드
  if _has py; then
    _run "Python pip 업그레이드 (via py)" py -m pip install --upgrade pip
  elif _has python; then
    _run "Python pip 업그레이드 (via python)" python -m pip install --upgrade pip
  fi

  # 7. Node.js Ecosystem (npm & corepack)
  if _has npm; then
    _log "npm 및 글로벌 패키지 업데이트"
    _run "npm 자체 업데이트" npm install -g npm@latest
    _run "npm 글로벌 패키지 업데이트" npm update -g
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
  else
    _skip "pnpm이 설치되어 있지 않습니다."
  fi

  # 9. Winget
  if _has winget; then
    _log "Winget 패키지 업그레이드"

    _log "Winget (GitHub CLI) 업그레이드"
    local gh_start_time
    gh_start_time=$(date +%s)
    if winget upgrade --id GitHub.cli --accept-source-agreements --accept-package-agreements; then
      _ok "Winget (GitHub CLI) 업그레이드" "$(( $(date +%s) - gh_start_time ))"
    else
      _ok "Winget (GitHub CLI) 업그레이드 (업데이트 없음)" "$(( $(date +%s) - gh_start_time ))"
    fi

    _log "Winget (Starship) 업그레이드"
    local starship_start_time
    starship_start_time=$(date +%s)
    if winget upgrade --id Starship.Starship --accept-source-agreements --accept-package-agreements; then
      _ok "Winget (Starship) 업그레이드" "$(( $(date +%s) - starship_start_time ))"
    else
      _ok "Winget (Starship) 업그레이드 (업데이트 없음)" "$(( $(date +%s) - starship_start_time ))"
    fi
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

  unset -f _log _ok _skip _fail _has _run
  unset task_summaries
}
