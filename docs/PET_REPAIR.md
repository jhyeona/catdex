# Catdex 펫 크기 보정

2026-09-09에 기존 그림을 유지하면서 설치된 v1 펫을 보정했다. 메뉴바 앱이나 Codex 실행 파일은 변경하지 않았다.

- 데스크톱: 동작별 얼굴 크기를 기준으로 비례 확대·축소했다. 각 동작 안에서는 공통 배율을 사용해 프레임마다 크기가 달라지지 않도록 했다. 점프는 고정된 192×208 셀 안에서 캐릭터가 잘리지 않도록 이동 폭을 줄였다.
- 터미널: Codex CLI 0.153.2가 펫을 9×5 글자 칸에 표시한다. 현재 iTerm 셀은 14×34px여서 원본 그림의 가로가 약 20% 눌렸다. 투명 여백 안에서 가로를 약 1.245배 보정한 별도 펫을 설치했다.
- 데스크톱의 펫 표시 폭은 80에서 90으로 조정했다. 시트 안에 점프 여백을 확보하면서도 평소 캐릭터의 실제 표시 크기를 유지하기 위한 보정이다.

데스크톱은 `custom:catdex`, 터미널은 `custom:catdex-terminal`을 사용한다. **`Catdex (Terminal)`을 데스크톱에서 선택하면 가로 보정 때문에 넓게 보인다.** 터미널 보정은 현재 측정한 셀 비율과 CLI 배치 방식에 맞춰져 있다. 다른 폰트나 다른 터미널을 쓰거나 CLI의 이미지 배치 방식이 바뀌면 다시 측정해야 한다.

이번 설치 방식 수정은 기존 `Catdex (Terminal)`에 덮어쓴다. 같은 ID와 폴더를 사용하므로 펫 항목이 추가되지 않는다. 데스크톱용 `Catdex` 이미지와 표시 폭은 수정하지 않으며, 데스크톱에서 터미널용 펫을 선택한 경우에만 선택을 `Catdex`로 바로잡는다. 다른 데스크톱 펫을 선택한 경우에는 그 선택을 유지한다.

## 설치 파일과 확인 자료

- `~/.codex/pets/catdex/pet.json`: 데스크톱용. 해시가 포함된 시트 파일명으로 오래된 이미지 캐시를 피한다.
- `~/.codex/pets/catdex-terminal/pet.json`: 기존 항목에 덮어쓰는 터미널용. 이미지 해시가 포함된 파일명으로 캐시를 갱신한다.
- `~/.codex/pet-backups/catdex/20260909T031437748054Z/`: 원본 펫, 변경 전 설정, 설치 내역.
- `~/.codex/pet-backups/catdex-terminal/<설치 시각>/`: 덮어쓰기 직전의 터미널 펫과 설정 백업.
- `build/pet-repair/validation.json`: 57개 사용 프레임, 15개 빈 셀, 잘림, 얼굴 크기, 무손실 저장 검증.
- `build/pet-repair/visual-qa.json`: 독립 시각 검토 결과.
- `build/pet-repair/motion.gif`: 보정한 동작 전환 미리보기.
- `build/pet-repair/terminal-comparison.png`: 보정 전·후와 정상 비율 기준 이미지 비교.
- `build/pet-repair/installation.json`: 최초 설치 경로와 파일 해시.
- `build/pet-repair/terminal-installation.json`: 최근 터미널 펫 덮어쓰기 내역과 파일 해시.
- `build/pet-repair/terminal-install-smoke.json`: 반복 덮어쓰기, 데스크톱 보존, 백업, 실패 복구, 동시 설정 변경 보존 등 7개 설치 검증 결과.

실행 중인 CLI는 이미 로드한 펫을 계속 사용할 수 있다. `/pet`에서 `Catdex (Terminal)`을 다시 선택하거나 다음에 `catdex`를 실행하면 새 설정을 사용한다. 데스크톱에서 이전 그림이 남으면 `Catdex`를 다시 선택해 불러온다. 설치 스크립트는 실행 중인 앱이나 터미널을 재시작하지 않는다.

## 재현

`scripts/repair-catdex-pet.py`는 Pillow와 NumPy가 설치된 Python에서 실행한다. 원본 해시를 검사하므로 이미 보정된 그림을 중복 보정하지 않는다. 아래 원본 경로는 백업의 `catdex/spritesheet.webp`를 사용한다.

```sh
python scripts/repair-catdex-pet.py ORIGINAL.webp build/pet-repair \
  --cell-width 14 --cell-height 34
python3 scripts/install-catdex-pet.py build/pet-repair
python3 scripts/install-catdex-pet.py build/pet-repair --apply
```

설치 스크립트는 기본적으로 변경 내용을 출력한다. `--apply`가 있어야 설치하며, 검증 파일·시각 검토·터미널 이미지 해시·기존 펫 ID·현재 펫 선택을 확인하고 백업을 만든다. 기존 `catdex-terminal` 폴더가 있어야 하며 반복 덮어쓰기를 지원한다. 데스크톱 선택을 바로잡기 전에는 `Catdex`가 검증된 정상 비율 이미지인지 확인한다. 설치 도중 실패하면 변경한 터미널 파일을 복구한다. 재현한 결과는 다시 시각 검토한 뒤 설치해야 한다.
