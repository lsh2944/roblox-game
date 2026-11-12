# 인계: 빛 정령 Roblox 게임 — MVP1 진행·BM·개발 환경 (2026-11-12)

저장소: `roblox-game` (Git, 브랜치 `main`, origin = GitHub `lsh2944/roblox-game` 비공개). 이 파일 작성 시점 HEAD = `4d111aa`(origin과 동기). 이후 커밋은 `git log`로 확인.

## 0. 시작할 때
1. **OS 확인**(회사 macOS / 집 Windows) → 명령은 `docs/dev_environment.md`의 해당 OS 형태. Windows 첫 설정은 같은 문서 3절.
2. `git pull` 후 작업. commit·push는 사용자 요청 시 Claude(2026-11-12 결정).
3. 저장소 `CLAUDE.md`를 읽는다(작업 시작 규칙, 제안 시 안정성 비교 규칙, 명령, 실환경 경계).

## 1. 목표
- 광고비 없는 수익형 전 세계 대상 Roblox 방치·수집 게임(1인 개발). 코드는 Claude, Studio 작업·게시·상품 등록·push는 사용자.
- 현재 마일스톤: **MVP1 meadow 수직 슬라이스** — `docs/game_mvp1_impl_plan.md`(6절 S0~S10, 끝의 "사용자 결정"·"진행 기록"이 최신).

## 2. 확정 결정 (근거 문서 끝 "사용자 결정"이 우선, 나중 날짜 우선)
- 게임 규칙·경제: `docs/*_debate_*.md` 각 끝. 밤 = 게임 내 시계(현실 60분 = 하루, 매시 30~60분 밤, 전 세계 동기, `data/rules.json` night).
- MVP1: 종은 등롱 사용 시 공개, 동행·시설 배타, 시작 정령 자동 배치 안 함, 보관함 가득 → 포획 차단, 간편 모드·자동 연속 시도, 일일 초기화 UTC 0시, 잠금 TTL 300초, 플레이어 문구 영어 기본(`game/src/shared/Text.luau`), 배치 이동은 서버 원자적(`MoveSlot`, 찬 칸은 자리 바꾸기), 조우 이벤트는 시각에 맞춰 단계별 전송(결과·조우 길이 미리 공개 안 함), 미래 시각 값은 상한 초과 시 잘라냄, 진행 중 조우는 저장 안 함(서버 다운 시 손실 수용).
- BM: `docs/bm_monetization_debate_20261111.md` 끝. 16+ 먼저 공개, 외형·편의만, 재료 상자·초심자 패스 **완전 제거**(기본 재료 비매), 원칙 완화 없음, 반복 수익은 외형 시즌 패스 우선. 순서: 결제 기반 → 확정형 외형·칭호·서포터 → 유료 비공개 서버(방문과 함께) → 전시 꾸미기 → 보상형 광고(외형 보상) → 시즌 패스.
- 결제 기반: `docs/payment_foundation_plan.md` 끝(보관함 = 게임패스 10단계, 환불 시 권한 해제·정령 보존, 구독은 로직·테스트만·유예 6h, 보관함 불일치는 구매 기록 기준 재계산). **착수는 MVP1 S10 뒤**.
- 사용자 선호: 선택지 제안 시 버그 가능성·장애 영향·테스트 가능성·범용성 비교 후 안정성 우선 권장(`CLAUDE.md` 해당 절).

## 3. 현재 상태
- 완료(Lune 검증, **Studio 미검증**): S1(Rojo 프로젝트·GameData), S2(Formulas·벡터), S3(Economy·Ledger·CaptureLogic·IdleCalc), S4(저장·세션 잠금·오프라인 정산), S6~S9 **순수 로직·서비스**(Gather/WildSpawn/Capture/Roster/Facility/Quest/Craft, SessionCleanup, MoveSlot) + 리뷰 반영.
- 미착수(Studio 필요): S5(월드 MeadowBuilder·HUD·Remote 결선·스냅샷·1초 루프), S6~S9 Main 결선(TODO는 `game/src/server/Main.server.luau` 주석과 계획서 진행 기록: PlayerRemoving은 releaseAsync 전, BindToClose는 closeAll 전 SessionCleanup), 클라이언트 연출, S10 통합 확인·리뷰.
- econ_sim: 최신 quick 기준 run은 회사 Mac `outputs/20261111_no_material_products_q`(outputs는 Git 제외, 다른 PC에서는 같은 명령으로 재생성).

## 4. 검증 (2026-11-12, 회사 macOS)
- cwd 저장소 루트: `.tools/bin/lune run game/tests/lune_run.luau` → vectors PASS 100/SKIP 30/FAIL 0, unit PASS 119/FAIL 0(18 suites). `.tools/bin/rojo build default.project.json -o <scratchpad>/x.rbxlx` 성공.
- cwd `tools/econ_sim`: `python3 -m unittest discover -s tests` 204 OK, `validate` ERROR 0·WARN 0, `gen-tables --check` 최신.
- Windows에서는 미실행(인코딩·CSV 줄바꿈·spawn 방식은 정적 점검상 호환, `.gitattributes`로 LF 고정).

## 5. 미해결·다음 행동
1. **사용자**: Roblox Studio 설치(집 Windows 예정), 테스트용 Experience 분리 생성·API 접근은 그 Experience에서만.
2. Studio 준비 후: `.tools/bin/rojo plugin install` → `rojo serve` → Connect → Play로 TestRunner(vectors 100/0, unit 119/0)·"불러오기 성공(Mock, new)"·CaptureSample(Roblox Random 경계) 확인 → S5 착수(계획서 6절 S5 완료 기준).
3. 남은 결정(나중): 데이터 표시 이름 57건 영어화(권장: S5 이후 Localization 표), 채집·포획 반경 등 월드 임시값, D15 이후 사냥 재료 적체(별도 과제 ⑦), 시즌 패스 설계.
4. 출시 전 재확인 항목: `docs/bm_monetization_debate_20261111.md` 미확인 목록(게임패스·개발자 상품 생성 비용 등), 결제 계획서의 미확인 항목.

## 6. 참고
- 구현 담당 에이전트 정의: `.claude/agents/roblox-feature.md`(저장소 포함). 회사 Mac의 `/cross-check`·`task-metrics` 스킬은 저장소에 없다.
- 실환경 경계: place 게시·Open Cloud·라이브 DataStore 쓰기·상품 생성/가격 변경은 사용자만.
