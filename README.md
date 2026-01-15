# 🚀 Dev-Up: 통합 개발 환경 원클릭 업데이트

Dev-Up은 Git Bash 환경에서 자주 쓰는 런타임, 패키지 매니저, 시스템 도구 업데이트를 한 번에 돌려주는 함수입니다.
dev-up 한 줄로 업데이트 체인을 굴리고, 마지막에 성공 실패와 소요 시간, 버전 변경 목록을 정리해 보여줍니다.

## 주요 기능

* 설치된 도구만 자동 감지해서, 있는 것만 업데이트합니다
* 작업별 소요 시간과 성공 실패를 요약합니다
* 이번 실행에서 버전이 바뀐 항목만 따로 모아서 보여줍니다
* 전역 패키지 변경 요약은 기본 비활성화 (필요 시 DEV_UP_SUMMARY_GLOBALS=1)

업데이트 대상 요약

* Bun
  * bun upgrade
  * bun update -g
  * codex, gemini-cli는 미설치 시만 설치
  * bun 전역 postinstall 차단 감지 후 allowlist 방식 trust
* Node.js
  * npm 자체 업데이트 (3일 주기)
  * npm 전역 업데이트는 7일에 한 번만 자동 실행
  * Corepack으로 pnpm 최신 활성화 (`corepack prepare pnpm@latest --activate`)
  * pnpm 전역 패키지 업데이트
* Rust: rustup update
* Python: pip 업데이트, uv 업데이트는 설치 방식에 따라 자동 분기
* Deno, Flutter, Julia: 각 런타임 및 SDK 업데이트
* Windows 시스템: Winget, Chocolatey 업데이트

## 기술적 특성

* **서브쉘 구조**: 네임스페이스 오염 방지, 강제 종료 시도 안전
* **종료 코드 반환**: 실패 시 `1` 반환으로 자동화 체인/스케줄러 지원
* **임시 파일 정리**: `trap EXIT`로 모든 종료 경로에서 100% 정리 보장

## 업데이트 철학

전역 업데이트는 빠르고 편해야 합니다.
하지만 한 번의 빌드 실패가 전체 체인을 망가뜨리면 자동화가 아니라 폭탄이 됩니다.

그래서 Dev-Up은 아래를 지킵니다.

* bun trust all 자동 실행은 하지 않습니다
* bun은 allowlist 방식으로만 trust를 시도합니다
* node-pty는 자동 trust에서 제외합니다
* uv는 설치 방식이 섞였을 때를 대비해 업그레이드 경로를 분기합니다
* npm 전역 업데이트는 무거워서 7일 주기로 제한합니다
* npm 자체 업데이트도 3일 주기로 제한합니다

## 설치 및 적용 방법

이 스크립트는 Git Bash 설정 파일인 .bashrc에 함수 형태로 등록해서 사용합니다.

1. 설정 파일 열기

```bash
nano ~/.bashrc
```

1. 스크립트 등록: 파일 맨 아래에 dev-up 함수 전체 코드를 붙여넣습니다. Starship 같은 프롬프트 설정이 있다면 그 아래에 배치하는 것을 권장합니다.

1. 적용

```bash
source ~/.bashrc
```

## 사용 방법

```bash
dev-up
```

## codex, gemini-cli 설치 동작

* bun update -g 단계에서 최신 업데이트를 처리합니다
* 이미 설치되어 있으면 추가 설치/재설치를 하지 않습니다
* 미설치일 때만 latest로 설치합니다
* 강제 재설치가 필요하면 수동으로 실행합니다

```bash
bun install -g @openai/codex@latest
bun install -g @google/gemini-cli@latest
```

## 옵션 환경변수

필요할 때만 더 강하게, 더 자주 돌릴 수 있습니다.

### npm 전역 업데이트 주기

* 기본 동작: 7일에 한 번만 npm update -g 실행
* 지금 바로 강제 실행

```bash
DEV_UP_NPM_GLOBAL_FORCE=1 dev-up
```

* 주기 변경

```bash
DEV_UP_NPM_GLOBAL_INTERVAL_DAYS=3 dev-up
```

### npm 자체 업데이트 주기

* 기본 동작: 3일에 한 번만 npm 자체 업데이트 실행
* 지금 바로 강제 실행

```bash
DEV_UP_NPM_SELF_FORCE=1 dev-up
```

* 주기 변경

```bash
DEV_UP_NPM_SELF_INTERVAL_DAYS=7 dev-up
```

### npm 업데이트 상태 파일

주기 관리는 로컬 상태 파일로 기록됩니다.

* 기본 폴더: HOME/.cache/dev-up
* 기본 파일: HOME/.cache/dev-up/npm-global-update.ts
* npm 자체 업데이트 파일: HOME/.cache/dev-up/npm-self-update.ts
* 이 파일을 삭제하면 다음 실행에서 npm 전역 업데이트가 다시 실행됩니다
* 상태 폴더를 바꾸고 싶으면

