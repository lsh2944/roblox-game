# roblox-game — 빛 정령 방치·수집 Roblox 게임

1인 개발, 광고비 없는 수익형 전 세계 대상 게임. 코드는 Claude(Luau·Python), Roblox Studio 작업·게시는 사용자가 맡는다. Git 저장소(2026-11-12 초기화·첫 커밋 b511e25, 브랜치 main, GitHub 비공개 저장소로 회사 macOS와 집 Windows에서 공유).

## 작업 시작 시 (필수)
- **먼저 OS를 확인한다**(환경 정보 Platform `darwin`/`win32`, 애매하면 `uname -s`). 회사 = macOS(Apple Silicon, zsh), 집 = Windows(Git Bash 권장). Python 명령(`python3` vs `py -3.12`), 도구 바이너리(`.tools/bin/*` vs `*.exe`), 경로·셸 문법이 다르다. OS별 명령과 새 PC 준비는 `docs/dev_environment.md`.
- `git pull`로 다른 PC의 변경을 받은 뒤 작업한다. commit·push는 사용자 요청 시 Claude가 한다(2026-11-12 사용자 결정, origin = GitHub 비공개 저장소에 한함. force push·원격 브랜치 삭제·히스토리 재작성은 별도 승인).

## 사용자에게 선택지를 제안할 때 (사용자 요청 2026-11-12)
- 선택지마다 **안정성 관점**을 함께 적는다: 버그가 생길 가능성(중간 상태·부분 실패·경합·번호/순서 어긋남 등 구체적 원인), 서버·네트워크·Roblox API 장애·저장 실패가 났을 때의 영향(데이터 손실·중복 지급·진행 차단 여부, 조용히 저장되는지), 테스트로 고정할 수 있는지, 범용성(다른 필드·기능·나중 확장에 그대로 쓸 수 있는지).
- 구현 편의보다 위 기준을 우선해 권장안을 고르고, 이전 권장을 이 기준으로 뒤집게 되면 그 사실과 이유를 밝힌다.

## 구성
- `default.project.json`: Rojo 프로젝트(2026-11-11~). `game/src/shared`→ReplicatedStorage.Shared, `game/src/server`→ServerScriptService.Server, `game/src/client`→StarterPlayerScripts.Client, `game/tests`→ServerStorage.Tests. data는 manifest 기준 파일별 명시 매핑(ReplicatedStorage.GameData, test_vectors만 ServerStorage.TestData) — data 파일을 추가하면 이 파일도 갱신한다. Rojo가 관리하는 폴더 안에 Studio에서 직접 만든 인스턴스는 동기화 때 지워질 수 있다.
- `game/src/{server,shared,client}`: Luau 게임 코드(각 스크립트 머리 주석에 배치 위치). 순수 모듈(Formulas·Economy·CaptureLogic·Ledger·IdleCalc)은 Roblox API 없이 Studio·Lune 양쪽에서 돈다. `game/tests`: 벡터 러너·Spec(Studio `Dev/TestRunner`와 Lune `lune_run.luau` 공용). `game/previews`: 외형 미리보기(매핑 안 함).
- 구현 계획: `docs/game_mvp1_impl_plan.md`(MVP1 meadow 수직 슬라이스, 끝의 사용자 결정 우선).
- `data/*.json`: 게임(Luau)과 econ_sim이 **함께 쓰는 계약 데이터**. 진입점 `data/manifest.json`, 공식 골든 벡터 `data/test_vectors.json`(Luau 테스트도 같은 파일 사용 예정), 생성물 `data/generated/`(직접 수정 금지, `gen-tables`로 생성).
- `tools/econ_sim`: 경제 시뮬레이터(Python 3.12 표준 라이브러리만). 사용법은 `tools/econ_sim/README.md`.
- `docs/`: 토론 문서(`*_debate_*.md`), 구현 계획서(`*_impl_plan.md`), 인계 메모(`*_handoff.md`). `outputs/`: 시뮬 결과(run_id별, Git 제외). `baselines/`: Git 도입 전 기준본(회사 Mac에만, Git 제외). `docs/dev_environment.md`: OS별 개발 환경.

