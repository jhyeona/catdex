# Usage

This guide covers local installation, everyday use, status behavior, icon customization, cleanup, and development commands.

## Quick Install

Run this from the project root:

```bash
scripts/install-local.sh
```

Installed files:

```text
~/.local/bin/catdex
~/Applications/CatdexMenu.app
```

If `~/.local/bin` is not on your `PATH`, add it to your shell config:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Start The Menu Bar App

Run:

```bash
open ~/Applications/CatdexMenu.app
```

The menu bar normally shows `🐱`. When active sessions exist, it shows the highest-priority state:

- `🐱❓`: review needed
- `🙀`: failed
- `😿`: stale
- `✍️`: responding or running tools
- `😼`: starting or running
- `👀`: waiting for the next prompt

If multiple sessions are active, Catdex appends the active count, such as `✍️ 2`.

Priority:

```text
review > failed > stale > responding > starting/running > waiting
```

Click the menu bar item to see the session list:

```text
🐱 Codex Cats
😼 RUNNING  investigate duplicate reminders  ·  backend-app @fix/reminder
🙀 FAILED   fix the UI build                 ·  admin-web
```

`done` sessions are hidden from the active list. They may still exist as session files, but they are not shown in the menu.

Each row means:

```text
state-icon STATE  task  ·  project-folder @branch
```

Session submenu actions:

- `Open Workspace`: open the working directory
- `Open Log`: open the internal Catdex log
- `Open Codex Session`: open the Codex JSONL session file from the menu submenu
- `Reveal Session JSON`: select the Catdex session JSON in Finder
- `Dismiss`: remove a finished session from the list

Menu actions:

- `Hide Floating Panel` / `Show Floating Panel`
- `Settings...`
- `Open Status Folder`
- `Dismiss Finished`
- `Refresh`
- `Quit`

`Dismiss Finished` removes `done`, `failed`, and `stale` sessions. It does not remove active sessions.

## Floating Panel

Catdex also shows a compact floating panel. It follows you across macOS Spaces and stays above normal windows.

Each session gets one cell:

```text
icon
task
```

The task name is clipped inside the cell so the panel stays small. Drag the panel by its background or cells to move it.

Click a session cell to open a context popover. The popover shows:

- `CURRENT`: state, last status message, and update time
- `LAST USER QUESTION`: the latest user prompt seen in the Codex session file
- `LAST ASSISTANT ANSWER`: the latest assistant `final_answer`; if it contains a divider, Catdex shows only the final result after the last divider
- `PATHS`: workspace, log, and Codex session paths

Popover actions:

- `Workspace`: open the working directory
- `Log`: open the Catdex wrapper log
- `Copy Context`: copy the displayed context to the clipboard
- `Reveal JSON`: select the Catdex session JSON in Finder

Use the upper-right close button, press `Esc`, or click outside the popover to dismiss it.

## Custom Status Icons

Open the menu bar item and choose `Settings...`.

For each state:

- `Choose...`: select an image file
- `Emoji...`: enter an emoji or short text
- `Reset`: use the default emoji again

Supported image types:

```text
png, jpg, gif, tiff, bmp, icns, pdf, svg
```

Settings are saved here:

```text
~/.codex/cat-status/settings.json
```

Emoji settings take priority over image settings. If an image cannot be loaded, Catdex falls back to the default emoji.

## Start Codex Work

Use `catdex` instead of `codex`:

```bash
catdex
catdex "investigate duplicate reminders"
```

If you run `catdex` without a prompt, the current folder name is used as the task name. If you pass a prompt, the prompt is forwarded to Codex and also used as the displayed task name.

The wrapper does this:

1. Creates a new session ID
2. Writes `~/.codex/cat-status/sessions/*.json`
3. Starts the real `codex` process
4. Finds the Codex JSONL session file
5. Infers state from Codex events
6. Updates heartbeat while running
7. Records `done` or `failed` from the Codex exit code

Catdex forwards `SIGTERM`, `SIGINT`, and `SIGHUP` to the Codex process group and records the session as `failed`, so interrupted terminal sessions do not stay stuck as active forever.

Pass Codex options as usual:

```bash
catdex --model gpt-5.4 "review the API"
```

Use a custom Codex executable:

```bash
catdex --codex-bin /path/to/codex "review the API"
```

Set only the displayed task name:

```bash
catdex --task "API review" --model gpt-5.4
```

## States

| State | Meaning |
| --- | --- |
| `starting` | Catdex created a session and is starting Codex or finding its session file |
| `responding` | Codex is answering, reasoning, running tools, or processing tool results |
| `waiting` | Codex finished an answer and is waiting for the next prompt |
| `review` | Permission approval, command confirmation, or user input is needed |
| `done` | Codex exited successfully |
| `failed` | Codex exited with an error, signal, or aborted turn |
| `stale` | The process disappeared or heartbeat updates stopped |
| `running` | Compatibility state for older sessions |