```bash
DEV_UP_STATE_DIR="$HOME/.cache/my-dev-up" dev-up
```

### 전역 패키지 변경 요약

기본적으로 전역 패키지 요약은 꺼져 있습니다.
전역 패키지 수가 많으면 약간 느려질 수 있습니다.

* 켜기

```bash
DEV_UP_SUMMARY_GLOBALS=1 dev-up
```

### Corepack enable 권한 문제 우회

Windows에서 `corepack enable pnpm`이 권한 오류(EPERM/EACCES/Access denied)로 실패하면,
자동으로 사용자 쓰기 가능한 경로에 fallback 설치를 시도합니다.
기본 fallback 경로는 `$HOME/.local/bin`이며, PATH에 추가되어야 합니다.

* fallback 경로 지정

```bash
DEV_UP_COREPACK_DIR="$HOME/.local/bin" dev-up
```

### bun 전역 패키지 전체 최신 강제

기본 동작은 codex와 gemini-cli만 최신 보장을 합니다.
bun 전역에 설치된 모든 패키지를 최신으로 강제하려면 아래 옵션을 켭니다.

* bun 전역 전체 최신 강제

```bash
DEV_UP_BUN_FORCE_LATEST_ALL=1 dev-up
```

* 캐시까지 비우고 더 강하게

```bash
DEV_UP_BUN_FORCE_LATEST_ALL=1 DEV_UP_BUN_FORCE_LATEST_COLD=1 dev-up
```

* 버전 번호를 npm view로 고정해서 더 확실하게 (정확도는 높고, 느려질 수 있습니다)

```bash
DEV_UP_BUN_FORCE_LATEST_ALL=1 DEV_UP_BUN_FORCE_LATEST_NPM=1 dev-up
```

## npm 전역 업데이트가 느린 이유

npm update -g는 전역 패키지 수가 많을수록 매우 무거워집니다.
한 번에 수백 개가 바뀌면 몇 분이 걸릴 수 있어, Dev-Up은 기본값을 7일 주기로 제한합니다.

## 실행 예시

```plaintext
==> Bun 런타임 업그레이드
  ✓ Bun 런타임 업그레이드

==> Bun 글로벌 패키지 업데이트
  ✓ Bun 글로벌 패키지 업데이트

==> Codex CLI 설치됨 (0.69.0)
  ✓ Codex CLI 설치됨 (0.69.0)

==> Gemini CLI 설치됨 (0.4.2)
  ✓ Gemini CLI 설치됨 (0.4.2)

⏱️ 작업별 소요 시간 요약
  ✓ Bun 런타임 업그레이드: 1s
  ✓ Bun 글로벌 패키지 업데이트: 4s
  ✓ Codex CLI 설치됨 (0.69.0): 0s
  ✓ Gemini CLI 설치됨 (0.4.2): 0s

✅ 모든 작업 완료! (총 소요 시간: 12초)

==> ⬆️ 이번 실행에서 버전이 바뀐 것들
  [tool] npm 10.9.0 -> 10.9.1
  [bun] @google/gemini-cli 0.4.1 -> 0.4.2
```

## 주의 사항

* 관리자 권한
  * Winget이나 Chocolatey 업데이트는 관리자 권한이 필요할 수 있습니다

* Winget (Git Bash)
  * Git Bash에서 winget 실행 시 winpty 래핑을 자동 적용합니다
  * PATH에 winget이 없어도 `SystemRoot` 환경변수를 활용해 동적으로 경로를 탐색합니다 (C: 외 드라이브 지원)
  * 업데이트 없음 메시지는 실패가 아니라 SKIPPED로 처리합니다

* pnpm 경고
  * Ignored build scripts 경고가 감지되면 pnpm approve-builds -g 실행 안내가 출력됩니다

* bun 전역 postinstall
  * trust all은 자동 실행하지 않습니다
  * allowlist에 포함된 패키지만 trust를 시도합니다

* 실행 파일 경로 충돌
  * 전역과 로컬이 같이 있을 때는 PATH 우선순위 때문에 “다른 버전이 실행”될 수 있습니다
  * 프로젝트에서는 bunx 또는 bun run으로 로컬 실행을 고정하는 것을 권장합니다

## bun allowlist 규칙

Dev-Up은 bun 전역에 wrangler/vercel이 설치되어 있을 때 allowlist 기반 trust를 시도합니다.

* wrangler 전역 사용 시: esbuild, workerd trust 후보에 포함
* vercel 전역 사용 시: esbuild, sharp trust 후보에 포함
* node-pty: 자동 trust 제외

### allowlist 커스터마이징

환경변수로 allowlist를 확장할 수 있습니다.

```bash
# wrangler allowlist 커스터마이징
export DEV_UP_BUN_TRUST_ALLOWLIST_WRANGLER="esbuild workerd miniflare"

# vercel allowlist 커스터마이징
export DEV_UP_BUN_TRUST_ALLOWLIST_VERCEL="esbuild sharp puppeteer"
```
