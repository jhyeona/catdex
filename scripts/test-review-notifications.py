#!/usr/bin/env python3
"""Exercise the real CLI monitor with isolated rollouts and a notification recorder.

No real Codex process, desktop notifications, or user session data are involved.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/catdex').resolve())
with tempfile.TemporaryDirectory(prefix='catdex-review-') as directory:
    root = Path(directory).resolve()
    workspace = root / 'project'
    workspace.mkdir()
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    codex_home = root / 'codex'
    (codex_home / 'sessions').mkdir(parents=True)
    status = root / 'status'
    notifications = root / 'notifications.jsonl'
    done = root / 'done'
    fake_codex = bin_dir / 'codex'
    fake_codex.write_text('#!/bin/sh\nwhile [ ! -e "$CATDEX_TEST_DONE" ]; do sleep 0.2; done\n')
    fake_codex.chmod(0o755)
    recorder = bin_dir / 'osascript'
    recorder.write_text(
        '#!/usr/bin/env python3\nimport json, os, sys\n'
        'with open(os.environ["CATDEX_TEST_NOTIFICATIONS"], "a") as f:\n'
        '    f.write(json.dumps(sys.argv[1:]) + "\\n")\n'
    )
    recorder.chmod(0o755)
    rollout = codex_home / 'sessions' / 'test.jsonl'
    rollout.write_text(json.dumps({'type': 'session_meta', 'payload': {'cwd': str(workspace)}}) + '\n')
    env = {
        **os.environ, 'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'],
        'CATDEX_STATUS_DIR': str(status), 'CODEX_HOME': str(codex_home),
        'CATDEX_NOTIFY': '1', 'CATDEX_TEST_DONE': str(done),
        'CATDEX_TEST_NOTIFICATIONS': str(notifications),
    }

    def append(payload, kind='response_item'):
        with rollout.open('a') as stream:
            stream.write(json.dumps({'type': kind, 'payload': payload}) + '\n')

    def alerts():
        return notifications.read_text().splitlines() if notifications.exists() else []

    def current_state():
        for path in (status / 'sessions').glob('*.json'):
            try:
                return json.loads(path.read_text())['state']
            except (ValueError, KeyError):
                continue
        return None

    def expect(state, count):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if current_state() == state and len(alerts()) == count:
                return
            time.sleep(0.1)
        raise AssertionError((state, count, current_state(), alerts()))

    def question(call_id):
        return {'type': 'function_call', 'name': 'request_user_input', 'call_id': call_id,
                'arguments': json.dumps({'questions': [{'question': '검증용 질문'}]})}

    process = subprocess.Popen(
        [binary, '--codex-bin', str(fake_codex), '--task', 'notification regression'],
        cwd=workspace, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    try:
        append({'type': 'task_started'}, 'event_msg')
        append({'type': 'custom_tool_call', 'name': 'functions.exec', 'call_id': 'slow',
                'input': 'await tools.exec_command({cmd:"swift test",sandbox_permissions:"require_escalated",justification:"테스트를 실행할까요?"});'})
        expect('responding', 0)
        time.sleep(4.5)  # Multiple monitor polls while the auto-approved tool has no output.
        assert current_state() == 'responding' and not alerts()
        append({'type': 'custom_tool_call_output', 'call_id': 'slow', 'output': 'done'})
        append(question('question1'))
        expect('review', 1)
        time.sleep(4.5)
        assert len(alerts()) == 1
        append({'type': 'function_call_output', 'call_id': 'question1', 'output': 'answered'})
        append(question('question2'))
        expect('review', 2)  # New question even if two polls see the same review state.
        append({'type': 'turn_aborted'}, 'event_msg')
        expect('failed', 2)
        append({'type': 'task_started'}, 'event_msg')
        append(question('already-finished'))
        append({'type': 'task_complete'}, 'event_msg')
        expect('waiting', 2)
        print('PASS: no escalation alert; one alert per pending question; answered/aborted/completed requests cleared')
    finally:
        done.touch()
        try:
            _, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.terminate()
            _, stderr = process.communicate(timeout=10)
        if process.returncode:
            raise AssertionError(f'catdex exited {process.returncode}: {stderr.decode()}')
