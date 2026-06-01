# Catdex Status

A tiny macOS companion for keeping an eye on your Codex sessions.

Catdex wraps the `codex` CLI, records lightweight session state, and shows every running task as a little cat in your menu bar and floating panel. Quiet when nothing is happening. Loud enough when Codex needs your review.

## What It Does

- Shows Codex session state in the macOS menu bar
- Adds a small always-on-top floating panel with one cell per session
- Displays each session as a status icon plus a clipped task name
- Lets you customize status icons with emoji, PNG, SVG, PDF, ICNS, and other image files
- Sends a macOS notification when a session enters `review`
- Hides `done` sessions from the active list
- Marks silent active sessions as `stale` when heartbeat updates stop

## Components

- `catdex`: a Codex CLI wrapper. Use it like `codex`; it creates and updates Catdex session files while Codex runs.
- `CatdexMenu`: a macOS menu bar app. It reads `~/.codex/cat-status/sessions/*.json` and renders the menu bar list plus the floating panel.

## Install

```bash
scripts/install-local.sh
```

Installed files:

```text
~/.local/bin/catdex
~/Applications/CatdexMenu.app
```

If `~/.local/bin` is not on your `PATH`, add it:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Start the menu bar app:

```bash
open ~/Applications/CatdexMenu.app
```

## Usage

Run Codex through Catdex:

```bash
catdex
catdex "review the API changes"
catdex --model gpt-5.4 "debug the reminder job"
```

Set a display name without changing the Codex prompt:

```bash
catdex --task "API review" --model gpt-5.4
```

Use a custom Codex executable:

```bash
catdex --codex-bin /path/to/codex "check this branch"
```

## Statuses

| State | Meaning |
| --- | --- |
| `starting` | Catdex created a session and is starting Codex or finding its session file |
| `responding` | Codex is thinking, answering, running tools, or processing tool results |
| `waiting` | Codex finished an answer and is waiting for the next prompt |
| `review` | Codex needs confirmation, approval, or user input |
| `done` | Codex exited successfully |
| `failed` | Codex exited with an error, signal, or aborted turn |
| `stale` | Heartbeat was lost or the process disappeared |
| `running` | Compatibility state for older sessions |

Menu bar priority:

```text
review > failed > stale > responding > starting/running > waiting
```

## Floating Panel

Catdex shows a compact floating panel that follows you across Spaces. Each session gets its own small cell:

```text
icon
task
```

The task name is clipped inside the cell, so the panel stays small. You can drag the panel by its background or cells.

From the menu bar, use:

- `Hide Floating Panel`
- `Show Floating Panel`

## Custom Icons

Open the menu bar item and choose `Settings...`.

For every state you can set:

- `Choose...`: select an image file
- `Emoji...`: type an emoji or short text
- `Reset`: go back to the default cat emoji

Supported image types include:

```text
png, jpg, gif, tiff, bmp, icns, pdf, svg
```

Settings are stored here:

```text
~/.codex/cat-status/settings.json
```

Emoji settings take priority over image settings. If an image cannot be loaded, Catdex falls back to the default emoji.

## Notifications

Catdex sends a macOS notification when a session enters `review`:

```text
🐱❓ Codex needs review
<task name>
```

Disable notifications for a run:

```bash
CATDEX_NOTIFY=0 catdex "quiet task"
```

## Maintenance

Clean up finished sessions:

```bash
catdex cleanup
```

Check your setup:

```bash
catdex doctor
```

Status files and logs live under:

```text
~/.codex/cat-status/
├── sessions/
├── logs/
└── settings.json
```

Override the status directory:

```bash
CATDEX_STATUS_DIR=/private/tmp/catdex-status catdex "test"
```

## Development

Run tests:

```bash
swift test
```

Build the menu bar app:

```bash
swift build --product CatdexMenu
```

Create the `.app` bundle:

```bash
scripts/build-app.sh
```

## Notes

Catdex tracks sessions that were started through `catdex`. Existing `codex` sessions started directly are not imported.

The `review` state is inferred from Codex JSONL events such as user input requests and tool calls that require elevated permissions. If Codex changes its event format, Catdex may need matching updates.

## Korean

<details>
<summary>한국어 README 보기</summary>

# Catdex Status

여러 Codex 작업을 맥 메뉴바와 작은 플로팅 패널에서 고양이처럼 귀엽게 지켜보는 도구입니다.

`catdex`는 `codex` CLI를 감싸서 실행하고, 작업 상태를 `~/.codex/cat-status/` 아래에 기록합니다. `CatdexMenu` 앱은 그 상태 파일을 읽어서 메뉴바 목록과 플로팅 패널에 보여줍니다.

## 기능

- macOS 메뉴바에서 Codex 세션 상태 확인
- 어디서나 보이는 작은 플로팅 패널 제공
- 세션마다 상태 아이콘과 잘리는 작업명 표시
- 상태별 아이콘을 이모지나 이미지 파일로 변경
- `review` 상태가 되면 macOS 알림 전송
- `done` 세션은 활성 목록에서 숨김
- heartbeat가 끊긴 활성 세션은 `stale`로 표시

## 설치

```bash
scripts/install-local.sh
```

설치 위치:

```text
~/.local/bin/catdex
~/Applications/CatdexMenu.app
```

메뉴바 앱 실행:

```bash
open ~/Applications/CatdexMenu.app
```

## 사용

기존 `codex` 대신 `catdex`를 사용합니다.

```bash
catdex
catdex "API 변경사항 리뷰"
catdex --model gpt-5.4 "리마인더 배치 디버깅"
```

메뉴바에 보이는 이름만 따로 지정하려면:

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
| `stale` | heartbeat가 끊겼거나 프로세스가 사라짐 |
| `running` | 이전 버전 세션 호환용 상태 |

## 플로팅 패널

플로팅 패널은 각 세션을 작은 칸 하나로 보여줍니다.

```text
아이콘
작업명
```

작업명은 칸 너비 안에서 잘립니다. 패널은 배경이나 셀을 잡고 드래그할 수 있습니다.

## 아이콘 설정

메뉴바 고양이 아이콘을 클릭한 뒤 `Settings...`를 엽니다.

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

이모지 설정이 이미지 설정보다 우선합니다.

## 알림

세션이 `review` 상태로 바뀌면 알림을 보냅니다.

```text
🐱❓ Codex needs review
<작업명>
```

알림 끄기:

```bash
CATDEX_NOTIFY=0 catdex "조용한 작업"
```

## 정리와 점검

완료/실패/stale 세션 정리:

```bash
catdex cleanup
```

설치와 상태 저장소 점검:

```bash
catdex doctor
```

## 개발

```bash
swift test
swift build --product CatdexMenu
scripts/build-app.sh
```

자세한 사용법은 [docs/USAGE.md](docs/USAGE.md)를 참고하세요.

</details>