## 설계 근거의 우선순위
1. 각 토론 문서 끝의 "사용자 결정"(나중 날짜가 앞 날짜를 대체)
2. 승인된 구현 계획서(개정 절 포함)
3. 토론 synthesis·인계 메모

memory는 탐색 안내로만 쓰고 수치·규칙은 위 문서와 현행 data/코드로 확인한다. 문서끼리 충돌하거나 결정이 비어 있으면 임의로 정하지 않고 사용자에게 묻는다.

## 게임 원칙 (변경은 사용자 결정 사항)
- 과금: 정령 판매·유료 뽑기·행운 상품·정령 스탯 직접 버프 상품 없음. 외형·편의 중심. 유료 차단 범위 = 포획 투입물·시도 수·확률(기존 과금 해금 단축은 유지).
- 유료 재료가 랜덤 결과(포획 등)에 쓰이면 간접 유료 랜덤이 된다. 확률 공개·`PolicyService` 확인이 필요하므로 설계 단계에서 표시한다.
- PvP 약탈 없음. 거래는 MVP 미구현(원칙만).

## 명령 (cwd: `tools/econ_sim`)
```
python3 -m unittest discover -s tests   # 전체 테스트
python3 -m econ_sim validate            # data 검증(ERROR 시 종료 코드 1)
python3 -m econ_sim gen-tables --check  # 생성 표 최신 여부
python3 -m econ_sim all --quick         # 20시드 빠른 일괄 실행
```
Luau (cwd: `roblox-game`, 도구는 `.tools/bin/`, Windows는 `*.exe` — Git Bash에서는 아래 그대로 실행 가능, Python은 Windows에서 `py -3.12`):
```
.tools/bin/lune run game/tests/lune_run.luau        # 벡터(PASS 123/SKIP 30·합계 153 고정, 2026-11-13 도감 개편)·단위 테스트·매핑 검사
.tools/bin/rojo build default.project.json -o <scratchpad>/test.rbxlx   # 프로젝트 유효성
.tools/bin/rojo serve                                # Studio 동기화(사용자가 Studio에서 Connect)
```
200시드 full 실행은 수십 분~수 시간 걸리므로 계획서·메인이 지정한 경우에만 실행한다.

## 작업 규칙
- 코드 주석은 일본어, README·docs는 한국어.
- `outputs/`의 기존 run은 덮어쓰거나 삭제하지 않는다. 실행마다 새 run_id·`--out`을 쓴다.
- 리뷰 기준은 Git(커밋·`git diff`). Git 도입(2026-11-11) 전의 비교는 `baselines/<날짜>_<라벨>/`을 썼다. 줄바꿈은 `.gitattributes`로 LF 고정(Windows CRLF 변환 금지).
- data 스키마·키를 바꾸면 소비자 양쪽(econ_sim 로더·검증기, Luau 모듈)과 `test_vectors.json`을 함께 확인한다.
- **Roblox 실환경 경계:** place 게시, Open Cloud API, 라이브 DataStore 쓰기, 개발자 상품·게임패스 생성/가격 변경은 사용자만 실행한다. Claude는 로컬 코드와 사용자 실행 절차만 준비한다.
- 도구(2026-11-11): Rojo 7.7.1·Lune 0.11.1 공식 바이너리를 PC마다 `.tools/bin/`에 둔다(Git 제외, PATH 미등록 — 전체 경로로 실행). 회사 Mac은 arm64판(brew는 Intel판이라 사용 불가), 집 Windows는 windows판. `selene`·`stylua`는 없다. 순수 모듈·벡터는 Lune으로 Claude가 검증하고, Roblox 고유 동작(Rojo JSON 변환·require 해석·DataStore·화면)은 Studio에서 사용자가 확인한다. Roblox Studio는 회사 Mac에 미설치(2026-11-11 확인). 도구 추가 도입은 사용자 승인 후에 한다.
- 구현 담당: `roblox-feature`. 큰 설계 단계는 사용자가 `/cross-check`(debate)를 요청하는 경우가 많다.