Catdex reads events from Codex JSONL files under:

```text
~/.codex/sessions/**/*.jsonl
```

It infers `responding`, `waiting`, and `review` from those events. `review` is detected from user input requests or tool calls that require elevated permissions.

Manual `review` representation in a session JSON:

```json
{
  "state": "review",
  "lastMessage": "Permission approval required",
  "reviewOptions": [
    "Yes, proceed",
    "No, stop",
    "Change command"
  ]
}
```

The menu shows `🐱❓ REVIEW`, and review options appear in the row tooltip.

## Notifications

Catdex sends a macOS notification when a session enters `review`:

```text
🐱❓ Codex needs review
<task name>
```

Disable notifications for one run:

```bash
CATDEX_NOTIFY=0 catdex "quiet task"
```

## Cleanup

`catdex` updates heartbeat every 15 seconds while running. The menu bar app marks active sessions as `stale` after 120 seconds without heartbeat updates, and persists that state to the session file.

`done`, `failed`, and `stale` sessions older than 24 hours are automatically pruned during menu refresh.

Clean up now:

```bash
catdex cleanup
```

This marks old active sessions as `stale`, then removes finished sessions and their logs.

## Doctor

Check the installation and runtime state:

```bash
catdex doctor
```

`catdex doctor` checks:

- status directory writability
- Codex executable discovery
- `catdex` on `PATH`
- `CatdexMenu.app` installation
- current session counts
- active sessions pointing at dead PIDs

Run Codex's own `doctor` command by passing it after `--`:

```bash
catdex -- doctor
```

`cleanup` and `doctor` are reserved Catdex top-level commands. To pass those words to Codex as prompts or subcommands, put them after `--`.

## Environment Variables

Change the status directory:

```bash
CATDEX_STATUS_DIR=/private/tmp/catdex-status catdex "test"
```

Change the default Codex executable:

```bash
CATDEX_CODEX_BIN=/path/to/codex catdex "test"
```

Disable notifications:

```bash
CATDEX_NOTIFY=0 catdex "test"
```

## Development

Run tests:

```bash
swift test
```

Build the menu bar executable:

```bash
swift build --product CatdexMenu
```

Create the app bundle:

```bash
scripts/build-app.sh
```

Bundle output:

```text
build/CatdexMenu.app
```

## Smoke Tests

Create a session without starting Codex:

```bash
catdex --dry-run "CLI smoke test"
```

Record a successful run:

```bash
CATDEX_NOTIFY=0 catdex --task "true command smoke" --codex-bin /usr/bin/true
```

Record a failed run:

```bash
CATDEX_NOTIFY=0 catdex --task "false command smoke" --codex-bin /usr/bin/false
```

Test cleanup in a temporary directory:

```bash
CATDEX_STATUS_DIR=/private/tmp/catdex-status-test catdex cleanup
```

Run the environment check:

```bash
catdex doctor
```

## Korean

<details>
<summary>한국어 사용법 보기</summary>

# 사용 방법

## 빠른 설치

프로젝트 루트에서 실행합니다.

```bash
scripts/install-local.sh
```

설치 결과:

```text
~/.local/bin/catdex
~/Applications/CatdexMenu.app
```

`~/.local/bin`이 `PATH`에 없다면 셸 설정에 추가합니다.

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## 메뉴바 앱 실행

```bash
open ~/Applications/CatdexMenu.app
```

메뉴바에는 평소 `🐱`가 보입니다. 표시할 세션이 있으면 가장 중요한 상태를 메뉴바 아이콘에 반영합니다.

- `🐱❓`: 컨펌 필요
- `🙀`: 실패
- `😿`: stale
- `✍️`: 답변/도구 실행 중
- `😼`: 시작 또는 실행 중
- `👀`: 다음 프롬프트 대기

세션이 여러 개면 `✍️ 2`처럼 active 세션 수가 붙습니다.

우선순위:

```text
review > failed > stale > responding > starting/running > waiting
```

클릭하면 세션 목록이 보입니다.

```text
🐱 Codex Cats
😼 RUNNING  배치 중복 발송 조사  ·  backend-app @fix/reminder
🙀 FAILED   UI 빌드 수정         ·  admin-web
```

`done` 세션은 활성 목록에 표시하지 않습니다.

세션 메뉴:

- `Open Workspace`: 작업 폴더 열기
- `Open Log`: Catdex 내부 로그 열기
- `Open Codex Session`: 메뉴 하위 항목에서 Codex JSONL 세션 파일 열기
- `Reveal Session JSON`: 세션 상태 파일을 Finder에서 선택
- `Dismiss`: 완료된 세션 제거

