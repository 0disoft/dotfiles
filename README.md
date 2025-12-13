# 🚀 Dev-Up: 통합 개발 환경 원클릭 업데이트

Dev-Up은 Git Bash 환경에서 자주 쓰는 런타임, 패키지 매니저, 시스템 도구 업데이트를 한 번에 돌려주는 함수입니다.
dev-up 한 줄로 업데이트 체인을 굴리고, 마지막에 성공 실패와 소요 시간, 버전 변경 목록을 정리해 보여줍니다.

## 주요 기능

- Bun
  - 런타임 업데이트: bun upgrade
  - 전역 패키지 업데이트: bun update -g
  - codex, gemini-cli 최신 강제 설치
  - bun 전역 postinstall 차단 감지 후 allowlist 방식으로만 trust 시도
- Node.js
  - npm 자체 업데이트: npm install -g npm@latest
  - npm 전역 패키지 업데이트는 7일에 한 번만 자동 실행
  - Corepack으로 pnpm 최신 지정
  - pnpm 전역 패키지 업데이트
- Rust: rustup update
- Python
  - pip 업데이트
  - uv 업데이트는 설치 방식에 따라 자동 분기
- Deno, Flutter, Julia: 각 런타임 및 SDK 업데이트
- Windows 시스템
  - Winget으로 GitHub CLI, Starship 업데이트
  - Chocolatey 패키지 업데이트
- 결과 리포트
  - 작업별 소요 시간, 성공 실패 요약
  - 이번 실행에서 버전이 바뀐 항목만 별도 목록으로 출력

## 설치 및 적용 방법

이 스크립트는 Git Bash 설정 파일인 .bashrc에 함수 형태로 등록해서 사용합니다.

1. 설정 파일 열기

    ```plaintext
    nano ~/.bashrc
    ```

2. 스크립트 등록

    파일의 맨 아래쪽에 dev-up 함수 전체 코드를 붙여넣습니다.
    Starship 같은 프롬프트 설정이 있다면 그 아래에 배치하는 것을 권장합니다.

3. 변경 사항 저장

    - Ctrl + O 저장 후 Enter
    - Ctrl + X 나가기

4. 설정 적용

    ```plaintext
    source ~/.bashrc
    ```

## 사용 방법

```plaintext
dev-up
```

## 옵션 환경변수

필요할 때만 더 강하게 돌릴 수 있습니다.

### npm 전역 업데이트

- 기본 동작: 7일에 한 번만 npm 전역 업데이트 실행
- 지금 바로 강제 실행

```plaintext
DEV_UP_NPM_GLOBAL_FORCE=1 dev-up
```

- 주기 변경

```plaintext
DEV_UP_NPM_GLOBAL_INTERVAL_DAYS=3 dev-up
```

### bun 전역 패키지 최신 강제

- bun 전역에 설치된 모든 패키지를 최신으로 강제 설치

```plaintext
DEV_UP_BUN_FORCE_LATEST_ALL=1 dev-up
```

- bun 캐시를 비우고 최신 해석을 더 강하게

```plaintext
DEV_UP_BUN_FORCE_LATEST_ALL=1 DEV_UP_BUN_FORCE_LATEST_COLD=1 dev-up
```

- 가장 확실하게 하고 싶을 때
  - npm view로 최신 버전 번호를 받아서 그 버전으로 설치합니다
  - 정확도는 높고, 속도는 느릴 수 있습니다

```plaintext
DEV_UP_BUN_FORCE_LATEST_ALL=1 DEV_UP_BUN_FORCE_LATEST_NPM=1 dev-up
```

### codex, gemini-cli 최신 강제

- codex와 gemini-cli는 기본 동작에서도 최신 강제 설치를 수행합니다
- npm이 있으면 npm view로 최신 버전 번호를 조회해 그 버전으로 설치합니다
- npm이 없거나 조회가 실패하면 latest로 설치합니다

## npm 전역 업데이트가 7일 주기인 이유

npm update -g는 전역 패키지가 많을수록 매우 무거워집니다.
한 번에 수백 개가 바뀌면 몇 분이 걸릴 수 있습니다.
그래서 Dev-Up은 기본 동작에서 7일에 한 번만 실행합니다.

주기 관리는 로컬 상태 파일로 기록됩니다.

- 기본 경로: HOME/.cache/dev-up/npm-global-update.ts
- 이 파일을 삭제하면 다음 실행에서 다시 npm 전역 업데이트가 수행됩니다

## 실행 예시

```plaintext
==> Bun 런타임 업그레이드
  ✓ Bun 런타임 업그레이드

==> Bun 글로벌 패키지 업데이트
  ✓ Bun 글로벌 패키지 업데이트

==> Codex CLI 강제 최신 설치 (@openai/codex@0.71.0)
  ✓ Codex CLI 강제 최신 설치

==> Gemini CLI 강제 최신 설치 (@google/gemini-cli@0.4.2)
  ✓ Gemini CLI 강제 최신 설치

==> Bun 전역 postinstall 스크립트 상태 확인
  ⚠️ Bun 전역에서 차단된 lifecycle 스크립트가 감지되었습니다.
  ... node-pty는 자동 trust에서 제외했습니다. 필요할 때만 수동으로 처리하세요.
  ... 자동 trust 후보(현재 전역 패키지 기준): esbuild workerd sharp
  ✓ Bun 전역 postinstall 신뢰 및 실행 (allowlist)

⏱️ 작업별 소요 시간 요약
  ✓ Bun 런타임 업그레이드: 1s
  ✓ Bun 글로벌 패키지 업데이트: 4s
  ✓ Codex CLI 강제 최신 설치: 3s
  ✓ Gemini CLI 강제 최신 설치: 2s
  ✓ Bun 전역 postinstall 신뢰 및 실행 (allowlist): 3s

✅ 모든 작업 완료! (총 소요 시간: 20초)

==> ⬆️ 이번 실행에서 버전이 바뀐 것들
  [tool] npm 10.9.0 -> 10.9.1
  [bun] codex 0.66.0 -> 0.71.0
  [bun] gemini 0.3.1 -> 0.4.2
```

## 주의 사항

- 관리자 권한
  - Winget이나 Chocolatey 업데이트는 관리자 권한이 필요할 수 있습니다
  - 권한 오류가 나면 Git Bash를 관리자 권한으로 실행하세요

- pnpm 경고
  - 로그에서 Ignored build scripts가 감지되면 pnpm approve-builds -g 실행 안내가 출력됩니다

- bun 전역 postinstall
  - Dev-Up은 trust all을 자동 실행하지 않습니다
  - allowlist에 포함된 패키지만 trust를 시도합니다

- codex, gemini 실행 파일을 못 찾는 경우
  - 설치는 됐는데 실행이 안 되면 PATH 우선순위 문제일 수 있습니다
  - command -v codex, command -v gemini로 실제 경로를 확인하세요

## bun allowlist 규칙

Dev-Up은 bun pm ls -g 결과를 보고 allowlist를 구성합니다.

- wrangler 전역 사용 시: esbuild, workerd trust 후보에 포함
- vercel 전역 사용 시: esbuild, sharp trust 후보에 포함
- node-pty: 자동 trust 제외

원하는 경우 allowlist 규칙은 dev-up 함수 내부에서 쉽게 수정할 수 있습니다.
