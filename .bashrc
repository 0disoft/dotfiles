#################################################################
# 1-Click Developer Tool Updater Function (dev-up)
# (dev-up 함수 정의)
#################################################################

function dev-up() {
    set -uo pipefail

    # 작업 요약을 저장할 배열
    local task_summaries=()
    
    # --- 로그 헬퍼 함수 (시간 저장 로직) ---
    _log()  { printf "\n==> %s\n" "$*"; }
    # $1: 메시지, $2: 소요 시간(초)
    _ok()   { 
        printf "  ✓ %s\n" "$1" # 실시간 피드백 (시간 제외)
        task_summaries+=("✓ $1: $2""s") # 요약 배열에 저장
    }
    _skip() { 
        printf "  ... %s (skipping)\n" "$*" # 실시간 피드백
        task_summaries+=("... $1: SKIPPED") # 요약 배열에 저장
    }
    # $1: 메시지, $2: 소요 시간(초)
    _fail() { 
        printf "  ✗ %s (FAILED)\n" "$1" # 실시간 피드백 (시간 제외)
        task_summaries+=("✗ $1: $2""s (FAILED)") # 요약 배열에 저장
    }
    _has()  { command -v "$1" >/dev/null 2>&1; }

    # --- 실행 래퍼 함수 (pnpm, winget, choco 제외) ---
    _run() {
        local title="$1"; shift
        _log "$title"
        
        local start_time
        local end_time
        local duration
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

    # pnpm 경고를 추적하기 위한 플래그
    local pnpm_warning_detected=0
    # Bun postinstall 차단 감지 플래그
    local bun_untrusted_detected=0
    # 전체 시작 시간
    local start_ts
    start_ts=$(date +%s)

    # --- 1. Deno ---
    if _has deno; then
        _run "Deno 업그레이드" deno upgrade
    else
        _skip "Deno가 설치되어 있지 않습니다."
    fi

    # --- 2. Bun ---
    if _has bun; then
        # Bun 런타임 업그레이드
        _run "Bun 런타임 업그레이드" bun upgrade

        # Bun 글로벌 패키지 업데이트
        _run "Bun 글로벌 패키지 업데이트" bun update -g

        # Bun 글로벌 업데이트 이후, 차단된 postinstall 스크립트 자동 처리
        _log "Bun 전역 postinstall 스크립트 상태 확인"
        local bun_untrusted_output
        bun_untrusted_output="$(bun pm -g untrusted 2>/dev/null || true)"

        if printf '%s\n' "$bun_untrusted_output" | grep -q "These dependencies had their lifecycle scripts blocked during install."; then
            bun_untrusted_detected=1
            printf "  ⚠️ Bun 전역에서 차단된 lifecycle 스크립트가 감지되었습니다.\n"
            printf "%s\n" "$bun_untrusted_output"

            # 모든 차단된 의존성의 스크립트를 신뢰하고 실행
            _run "Bun 전역 postinstall 스크립트 신뢰 및 실행 (bun pm -g trust --all)" \
                bun pm -g trust --all
        else
            _ok "Bun 전역 postinstall 스크립트 상태 (차단 없음)" 0
        fi
    else
        _skip "Bun이 설치되어 있지 않습니다."
    fi

    # --- 3. Rust ---
    if _has rustup; then
        _run "Rust Toolchain 업데이트" rustup update
    else
        _skip "rustup이 설치되어 있지 않습니다."
    fi

    # --- 4. Julia (juliaup) ---
    if _has juliaup; then
        _log "Julia Toolchain 업데이트"
        _run "Juliaup 자체 업데이트" juliaup self update
        _run "Julia 채널 업데이트" juliaup update
    else
        _skip "Juliaup이 설치되어 있지 않습니다."
    fi

    # --- 5. Flutter ---
    if _has flutter; then
        _run "Flutter SDK 업그레이드" flutter upgrade
    else
        _skip "Flutter가 설치되어 있지 않습니다."
    fi

    # --- 6. Python Ecosystem (uv & pip) ---
    # (1) uv: 엔진 업데이트 및 글로벌 도구 전체 업데이트
    if _has uv; then
        _run "uv 자체 업그레이드" uv self update
        _run "uv 글로벌 도구 전체 업그레이드" uv tool upgrade --all
    else
        _skip "uv가 설치되어 있지 않습니다."
    fi

    # (2) pip: 시스템 pip 업데이트 (레거시 호환용)
    if _has py; then
        _run "Python pip 업그레이드 (via py)" py -m pip install --upgrade pip
    elif _has python; then
        _run "Python pip 업그레이드 (via python)" python -m pip install --upgrade pip
    fi

    # --- 7. Node.js Ecosystem (npm & corepack) ---
    
    # (1) npm 업데이트
    if _has npm; then
        _log "npm 및 글로벌 패키지 업데이트"
        # npm 자체를 최신 버전으로 업데이트 (npm install -g npm@latest)
        _run "npm 자체 업데이트" npm install -g npm@latest
        # 설치된 글로벌 패키지들을 업데이트 (npm update -g)
        _run "npm 글로벌 패키지 업데이트" npm update -g
    else
        _skip "npm이 설치되어 있지 않습니다."
    fi

    # (2) Corepack 업데이트
    if _has corepack; then
        _run "Corepack (pnpm@latest 설정)" corepack use pnpm@latest
    else
        _skip "Corepack이 설치되어 있지 않습니다."
    fi

    # --- 8. pnpm Global Packages ---
    if _has pnpm; then
        _log "pnpm 글로벌 패키지 업데이트"
        local pnpm_start_time
        pnpm_start_time=$(date +%s)
        
        local pnpm_log
        pnpm_log=$(mktemp)
        
        if pnpm update -g --latest 2>&1 | tee "$pnpm_log"; then
            local pnpm_end_time
            pnpm_end_time=$(date +%s)
            _ok "pnpm 글로벌 패키지 업데이트" "$((pnpm_end_time - pnpm_start_time))"
        else
            local pnpm_end_time
            pnpm_end_time=$(date +%s)
            _fail "pnpm 글로벌 패키지 업데이트" "$((pnpm_end_time - pnpm_start_time))"
        fi
        
        if grep -q "Ignored build scripts" "$pnpm_log"; then
            pnpm_warning_detected=1
        fi
        
        rm "$pnpm_log"
        
    else
        _skip "pnpm이 설치되어 있지 않습니다."
    fi

    # --- 9. System Apps (Winget & Choco) ---
    
    # Winget
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
    
    # Chocolatey
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

    # --- 최종 요약 ---
    _log "⏱️ 작업별 소요 시간 요약"
    
    for summary in "${task_summaries[@]}"; do
        printf "  %s\n" "$summary"
    done

    local end_ts
    end_ts=$(date +%s)
    _log "✅ 모든 작업 완료! (총 소요 시간: $((end_ts - start_ts))초)"

    # pnpm 경고가 감지되었을 경우 알림 메시지 출력
    if [ $pnpm_warning_detected -eq 1 ]; then
        printf "\n"
        printf "  💡 pnpm 경고 알림\n"
        printf "    로그에서 \"Ignored build scripts\"가 감지되었습니다.\n"
        printf "    터미널에 'pnpm approve-builds -g'를 직접 실행하여\n"
        printf "    신뢰하는 패키지의 빌드 스크립트를 승인해 주세요.\n"
    fi

    # Bun 전역 postinstall 차단이 있었던 경우 안내
    if [ $bun_untrusted_detected -eq 1 ]; then
        printf "\n"
        printf "  💡 Bun 전역 postinstall 안내\n"
        printf "    이번 실행에서 'bun pm -g trust --all'이 자동으로 실행되었습니다.\n"
        printf "    전역 패키지 보안 정책을 더 세밀하게 관리하고 싶다면,\n"
        printf "    개별 패키지 단위로 'bun pm -g trust <패키지명>'을 사용하는 것도 고려해 보세요.\n"
    fi

    # 셸 환경을 깨끗하게 유지하기 위해 헬퍼 함수들 삭제
    unset -f _log _ok _skip _fail _has _run task_summaries
}
