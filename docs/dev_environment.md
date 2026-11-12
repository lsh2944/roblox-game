# 개발 환경 (회사 macOS · 집 Windows)

작성 2026-11-11. 이 게임은 회사 Mac과 집 Windows PC 두 곳에서 같은 Git 저장소(`roblox-game`, GitHub 비공개)로 개발한다.

## 1. 작업 시작 시 확인 (Claude·사람 공통)

1. **OS 확인**: Claude Code는 환경 정보의 Platform(`darwin` / `win32`)을 먼저 보고, 애매하면 `uname -s`(Git Bash) 또는 `$env:OS`(PowerShell)로 확인한다. 아래 표에서 그 OS의 명령을 쓴다.
2. **최신 상태 받기**: `git pull` 후 작업한다. 다른 PC에서 push하지 않은 변경이 있으면 먼저 그쪽에서 커밋·push한다(두 PC에서 같은 파일을 동시에 고치지 않는다).
3. **도구 확인**: `.tools/bin`의 Rojo·Lune 버전이 아래 기준과 같은지 확인한다(`--version`).
4. 작업을 마치면 커밋·push한다. 사용자가 요청하면 Claude가 커밋·push까지 한다(2026-11-12 결정. force push·원격 브랜치 삭제는 별도 승인).

## 2. OS별 차이

| 항목 | 회사 Mac (macOS, Apple Silicon) | 집 Windows |
|---|---|---|
| 셸 | zsh | **Git Bash 권장**(Claude Code 기본). PowerShell이면 경로 구분자·명령이 다르다 |
| Python | `python3` (3.12, 표준 라이브러리만) | `py -3.12` 또는 `python`. `python3`은 Microsoft Store 바로가기일 수 있으니 `py -3.12 --version`으로 확인 |
| Rojo·Lune 바이너리 | `.tools/bin/rojo`, `.tools/bin/lune` (`*-macos-aarch64.zip`) | `.tools/bin/rojo.exe`, `.tools/bin/lune.exe` (`*-windows-x86_64.zip`, 이름은 릴리스 페이지에서 확인). Git Bash에서는 `.tools/bin/lune`처럼 `.exe` 없이도 실행된다 |
| Homebrew | Intel판(`/usr/local`)이라 Rojo·Lune 설치에 쓰지 않는다 | 해당 없음 |
| Roblox Studio | 미설치(2026-11-11) | 설치해서 사용 |
| 임시 파일 | Claude scratchpad | Claude scratchpad(경로가 다르므로 문서에 절대경로를 고정하지 않는다) |
| 줄바꿈 | LF | `.gitattributes`로 LF 고정. 편집기도 LF로 저장 |

공통 명령(cwd는 저장소 루트 `roblox-game`, Git Bash와 zsh에서 같은 형태):

```
cd tools/econ_sim && <python> -m unittest discover -s tests   # <python> = python3(Mac) / py -3.12(Win)
<python> -m econ_sim validate
<python> -m econ_sim gen-tables --check
cd ../.. && .tools/bin/lune run game/tests/lune_run.luau
.tools/bin/rojo build default.project.json -o <scratchpad>/test.rbxlx
.tools/bin/rojo serve        # Studio에서 Connect
```

## 3. 새 PC 준비 (집 Windows 첫 설정)

1. Git for Windows 설치(Git Bash 포함), Python 3.12 설치("Add to PATH"), Roblox Studio 설치·로그인.
2. Claude Code 설치. 회사 Mac의 개인 전역 지침(`~/.claude/CLAUDE.md`, 한국어 응답 등)은 PC마다 따로라서 필요하면 같은 내용을 Windows의 사용자 폴더 `.claude/CLAUDE.md`에 둔다. 회사 업무 관련 지침·도구는 옮기지 않는다.
3. 저장소 받기: `git clone <비공개 저장소 URL> roblox-game` → `cd roblox-game` → `git config user.email "<개인 이메일 또는 GitHub noreply>"`.
   - GitHub 인증은 PC마다 따로 한다. 다른 PC의 토큰을 옮기지 않는다(GitHub에서는 토큰 값을 다시 볼 수 없고, 토큰을 옮기면 유출 위험이 있다).
   - 권장: Git for Windows에 포함된 Git Credential Manager를 쓴다. 처음 clone/push할 때 브라우저 창이 뜨면 GitHub에 로그인한다. 인증 정보는 그 PC의 Windows 자격 증명 관리자에 저장된다.
   - 브라우저 로그인이 안 되면 GitHub ⟩ Settings ⟩ Developer settings에서 fine-grained token을 그 PC 전용으로 새로 만든다(이 저장소만, Contents read/write, 만료일 지정). 처음 push할 때 비밀번호 칸에 넣는다. PC를 잃어버리면 그 토큰만 폐기한다.
   - 회사 Mac은 macOS 키체인(`credential.helper=osxkeychain`)에 저장되어 있어 다시 입력할 필요가 없다(2026-11-12 확인).
4. `.tools/bin/`에 Rojo 7.7.1·Lune 0.11.1 Windows용 zip을 GitHub 공식 릴리스에서 받아 푼다(`.tools/`는 저장소에 없다).
5. Studio 플러그인: `.tools/bin/rojo plugin install` (Studio를 한 번 실행한 뒤).
6. 확인: 2절 공통 명령 중 unittest·validate·lune run이 통과하면 준비 완료.

## 4. 저장소에 없는 것 (PC마다 따로)

- `outputs/`(시뮬 결과, 다시 만들 수 있음), `baselines/`(Git 도입 전 기준본, 회사 Mac에만 있음), `.tools/`(바이너리).
- Claude memory(PC별). 게임 결정·수치의 근거는 `docs/`의 각 문서 끝 "사용자 결정"과 `CLAUDE.md`에 있으므로 memory 없이도 이어서 작업할 수 있다.
- 문서에 남은 `outputs/<run_id>` 참조는 회사 Mac에서 만든 결과다. 다른 PC에서 비교가 필요하면 같은 명령으로 다시 만든다(결정적 시뮬이라 같은 결과가 나와야 한다).
