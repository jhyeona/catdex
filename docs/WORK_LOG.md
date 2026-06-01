# 작업 기록

## 목표

맥북 메뉴바에서 여러 Codex 작업 상태를 어디서나 확인할 수 있는 개인용 도구를 만들었다. 장난감처럼 보여도 괜찮다는 요구에 맞춰 메뉴바와 목록에 고양이 이모지를 사용했다.

## 구현 구조

- Swift Package 기반 프로젝트로 구성했다.
- `CatdexCore` 라이브러리에 상태 모델, 경로, JSON 저장소, 실행 파일 탐색 로직을 분리했다.
- `catdex` 실행 파일은 Codex를 감싸서 실행하고 세션 상태 파일을 자동 생성/갱신한다.
- `CatdexMenu` 실행 파일은 macOS 메뉴바에 최우선 상태 아이콘과 활성 세션 수를 표시한다.
- 메뉴 항목은 workspace, log, session JSON을 바로 열 수 있는 하위 메뉴를 제공한다.
- 정상 완료된 `done` 세션은 상태 파일에는 남기지만 메뉴 리스트에는 표시하지 않는다.
- `catdex cleanup`과 `catdex doctor`로 상태 정리와 설치/환경 점검을 지원한다.
- `catdex`가 Codex 세션 JSONL을 찾아 내부 이벤트 기반 상태를 추론한다.
- 앱 번들 생성을 위해 `scripts/build-app.sh`를 추가했다.
- 로컬 설치 편의를 위해 `scripts/install-local.sh`를 추가했다.

## 상태 저장 방식

기본 상태 디렉터리는 다음 위치다.

```text
~/.codex/cat-status/
  sessions/
  logs/
```

세션 하나당 JSON 파일 하나를 쓴다.

```json
{
  "id": "20260527-180505-88529-true-command-smoke",
  "state": "done",
  "task": "true command smoke",
  "workspace": "/Users/example/projects/catdex-status",
  "updatedAt": "2026-05-27T09:05:05Z",
  "pid": 88534,
  "lastMessage": "😺 Codex complete",
  "logPath": "/.../logs/...log",
  "exitCode": 0
}
```

지원 상태는 다음과 같다.

- `starting`: catdex 세션 생성, Codex 시작 또는 Codex 세션 파일 탐색 중
- `responding`: 답변 생성, 추론, 도구 실행, 도구 결과 처리 중
- `waiting`: 답변 완료 후 다음 프롬프트 대기
- `review`: 권한 승인, 명령 실행 확인, 사용자 선택 등 검토 필요
- `done`: 성공 종료
- `failed`: 실패 종료
- `stale`: heartbeat가 오래 끊긴 실행 중 세션
- `running`: 이전 버전 세션 호환용

## 안정성 처리

- JSON 저장은 임시 파일을 만든 뒤 교체하는 방식으로 처리했다.
- 깨진 JSON 파일은 메뉴바 앱에서 무시한다.
- active 상태가 오래 갱신되지 않으면 메뉴바 앱이 `stale`로 표시하고 세션 파일에도 저장한다.
- 완료, 실패, stale 세션은 24시간 후 메뉴바 앱이 정리한다.
- 메뉴와 `catdex cleanup`에서 완료, 실패, stale 세션을 즉시 dismiss할 수 있다.
- `catdex`가 실제 Codex 종료 코드를 그대로 반환한다.
- `SIGTERM`, `SIGINT`, `SIGHUP`을 받으면 Codex 프로세스 그룹에 신호를 전달하고 세션을 `failed`로 기록한다.
- Codex 세션 이벤트의 `task_started`, `agent_reasoning`, `function_call`, `final_answer`, `task_complete`, 권한 상승 요청을 읽어 `responding`, `waiting`, `review`로 전환한다.
- `review` 상태 진입 시 `osascript`를 통해 macOS 알림을 시도한다. `CATDEX_NOTIFY=0`이면 알림을 끈다.

## 테스트한 내용

- `swift test`: `CatdexCore` 단위 테스트 통과
- `catdex --dry-run`: 세션 JSON과 로그 파일 생성 확인
- `catdex --codex-bin /usr/bin/true`: `done`, `exitCode: 0` 기록 확인
- `catdex --codex-bin /usr/bin/false`: `failed`, `exitCode: 1` 기록 확인
- `catdex --codex-bin /bin/sleep` 실행 후 `SIGTERM`: 자식 프로세스 정리와 `failed` 기록 확인
- `catdex cleanup`: 완료/실패/stale 세션과 로그 제거 확인
- `catdex doctor`: 상태 디렉터리, 실행 파일, 앱 설치, 세션 현황 출력 확인
- Codex 세션 JSONL 기반 상태 전환 smoke 확인
- `swift build --product CatdexMenu`: 메뉴바 실행 파일 빌드 확인
- `scripts/build-app.sh`: `build/CatdexMenu.app` 번들 생성 및 `Info.plist` 검증 확인

## 현재 제한

- 기존에 이미 직접 실행한 `codex` 세션은 자동 수집하지 않는다. `catdex`로 시작한 작업만 정확히 추적한다.
- `review` 상태는 Codex JSONL에 남는 권한 상승 tool call과 사용자 입력 요청을 기준으로 추론한다. Codex가 이벤트 포맷을 바꾸면 감지 규칙도 같이 조정해야 한다.
- 터미널 출력은 그대로 Codex에 붙여 두기 위해 전체 stdout/stderr 캡처는 하지 않는다. 로그 파일에는 catdex 내부 이벤트만 기록한다.
- 초기에는 요청한 작업 디렉터리 접근이 macOS 권한 문제로 막혀 대체 로컬 경로에서 먼저 구현했다. 최종 완료본은 요청한 위치로 복사했고, 그 위치에서 테스트와 빌드를 다시 통과시켰다.
