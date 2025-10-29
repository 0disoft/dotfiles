# ---------------------------------------------------------------
# Starship Prompt (스타쉽 프롬프트 활성화)
# ---------------------------------------------------------------
# 참고: 이 라인은 dev-up 함수보다 '먼저' 실행되어야 합니다.
eval "$(starship init bash)"


#################################################################
# 1-Click Developer Tool Updater Function (dev-up)
# (dev-up 함수 정의)
#################################################################

function dev-up() {
    set -uo pipefail

    # --- 로그 헬퍼 함수 ---
    _log()  { printf "\n==> %s\n" "$*"; }
    _ok()   { printf "  ✓ %s\n" "$*"; }
    _skip() { printf "  ... %s (skipping)\n" "$*"; }
    _fail() { printf "  ✗ %s (FAILED)\n" "$*"; }
    _has()  { command -v "$1" >/dev/null 2>&1; }

    # --- 실행 래퍼 함수 (pnpm, winget 제외) ---
    _run() {
        local title="$1"; shift
        _log "$title"
        if "$@"; then
            _ok "$title"
        else
            _fail "$title"
        fi
    }

    # pnpm 경고를 추적하기 위한 플래그
    local pnpm_warning_detected=0
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
        _run "Bun 업그레이드" bun upgrade
    else
        _skip "Bun이 설치되어 있지 않습니다."
    fi

    # --- 3. Python pip ---
    if _has py; then
        _run "Python pip 업그레이드 (via py)" py -m pip install --upgrade pip
    elif _has python; then
        _run "Python pip 업그레이드 (via python)" python -m pip install --upgrade pip
    else
        _skip "Python (pip)이 설치되어 있지 않습니다."
    fi

    # --- 4. uv ---
    if _has py; then
        _run "uv 업그레이드 (via py)" py -m pip install --upgrade uv
    elif _has python; then
        _run "uv 업그레이드 (via python)" python -m pip install --upgrade uv
    else
        _skip "uv (pip)가 설치되어 있지 않습니다."
    fi

    # --- 5. Rust ---
    if _has rustup; then
        _run "Rust Toolchain 업데이트" rustup update
    else
        _skip "rustup이 설치되어 있지 않습니다."
    fi

    # --- 6. Corepack (pnpm) ---
    if _has corepack; then
        _run "Corepack (pnpm@latest 설정)" corepack use pnpm@latest
    else
        _skip "Corepack이 설치되어 있지 않습니다."
    fi

    # --- 7. pnpm Global Packages (경고 감지 로직 추가) ---
    if _has pnpm; then
        _log "pnpm 글로벌 패키지 업데이트"
        
        # 임시 로그 파일 생성
        local pnpm_log
        pnpm_log=$(mktemp)

        # 'tee'로 실시간 출력과 파일 저장을 동시에 수행
        if pnpm update -g --latest 2>&1 | tee "$pnpm_log"; then
            _ok "pnpm 글로벌 패키지 업데이트"
        else
            _fail "pnpm 글로벌 패키지 업데이트"
        fi
        
        # 로그 파일에서 경고 문구 확인
        if grep -q "Ignored build scripts" "$pnpm_log"; then
            pnpm_warning_detected=1 # 경고 플래그 설정
        fi
        
        # 임시 로그 파일 삭제
        rm "$pnpm_log"
        
    else
        _skip "pnpm이 설치되어 있지 않습니다."
    fi

    # --- 8. Winget Packages (실패 처리 로직 수정) ---
    if _has winget; then
        _log "Winget 패키지 업그레이드 (관리자 권한 필요할 수 있음)"
        
        _log "Winget (GitHub CLI) 업그레이드"
        if winget upgrade --id GitHub.cli --accept-source-agreements --accept-package-agreements; then
            _ok "WingGeta (GitHub CLI) 업그레이드"
        else
            _ok "Winget (GitHub CLI) 업그레이드 (업데이트 없음)"
        fi
        
        _log "Winget (Starship) 업그레이드"
        if winget upgrade --id Starship.Starship --accept-source-agreements --accept-package-agreements; then
            _ok "Winget (Starship) 업그레이드"
        else
            _ok "Winget (Starship) 업그레이드 (업데이트 없음)"
        fi
        
    else
        _skip "Winget이 설치되어 있지 않습니다."
    fi


    # --- 최종 요약 ---
    local end_ts
    end_ts=$(date +%s)
    _log "✅ 모든 작업 완료! (총 소요 시간: $((end_ts - start_ts))초)"

    # pnpm 경고가 감지되었을 경우 알림 메시지 출력
    if [ $pnpm_warning_detected -eq 1 ]; then
        printf "\n"
        printf "  💡 **pnpm 경고 알림** 💡\n"
        printf "     로그에서 \"Ignored build scripts\"가 감지되었습니다.\n"
        printf "     터미널에 'pnpm approve-builds -g'를 직접 실행하여\n"
        printf "     신뢰하는 패키지의 빌드 스크립트를 승인해 주세요.\n"
    fi

    # 셸 환경을 깨끗하게 유지하기 위해 헬퍼 함수들 삭제
    unset -f _log _ok _skip _fail _has _run
}