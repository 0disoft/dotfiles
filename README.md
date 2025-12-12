# 🚀 Dev-Up: 통합 개발 환경 원클릭 업데이트

Dev-Up은 윈도우 Git Bash 환경에서 자주 쓰는 런타임, 패키지 매니저, 시스템 도구 업데이트를 한 번에 돌려주는 자동화 함수입니다.
dev-up 한 줄로 “업데이트 체인”을 굴리고, 마지막에 성공 실패와 소요 시간을 요약합니다.

## ✨ 주요 기능

시스템에 설치된 도구를 자동으로 감지하여, 있는 것만 업데이트합니다.

- Bun: 런타임(bun upgrade) 및 글로벌 패키지(bun update -g) 업데이트
- Node.js: npm 업데이트, Corepack으로 pnpm 최신 지정, pnpm 글로벌 패키지 업데이트
- Rust: rustup 툴체인 업데이트
- Python: pip 업데이트, uv 업데이트(설치 방식에 따라 자동 분기)
- Deno, Flutter, Julia: 각 런타임 및 SDK 업데이트
- Windows 시스템: Winget(GitHub CLI, Starship) 및 Chocolatey 패키지 업데이트
- 결과 리포트: 작업별 소요 시간, 성공 실패 여부 요약 출력

## 🧠 Dev-Up의 업데이트 철학

전역 업데이트 자동화는 빠르고 편해야 합니다.
그래서 Dev-Up은 “한 패키지 빌드 실패로 전체 업데이트가 폭발”하지 않도록, 몇 가지 안전장치를 둡니다.

- Bun postinstall 스크립트 trust --all 자동 실행을 하지 않습니다
- Bun은 전역 패키지 사용 현황을 보고 allowlist 방식으로만 trust를 시도합니다
- node-pty는 Windows에서 네이티브 빌드 실패가 잦아 자동 trust 대상에서 제외합니다
- uv는 설치 방식이 섞였을 때 self update가 실패할 수 있어 실행 경로로 자동 분기합니다

## 🛠 설치 및 적용 방법 (Git Bash)

이 스크립트는 Git Bash 설정 파일인 .bashrc에 함수 형태로 등록하여 사용합니다.

### 1. 설정 파일 열기

```plaintext
nano ~/.bashrc
```

### 2. 스크립트 등록

파일의 맨 아래쪽에 dev-up 함수 전체 코드를 복사하여 붙여넣습니다.
Starship 같은 프롬프트 설정이 있다면 그 아래에 배치하는 것을 권장합니다.

### 3. 변경 사항 저장

- Ctrl + O 저장 후 Enter
- Ctrl + X 나가기

### 4. 설정 적용

```plaintext
source ~/.bashrc
```

## 💻 사용 방법

```plaintext
dev-up
```

### 실행 예시

```plaintext
==> Bun 런타임 업그레이드
  ✓ Bun 런타임 업그레이드

==> Bun 글로벌 패키지 업데이트
  ✓ Bun 글로벌 패키지 업데이트

==> Bun 전역 postinstall 스크립트 상태 확인
  ⚠️ Bun 전역에서 차단된 lifecycle 스크립트가 감지되었습니다.
  ... node-pty는 자동 trust에서 제외했습니다. 필요할 때만 수동으로 처리하세요.
  ... 자동 trust 후보(현재 전역 패키지 기준): esbuild workerd sharp
  ✓ Bun 전역 postinstall 신뢰 및 실행 (allowlist)

⏱️ 작업별 소요 시간 요약
  ✓ Bun 런타임 업그레이드: 1s
  ✓ Bun 글로벌 패키지 업데이트: 4s
  ✓ Bun 전역 postinstall 신뢰 및 실행 (allowlist): 3s

✅ 모든 작업 완료! (총 소요 시간: 12초)
```

## ⚠️ 주의 사항

- 관리자 권한: Winget이나 Chocolatey 업데이트는 관리자 권한이 필요할 수 있습니다. 권한 오류가 발생하면 Git Bash를 관리자 권한으로 실행해 주세요.
- pnpm 경고: Ignored build scripts 경고가 감지되면 pnpm approve-builds -g 실행 안내가 출력됩니다.
- Bun 전역 postinstall: Dev-Up은 trust --all을 자동 실행하지 않습니다. 전역 스크립트 실행은 allowlist 방식으로만 제한합니다.
- uv 업데이트: uv가 pip 설치본이면 pip로 업그레이드하고, standalone 설치본이면 uv self update를 사용합니다.

## 🔧 Bun allowlist 규칙

Dev-Up은 bun pm ls -g 결과를 보고 allowlist를 구성합니다.

- wrangler 전역 사용 시: esbuild, workerd trust 후보에 포함
- vercel 전역 사용 시: esbuild, sharp trust 후보에 포함
- node-pty: 자동 trust 제외

원하는 경우 allowlist 규칙은 dev-up 함수 상단에서 쉽게 수정할 수 있습니다.
