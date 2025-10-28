eval "$(starship init bash)"

#################################################################
# 1-Click Developer Tool Updater Function (dev-up)
#################################################################

function dev-up() {
    # 스크립트 실행 중 오류가 발생해도 계속 진행하되,
    # 파이프 실패(-o pipefail)나 선언되지 않은 변수(-u) 사용은 막습니다.
    set -uo pipefail

    # --- 로그 헬퍼 함수 ---
    _log()  { printf "\n==> %s\n" "$*"; }
    _ok()   { printf "  ✓ %s\n" "$*"; }
    _skip() { printf "  ... %s (skipping)\n" "$*"; }
    _fail() { printf "  ✗ %s (FAILED)\n" "$*"; }
    _has()  { command -v "$1" >/dev/null 2>&1; }

    # --- 실행 래퍼 함수 ---
    _run() {
        local title="$1"; shift
        _log "$title"
        if "$@"; then
            _ok "$title"
        else
            _fail "$title"
        fi
    }

    # 시작 시간 기록
    local start_ts=$(date +%s)

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
        # 'corepack enable'은 실행하지 않음 (권한 문제 및 불필요)
        _run "Corepack (pnpm@latest 설정)" corepack use pnpm@latest
    else
        _skip "Corepack이 설치되어 있지 않습니다."
    fi

    # --- 7. pnpm Global Packages ---
    if _has pnpm; then
        _run "pnpm 글로벌 패키지 업데이트" pnpm update -g --latest
    else
        _skip "pnpm이 설치되어 있지 않습니다."
    fi

    # --- 8. Winget Packages (신규 추가) ---
    if _has winget; then
        _log "Winget 패키지 업그레이드 (관리자 권한 필요할 수 있음)"
        
        # winget 실행 시 라이선스 동의 프롬프트를 자동으로 수락합니다.
        _run "Winget (GitHub CLI) 업그레이드" winget upgrade --id GitHub.cli --accept-source-agreements --accept-package-agreements
        
        _run "Winget (Starship) 업그레이드" winget upgrade --id Starship.Starship --accept-source-agreements --accept-package-agreements
        
    else
        _skip "Winget이 설치되어 있지 않습니다."
    fi


    # 종료 시간 및 총 실행 시간 계산
    local end_ts=$(date +%s)
    _log "✅ 모든 작업 완료! (총 소요 시간: $((end_ts - start_ts))초)"

    # 셸 환경을 깨끗하게 유지하기 위해 헬퍼 함수들 삭제
    unset -f _log _ok _skip _fail _has _run
}