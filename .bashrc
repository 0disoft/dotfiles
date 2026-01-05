#################################################################
# 1-Click Developer Tool Updater Function (dev-up)
#################################################################

dev-up() {
  # 서브쉘로 실행하여 네임스페이스 오염 방지 (trap/unset 불필요)
  (
    set -uo pipefail

    # 임시 파일 정리용 trap (EXIT로 모든 종료 시 정리 보장)
    local -a temp_files=()
    trap 'rm -f "${temp_files[@]}" 2>/dev/null' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    local -a task_summaries=()
    local -a version_changes=()
    local overall_rc=0

    # -----------------------------------------------------------
    # Helper Functions
    # -----------------------------------------------------------
    _log()  { printf "\n==> %s\n" "$*"; }
    _ok()   { printf "  ✓ %s\n" "$1"; task_summaries+=("✓ $1: ${2}s"); }
    _skip() { printf "  ... %s (skipping)\n" "$*"; task_summaries+=("... $*: SKIPPED"); }
    _fail() { printf "  ✗ %s (FAILED)\n" "$1"; task_summaries+=("✗ $1: ${2}s (FAILED)"); }
    _has()  { command -v "$1" >/dev/null 2>&1; }

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
        overall_rc=1
        return 1
      fi
    }

    _ver1() {
      local out
      out=$("$@" 2>&1 | tr -d '\r' | head -n 1)
      printf '%s' "$out"
    }

    _record_change() {
      local prefix="$1" name="$2" before="$3" after="$4"
      if [ -z "$before" ] && [ -n "$after" ]; then
        version_changes+=("${prefix} ${name} (없음) -> ${after}")
      elif [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
        version_changes+=("${prefix} ${name} ${before} -> ${after}")
      fi
    }

    _summary_globals_enabled() {
      local v="${DEV_UP_SUMMARY_GLOBALS:-1}"
      if ! printf '%s' "$v" | grep -Eq '^[0-9]+$'; then v=1; fi
      [ "$v" -ne 0 ]
    }

    _state_dir() {
      printf '%s\n' "${DEV_UP_STATE_DIR:-$HOME/.cache/dev-up}"
    }

    _npm_global_update_due() {
      if [ "${DEV_UP_NPM_GLOBAL_FORCE:-0}" -eq 1 ]; then return 0; fi
      local interval_days="${DEV_UP_NPM_GLOBAL_INTERVAL_DAYS:-7}"
      if ! printf '%s' "$interval_days" | grep -Eq '^[0-9]+$'; then interval_days=7; fi

      local sd stamp now last interval
      sd="$(_state_dir)"
      mkdir -p "$sd" >/dev/null 2>&1 || true
      stamp="${sd}/npm-global-update.ts"
      now=$(date +%s)
      interval=$((interval_days * 86400))

      if [ ! -f "$stamp" ]; then return 0; fi
      last=$(cat "$stamp" 2>/dev/null | tr -d '\r\n' || true)
      if ! printf '%s' "$last" | grep -Eq '^[0-9]+$'; then return 0; fi
      if [ $((now - last)) -ge "$interval" ]; then return 0; fi
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
      local pkg="$1" out=""
      if ! _has npm; then return 0; fi
      if ! _has_timeout_gnu; then return 0; fi
      out=$(timeout 5 npm view "$pkg" version 2>/dev/null | tr -d '\r\n' || true)
      if printf '%s' "$out" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
        printf '%s' "$out"
      fi
    }

    _bun_global_node_modules() {
      local bin_g
      bin_g=$(bun pm bin -g 2>/dev/null | tr -d '\r\n' || true)
      if [ -n "$bin_g" ]; then
        bin_g=$(cygpath -u "$bin_g" 2>/dev/null || printf '%s' "$bin_g")
        printf '%s/install/global/node_modules\n' "$(dirname "$bin_g")"
        return 0
      fi
      if [ -n "${APPDATA:-}" ]; then
        local appdata_path
        appdata_path=$(cygpath -u "$APPDATA" 2>/dev/null || printf '%s' "$APPDATA")
        if [ -d "${appdata_path}/.bun/install/global/node_modules" ]; then
          printf '%s/.bun/install/global/node_modules\n' "$appdata_path"
          return 0
        fi
      fi
      printf '%s/.bun/install/global/node_modules\n' "$HOME"
    }

    _bun_global_pkg_version() {
      local pkg="$1" nm pj line ver
      nm=$(_bun_global_node_modules)
      pj="${nm}/${pkg}/package.json"
      [ -f "$pj" ] || return 0
      line=$(grep -m1 '"version"' "$pj" 2>/dev/null || true)
      ver=$(printf '%s\n' "$line" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
      printf '%s' "$ver"
    }

    _ensure_bun_global_pinned() {
      local label="$1" pkg="$2" target="$3"
      local installed
      installed=$(_bun_global_pkg_version "$pkg")
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
        base=$(basename "$d")
        [[ "$base" == .* ]] && continue
        if [ "${base#@}" != "$base" ]; then
          while IFS= read -r s; do
            sbase=$(basename "$s")
            [[ "$sbase" == .* ]] && continue
            printf '%s/%s\n' "$base" "$sbase"
          done < <(find "$d" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
        else
          printf '%s\n' "$base"
        fi
      done < <(find "$nm" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
    }

    _bun_snapshot_globals() {
      local nm="$1" out_file="$2"
      : > "$out_file"
      [ -d "$nm" ] || return 0
      local pkg pj ver line
      while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        pj="${nm}/${pkg}/package.json"
        ver="unknown"
        if [ -f "$pj" ]; then
          line=$(grep -m1 '"version"' "$pj" 2>/dev/null || true)
          ver=$(printf '%s\n' "$line" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
          [ -n "$ver" ] || ver="unknown"
        fi
        printf '%s\t%s\n' "$pkg" "$ver" >> "$out_file"
      done < <(_bun_list_globals "$nm" | sort)
    }

    _append_version_changes_from_files() {
      local before_file="$1" after_file="$2" prefix="$3"
      local -A before=() after=()
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
        local b="${before[$name]:-}" a="${after[$name]:-}"
        if [ -n "$a" ] && [ "$a" != "unknown" ]; then
          if [ -z "$b" ] || [ "$b" = "unknown" ]; then
            version_changes+=("${prefix} ${name} (없음) -> ${a}")
          elif [ "$b" != "$a" ]; then
            version_changes+=("${prefix} ${name} ${b} -> ${a}")
          fi
        fi
      done
    }

    _npm_snapshot_globals() {
      local out_file="$1"
      : > "$out_file"
      _has npm || return 0
      _has node || return 0
      local json
      json=$(npm ls -g --depth 0 --json 2>/dev/null | tr -d '\r' || true)
      [ -n "$json" ] || return 0
      printf '%s' "$json" | node -e 'const fs=require("fs");const input=fs.readFileSync(0,"utf8").trim();if(!input)process.exit(0);let data;try{data=JSON.parse(input);}catch(e){process.exit(0);}const deps=(data&&data.dependencies)||{};for(const [name,info] of Object.entries(deps)){if(info&&info.version){process.stdout.write(`${name}\t${info.version}\n`);}}' 2>/dev/null > "$out_file" || true
    }

    _pnpm_snapshot_globals() {
      local out_file="$1"
      local line pkgver pkg ver
      : > "$out_file"
      _has pnpm || return 0

      if _has node; then
        local json
        json=$(pnpm list -g --depth 0 --json 2>/dev/null | tr -d '\r' || true)
        if [ -n "$json" ]; then
          printf '%s' "$json" | node -e 'const fs=require("fs");const input=fs.readFileSync(0,"utf8").trim();if(!input)process.exit(0);let data;try{data=JSON.parse(input);}catch(e){process.exit(0);}const nodes=Array.isArray(data)?data:[data];for(const node of nodes){const deps=(node&&node.dependencies)||{};for(const [name,info] of Object.entries(deps)){if(info&&info.version){process.stdout.write(`${name}\t${info.version}\n`);}}}' 2>/dev/null > "$out_file" || true
          [ -s "$out_file" ] && return 0
          : > "$out_file"
        fi
      fi

      pnpm list -g --depth 0 2>/dev/null | tr -d '\r' | while IFS= read -r line; do
        if [[ "$line" =~ ([^[:space:]]+@[^[:space:]]+)$ ]]; then
          pkgver="${BASH_REMATCH[1]}"
          pkg="${pkgver%@*}"
          ver="${pkgver##*@}"
          printf '%s\t%s\n' "$pkg" "$ver"
        fi
      done >> "$out_file"
    }

    _append_uv_changes_from_log() {
      local log="$1" prefix="${2:-[uv]}"
      [ -f "$log" ] || return 0
      local -A old=()
      local line pkg ver
      while IFS= read -r line; do
        line=$(printf '%s' "$line" | tr -d '\r')
        if [[ "$line" =~ -[[:space:]]*([A-Za-z0-9._+-]+)==([^[:space:]]+) ]]; then
          pkg="${BASH_REMATCH[1]}"
          ver="${BASH_REMATCH[2]}"
          old["$pkg"]="$ver"
        elif [[ "$line" =~ ^[[:space:]]*\\+[[:space:]]*([A-Za-z0-9._+-]+)==([^[:space:]]+) ]]; then
          pkg="${BASH_REMATCH[1]}"
          ver="${BASH_REMATCH[2]}"
          if [ -n "${old[$pkg]:-}" ]; then
            if [ "${old[$pkg]}" != "$ver" ]; then
              version_changes+=("${prefix} ${pkg} ${old[$pkg]} -> ${ver}")
            fi
          else
            version_changes+=("${prefix} ${pkg} (없음) -> ${ver}")
          fi
        fi
      done < "$log"
    }

    _bun_check_and_trust_allowlist() {
      local bun_global_nm="$1" parent_pkg="$2"
      shift 2
      local -a allowlist=("$@")
      local pkg_dir="${bun_global_nm}/${parent_pkg}"
      [ -d "$pkg_dir" ] || return 0
      local out
      out=$(cd "$pkg_dir" 2>/dev/null && bun pm untrusted 2>/dev/null || true)
      [ -z "$out" ] && return 0
      local -a to_trust=()
      local dep
      for dep in "${allowlist[@]}"; do
        if printf '%s\n' "$out" | grep -Eq "(\\\\|/)node_modules(\\\\|/)${dep}(\\\\|/)" || \
           printf '%s\n' "$out" | grep -Eq "(^|[[:space:]])${dep}([[:space:]]|$)"; then
          to_trust+=("$dep")
        fi
      done
      if [ "${#to_trust[@]}" -gt 0 ]; then
        bun_untrusted_detected=1
        _run "Bun trust (${parent_pkg})" bash -c "cd '${pkg_dir}' && bun pm trust ${to_trust[*]}"
      fi
    }

    _winget_upgrade_capture() {
      local id="$1"
      local winget_cmd="winget"
      if ! _has winget; then
        # 동적 경로 탐색 (SystemRoot 환경변수 활용, C: 외 다른 드라이브 지원)
        local system32_path
        system32_path=$(cygpath -u "${SystemRoot:-C:\Windows}\System32" 2>/dev/null || echo "/c/Windows/System32")
        if [[ -x "${system32_path}/winget.exe" ]]; then
          winget_cmd="${system32_path}/winget.exe"
        else
          printf "winget을 찾을 수 없습니다.\n"
          return 1
        fi
      fi
      local winget_opts=(--accept-source-agreements --accept-package-agreements --disable-interactivity --silent)
      if _has winpty && [[ -n "${MSYSTEM:-}" ]]; then
        winpty -Xallow-non-tty "$winget_cmd" upgrade --id "$id" -e "${winget_opts[@]}" 2>&1
      else
        "$winget_cmd" upgrade --id "$id" -e "${winget_opts[@]}" 2>&1
      fi
    }

    _run_winget_upgrade() {
      local title="$1" id="$2"
      _log "$title"
      local start_time end_time duration
      start_time=$(date +%s)

      local output rc
      output=$(_winget_upgrade_capture "$id")
      rc=$?
      [ -n "$output" ] && printf "%s\n" "$output"

      if printf '%s\n' "$output" | tr -d '\r' | grep -Eq "사용 가능한 업그레이드를 찾을 수 없습니다|구성된 원본에서 사용할 수 있는 최신 패키지 버전이 없습니다|No available upgrade|No applicable update|No installed package found matching input criteria"; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        _skip "${title} (업데이트 없음)"
        return 0
      fi

      if [ "$rc" -eq 0 ]; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        _ok "$title" "$duration"
        return 0
      else
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        _fail "$title" "$duration"
        overall_rc=1
        return 1
      fi
    }

    _run_corepack_enable_pnpm() {
      local title="Corepack enable pnpm"
      _log "$title"
      local start_time end_time duration
      start_time=$(date +%s)

      local output rc
      output=$(corepack enable pnpm 2>&1)
      rc=$?
      [ -n "$output" ] && printf "%s\n" "$output"

      if [ "$rc" -eq 0 ]; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        _ok "$title" "$duration"
        return 0
      fi

      if printf '%s\n' "$output" | tr -d '\r' | grep -Eq "EPERM|EACCES|Access is denied|operation not permitted|Permission denied"; then
        local install_dir="${DEV_UP_COREPACK_DIR:-$HOME/.local/bin}"
        mkdir -p "$install_dir" >/dev/null 2>&1 || true
        local output2 rc2
        output2=$(corepack enable pnpm --install-directory "$install_dir" 2>&1)
        rc2=$?
        [ -n "$output2" ] && printf "%s\n" "$output2"
        if [ "$rc2" -eq 0 ]; then
          corepack_fallback_used=1
          corepack_fallback_dir="$install_dir"
          export PATH="$install_dir:$PATH"
          end_time=$(date +%s)
          duration=$((end_time - start_time))
          _ok "${title} (fallback: ${install_dir})" "$duration"
          return 0
        fi
      fi

      end_time=$(date +%s)
      duration=$((end_time - start_time))
      _fail "$title" "$duration"
      overall_rc=1
      return 1
    }

    # -----------------------------------------------------------
    # Main Logic
    # -----------------------------------------------------------
    local pnpm_warning_detected=0
    local bun_untrusted_detected=0
    local corepack_fallback_used=0
    local corepack_fallback_dir=""
    local start_ts
    start_ts=$(date +%s)

    # 1. Deno
    if _has deno; then
      local deno_before deno_after
      deno_before=$(_ver1 deno --version)
      _run "Deno 업그레이드" deno upgrade
      deno_after=$(_ver1 deno --version)
      _record_change "[tool]" "deno" "$deno_before" "$deno_after"
    else
      _skip "Deno가 설치되어 있지 않습니다."
    fi

    # 2. Bun
    if _has bun; then
      local bun_before_runtime bun_after_runtime
      bun_before_runtime=$(_ver1 bun --version)
      _run "Bun 런타임 업그레이드" bun upgrade
      bun_after_runtime=$(_ver1 bun --version)
      _record_change "[tool]" "bun" "$bun_before_runtime" "$bun_after_runtime"

      local bun_global_nm="" bun_before="" bun_after=""
      if _summary_globals_enabled; then
        bun_global_nm=$(_bun_global_node_modules)
        bun_before=$(mktemp)
        bun_after=$(mktemp)
        temp_files+=("$bun_before" "$bun_after")

        _bun_snapshot_globals "$bun_global_nm" "$bun_before"
      fi

      _run "Bun 글로벌 패키지 업데이트" bun update -g

      local codex_latest gemini_latest
      codex_latest=$(_npm_view_version "@openai/codex")
      if [ -n "$codex_latest" ]; then
        _ensure_bun_global_pinned "Codex CLI" "@openai/codex" "$codex_latest"
      else
        _run "Codex CLI 설치 (@openai/codex@latest)" bun install -g "@openai/codex@latest"
      fi

      gemini_latest=$(_npm_view_version "@google/gemini-cli")
      if [ -n "$gemini_latest" ]; then
        _ensure_bun_global_pinned "Gemini CLI" "@google/gemini-cli" "$gemini_latest"
      else
        _run "Gemini CLI 설치 (@google/gemini-cli@latest)" bun install -g "@google/gemini-cli@latest"
      fi

      if [ "${DEV_UP_BUN_FORCE_LATEST_ALL:-0}" -eq 1 ]; then
        if [ -z "$bun_global_nm" ]; then
          bun_global_nm=$(_bun_global_node_modules)
        fi
        if [ -z "$bun_before" ]; then
          bun_before=$(mktemp)
          bun_after=$(mktemp)
          temp_files+=("$bun_before" "$bun_after")
          _bun_snapshot_globals "$bun_global_nm" "$bun_before"
        fi

        if [ "${DEV_UP_BUN_FORCE_LATEST_COLD:-0}" -eq 1 ]; then
          _log "Bun 캐시 정리"
          bun pm cache rm >/dev/null 2>&1 || rm -rf "${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}" >/dev/null 2>&1 || true
        fi

        _log "Bun 전역 패키지 최신 강제 설치"
        local force_start force_end force_ok
        local -a failed_pkgs=()
        force_start=$(date +%s)
        force_ok=1

        local pkg latest
        while IFS= read -r pkg; do
          [ -n "$pkg" ] || continue
          if [ "${DEV_UP_BUN_FORCE_LATEST_NPM:-0}" -eq 1 ]; then
            latest=$(_npm_view_version "$pkg")
            if [ -n "$latest" ]; then
              bun install -g "${pkg}@${latest}" >/dev/null 2>&1 || { force_ok=0; failed_pkgs+=("$pkg"); }
            else
              bun install -g "${pkg}@latest" >/dev/null 2>&1 || { force_ok=0; failed_pkgs+=("$pkg"); }
            fi
          else
            bun install -g "${pkg}@latest" >/dev/null 2>&1 || { force_ok=0; failed_pkgs+=("$pkg"); }
          fi
        done < <(_bun_list_globals "$bun_global_nm" | sort)

        force_end=$(date +%s)
        if [ "$force_ok" -eq 1 ]; then
          _ok "Bun 전역 패키지 최신 강제 설치" "$((force_end - force_start))"
        else
          _fail "Bun 전역 패키지 최신 강제 설치" "$((force_end - force_start))"
          printf "    실패한 패키지: %s\n" "${failed_pkgs[*]}"
        fi
      else
        _skip "Bun 전역 패키지 최신 강제 설치 (DEV_UP_BUN_FORCE_LATEST_ALL=1 로 활성화)"
      fi

      if [ -n "$bun_before" ]; then
        _bun_snapshot_globals "$bun_global_nm" "$bun_after"
        _append_version_changes_from_files "$bun_before" "$bun_after" "[bun]"
      fi

      [ -z "$bun_global_nm" ] && bun_global_nm=$(_bun_global_node_modules)
      
      # Bun trust allowlist (환경변수로 확장 가능: DEV_UP_BUN_TRUST_ALLOWLIST_WRANGLER, DEV_UP_BUN_TRUST_ALLOWLIST_VERCEL)
      local -a wrangler_allowlist=(${DEV_UP_BUN_TRUST_ALLOWLIST_WRANGLER:-esbuild workerd})
      local -a vercel_allowlist=(${DEV_UP_BUN_TRUST_ALLOWLIST_VERCEL:-esbuild sharp})
      
      [ -d "$bun_global_nm/wrangler" ] && _bun_check_and_trust_allowlist "$bun_global_nm" "wrangler" "${wrangler_allowlist[@]}"
      [ -d "$bun_global_nm/vercel" ] && _bun_check_and_trust_allowlist "$bun_global_nm" "vercel" "${vercel_allowlist[@]}"
      [ "$bun_untrusted_detected" -eq 0 ] && _ok "Bun postinstall 차단 검사 (주요 툴 기준)" 0
    else
      _skip "Bun이 설치되어 있지 않습니다."
    fi

    # 3. Rust
    if _has rustup; then
      local rust_before="" rust_after=""
      _has rustc && rust_before=$(_ver1 rustc --version)
      _run "Rust Toolchain 업데이트" rustup update
      _has rustc && rust_after=$(_ver1 rustc --version)
      _record_change "[tool]" "rustc" "$rust_before" "$rust_after"
    else
      _skip "rustup이 설치되어 있지 않습니다."
    fi

    # 4. Julia
    if _has juliaup; then
      local julia_before="" julia_after=""
      _has julia && julia_before=$(_ver1 julia --version)
      _run "Juliaup 자체 업데이트" juliaup self update
      _run "Julia 채널 업데이트" juliaup update
      _has julia && julia_after=$(_ver1 julia --version)
      _record_change "[tool]" "julia" "$julia_before" "$julia_after"
    else
      _skip "Juliaup이 설치되어 있지 않습니다."
    fi

    # 5. Flutter
    if _has flutter; then
      local flutter_before flutter_after
      flutter_before=$(_ver1 flutter --version)
      _run "Flutter SDK 업그레이드" flutter upgrade
      flutter_after=$(_ver1 flutter --version)
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
      local uv_before uv_after uv_path uv_is_pip=0
      uv_before=$(_ver1 uv --version)
      uv_path=$(command -v uv 2>/dev/null || true)
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
      if _summary_globals_enabled; then
        local uv_tool_log
        uv_tool_log=$(mktemp)
        temp_files+=("$uv_tool_log")
        _run "uv 글로벌 도구 전체 업그레이드" bash -c "set -o pipefail; uv tool upgrade --all 2>&1 | tee \"$uv_tool_log\""
        _append_uv_changes_from_log "$uv_tool_log" "[uv]"
      else
        _run "uv 글로벌 도구 전체 업그레이드" uv tool upgrade --all
      fi
      uv_after=$(_ver1 uv --version)
      _record_change "[tool]" "uv" "$uv_before" "$uv_after"
    else
      _skip "uv가 설치되어 있지 않습니다."
    fi

    if [ -n "$python_cmd" ]; then
      local pip_before pip_after
      pip_before=$("$python_cmd" -m pip --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
      # Windows pip 업데이트는 권한/잠금 문제로 실패할 수 있으므로 실패 무시
      _run "Python pip 업그레이드 (via $python_cmd)" "$python_cmd" -m pip install --upgrade pip || true
      pip_after=$("$python_cmd" -m pip --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
      _record_change "[tool]" "pip" "$pip_before" "$pip_after"
    fi

    # 7. Node.js Ecosystem
    if _has npm; then
      local npm_before npm_after
      npm_before=$(_ver1 npm -v)
      if ! _run "npm 자체 업데이트" npm install -g npm@latest --no-fund --no-audit; then
        printf "    💡 Windows에서 npm 업데이트 실패 시: npm-windows-upgrade 사용 권장\n"
      fi
      npm_after=$(_ver1 npm -v)
      _record_change "[tool]" "npm" "$npm_before" "$npm_after"

      if _npm_global_update_due; then
        local npm_pkgs_before="" npm_pkgs_after=""
        if _summary_globals_enabled; then
          npm_pkgs_before=$(mktemp)
          npm_pkgs_after=$(mktemp)
          temp_files+=("$npm_pkgs_before" "$npm_pkgs_after")
          _npm_snapshot_globals "$npm_pkgs_before"
        fi

        if _run "npm 글로벌 패키지 업데이트 (7일 주기)" npm update -g --no-fund --no-audit; then
          _npm_global_update_stamp
        fi

        if [ -n "$npm_pkgs_before" ]; then
          _npm_snapshot_globals "$npm_pkgs_after"
          _append_version_changes_from_files "$npm_pkgs_before" "$npm_pkgs_after" "[npm]"
        fi
      else
        _skip "npm 글로벌 패키지 업데이트 (7일 주기 미도래)"
      fi
    else
      _skip "npm이 설치되어 있지 않습니다."
    fi

    if _has corepack; then
      _run_corepack_enable_pnpm
      _run "Corepack (pnpm@latest 활성화)" corepack prepare pnpm@latest --activate
    else
      _skip "Corepack이 설치되어 있지 않습니다."
    fi

    # 8. pnpm
    if _has pnpm; then
      local pnpm_start_time pnpm_log pnpm_exit_code pnpm_before pnpm_after
      pnpm_start_time=$(date +%s)
      pnpm_log=$(mktemp)
      temp_files+=("$pnpm_log")

      if _summary_globals_enabled; then
        pnpm_before=$(mktemp)
        pnpm_after=$(mktemp)
        temp_files+=("$pnpm_before" "$pnpm_after")
        _pnpm_snapshot_globals "$pnpm_before"
      fi

      pnpm update -g --latest 2>&1 | tee "$pnpm_log"
      pnpm_exit_code=${PIPESTATUS[0]}

      if [[ $pnpm_exit_code -eq 0 ]]; then
        _ok "pnpm 글로벌 패키지 업데이트" "$(( $(date +%s) - pnpm_start_time ))"
      else
        _fail "pnpm 글로벌 패키지 업데이트" "$(( $(date +%s) - pnpm_start_time ))"
      fi

      if grep -Fq "Ignored build scripts" "$pnpm_log" 2>/dev/null; then
        pnpm_warning_detected=1
      fi

      if [ -n "${pnpm_before:-}" ]; then
        _pnpm_snapshot_globals "$pnpm_after"
        _append_version_changes_from_files "$pnpm_before" "$pnpm_after" "[pnpm]"
      fi
    else
      _skip "pnpm이 설치되어 있지 않습니다."
    fi

    # 9. Winget
    if _has winget || [[ -x "/c/Windows/System32/winget.exe" ]]; then
      _run_winget_upgrade "Winget (GitHub CLI) 업그레이드" "GitHub.cli"
      _run_winget_upgrade "Winget (Starship) 업그레이드" "Starship.Starship"
    else
      _skip "Winget이 설치되어 있지 않습니다."
    fi

    # 10. Chocolatey (관리자 권한 필요)
    if _has choco; then
      _log "Chocolatey 패키지 업그레이드"
      printf "    💡 Chocolatey는 관리자 권한이 필요합니다. 실패 시 'Git Bash (Admin)'로 재시도하세요.\n"
      if choco upgrade chocolatey -y; then
        _ok "Choco (Self)" 0
      else
        _fail "Choco (Self) 실패" 0
        overall_rc=1
      fi
      if choco upgrade dart-sdk -y; then
        _ok "Choco (Dart SDK)" 0
      else
        _fail "Choco (Dart SDK) 실패" 0
        overall_rc=1
      fi
    else
      _skip "Chocolatey가 설치되어 있지 않습니다."
    fi

    # 요약 출력
    _log "⏱️ 작업별 소요 시간 요약"
    if [[ ${#task_summaries[@]} -gt 0 ]]; then
      for summary in "${task_summaries[@]}"; do
        printf "  %s\n" "$summary"
      done
    else
      printf "  실행된 작업 없음\n"
    fi

    local end_ts
    end_ts=$(date +%s)
    _log "✅ 모든 작업 완료! (총 소요 시간: $((end_ts - start_ts))초)"

    [ "$pnpm_warning_detected" -eq 1 ] && printf "\n  💡 pnpm 경고: 'pnpm approve-builds -g' 확인 필요\n"
    [ "$bun_untrusted_detected" -eq 1 ] && printf "\n  💡 Bun 경고: untrusted lifecycle scripts 감지됨\n"
    [ "$corepack_fallback_used" -eq 1 ] && printf "\n  💡 Corepack: fallback install dir 사용됨 (%s) — PATH에 추가 필요할 수 있음\n" "$corepack_fallback_dir"

    printf "\n"
    if [ "${#version_changes[@]}" -gt 0 ]; then
      _log "⬆️ 이번 실행에서 버전이 바뀐 것들"
      for vc in "${version_changes[@]}"; do
        printf "  %s\n" "$vc"
      done
    else
      _log "⬆️ 이번 실행에서 버전 변경 없음"
    fi

    # 임시 파일 정리 후 종료 코드 반환
    rm -f "${temp_files[@]}" 2>/dev/null
    exit $overall_rc
  )
}

# Ensure Corepack fallback bin is on PATH (used when corepack enable hits EPERM)
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