메뉴 하단:

- `Hide Floating Panel` / `Show Floating Panel`
- `Settings...`
- `Open Status Folder`
- `Dismiss Finished`
- `Refresh`
- `Quit`

## 플로팅 패널

플로팅 패널은 macOS Spaces를 따라다니고 일반 창 위에 표시됩니다.

각 세션은 작은 칸 하나로 보입니다.

```text
아이콘
작업명
```

세션 셀을 클릭하면 컨텍스트 팝오버가 열립니다.

- `CURRENT`: 상태, 마지막 상태 메시지, 갱신 시각
- `LAST USER QUESTION`: Codex 세션 파일에서 읽은 마지막 사용자 질문
- `LAST ASSISTANT ANSWER`: 마지막 assistant `final_answer`; 구분선이 있으면 마지막 구분선 뒤의 최종 결과만 표시
- `PATHS`: workspace, log, Codex session 경로

팝오버 버튼:

- `Workspace`: 작업 폴더 열기
- `Log`: Catdex wrapper 로그 열기
- `Copy Context`: 표시 중인 컨텍스트를 클립보드에 복사
- `Reveal JSON`: Catdex 세션 JSON을 Finder에서 선택

우측 상단 닫기 버튼, `Esc`, 또는 바깥 클릭으로 닫을 수 있습니다.

작업명은 칸 안에서 잘립니다. 패널 배경이나 셀을 잡고 드래그할 수 있습니다.

## 상태 아이콘 설정

메뉴바에서 `Settings...`를 엽니다.

상태별로 다음을 설정할 수 있습니다.

- `Choose...`: 이미지 파일 선택
- `Emoji...`: 이모지나 짧은 텍스트 입력
- `Reset`: 기본 이모지로 복구

지원 이미지:

```text
png, jpg, gif, tiff, bmp, icns, pdf, svg
```

설정 파일:

```text
~/.codex/cat-status/settings.json
```

이모지 설정이 이미지 설정보다 우선합니다. 이미지 로드에 실패하면 기본 이모지로 돌아갑니다.

## Codex 작업 시작

기존 `codex` 대신 `catdex`를 사용합니다.

```bash
catdex
catdex "배치 중복 발송 조사"
```

`catdex`만 실행하면 현재 폴더명이 세션 이름이 됩니다. 프롬프트를 넘기면 Codex에 그대로 전달하고, 메뉴에 보이는 작업명으로도 사용합니다.

Codex 옵션은 그대로 넘길 수 있습니다.

```bash
catdex --model gpt-5.4 "API 리뷰"
```

Codex 실행 파일 경로를 직접 지정:

```bash
catdex --codex-bin /path/to/codex "API 리뷰"
```

메뉴바 표시 이름만 지정:

```bash
catdex --task "API 리뷰" --model gpt-5.4
```

## 상태

| 상태 | 의미 |
| --- | --- |
| `starting` | Catdex 세션 생성, Codex 시작 또는 세션 파일 탐색 중 |
| `responding` | Codex가 답변 생성, 추론, 도구 실행/결과 처리 중 |
| `waiting` | 답변 완료 후 다음 프롬프트 대기 |
| `review` | 권한 승인, 명령 확인, 사용자 입력 등 컨펌 필요 |
| `done` | Codex 정상 종료 |
| `failed` | 비정상 종료, 시그널, turn abort |
| `stale` | 프로세스가 사라졌거나 heartbeat가 끊김 |
| `running` | 이전 버전 세션 호환용 |

`catdex`는 Codex가 남기는 JSONL 이벤트를 읽어서 `responding`, `waiting`, `review`를 추론합니다.

## 알림

세션이 `review` 상태로 바뀌면 macOS 알림을 보냅니다.

```text
🐱❓ Codex needs review
<작업명>
```

알림 끄기:

```bash
CATDEX_NOTIFY=0 catdex "조용한 작업"
```

## 정리

`catdex`는 실행 중 15초마다 heartbeat를 갱신합니다. 메뉴바 앱은 120초 이상 갱신이 끊긴 active 세션을 `stale`로 바꿉니다.

완료/실패/stale 세션 정리:

```bash
catdex cleanup
```

설치와 상태 저장소 점검:

```bash
catdex doctor
```

## 환경 변수

상태 저장 위치 변경:

```bash
CATDEX_STATUS_DIR=/private/tmp/catdex-status catdex "테스트"
```

Codex 실행 파일 기본값 변경:

```bash
CATDEX_CODEX_BIN=/path/to/codex catdex "테스트"
```

알림 끄기:

```bash
CATDEX_NOTIFY=0 catdex "테스트"
```

## 개발 명령

```bash
swift test
swift build --product CatdexMenu
scripts/build-app.sh
```

</details>
