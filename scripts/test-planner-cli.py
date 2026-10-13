#!/usr/bin/env python3
"""Exercise the CLI protocol and independent-process SQLite writers in a temporary store."""
import concurrent.futures
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/catdex').resolve())
with tempfile.TemporaryDirectory(prefix='catdex-planner-cli-') as root:
    env = {**os.environ, 'CATDEX_STATUS_DIR': root}

    def capture(request):
        result = subprocess.run([binary, 'capture', '--json'], input=json.dumps(request),
                                text=True, capture_output=True, env=env, check=False)
        return result.returncode, json.loads(result.stdout)

    request = {'requestID': 'retries', 'text': '메모: `$(do-not-run)` "quotes"\n원문 보존', 'candidates': []}
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        results = list(executor.map(capture, [request] * 6 + [
            {'requestID': f'parallel-{i}', 'text': f'작업 {i} 확인',
             'candidates': [{'title': f'작업 {i}', 'estimatedMinutes': 40}]}
            for i in range(12)
        ]))
    assert all(code == 0 and result['ok'] for code, result in results), results
    assert len({result['recordID'] for _, result in results}) == 13
    code, result = capture({'requestID': 'retries', 'text': 'overwrite attempt'})
    assert code != 0 and result['ok'] is False
    code, result = capture({'text': 'missing ID'})
    assert code != 0 and result['ok'] is False
    subprocess.run([binary, 'cleanup'], env=env, capture_output=True, check=True)
    with sqlite3.connect(Path(root) / 'planner.sqlite') as db:
        rows = [json.loads(row[0]) for row in db.execute("SELECT payload FROM planner_items WHERE kind='record'")]
    assert len(rows) == 13
    assert next(row for row in rows if row['id'] == 'retries')['text'] == request['text']
    print('PASS: 18 concurrent captures, retry deduplication, input errors, literal text, cleanup isolation')
