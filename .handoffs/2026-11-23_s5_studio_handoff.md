# 인계: Glimmerkins MVP1 — 집 Windows 환경 준비 · S5 구현 · Studio 확인 중단 지점 (2026-11-23)

저장소 `roblox-game`(main, origin = GitHub 비공개). 이 메모와 같은 커밋에 S5 코드가 들어 있다. 상세 근거는 `docs/game_mvp1_impl_plan.md` 끝 "진행 기록"의 2026-11-23 항목 3개.

## 0. 다음에 시작할 때 (집 Windows)
1. `git pull` → `CLAUDE.md` 확인.
2. 도구는 이미 설치됨: `.tools/bin/rojo.exe`(7.7.1), `.tools/bin/lune.exe`(0.11.1). Roblox Studio·Rojo 플러그인 설치됨. 테스트 장소는 Studio 시작 화면의 **Glimmerkins Test**(지난번 확인은 새로 만든 `11232026_1` 장소에서 했음 — 어느 쪽이든 Mock이라 무관하지만 앞으로는 Glimmerkins Test 사용 권장).
3. 콘솔이 cp932라 econ_sim 한국어 출력이 깨지면 `PYTHONUTF8=1`(사용자 환경 변수) 또는 `PYTHONIOENCODING=utf-8`.
4. 확인: `.tools/bin/lune run game/tests/lune_run.luau` → 매핑 오류 0 · vectors 123/30/0 · **unit 192/0 (24 suites)**.

## 1. (2026-11-24 완료) S5 Studio 재확인 — 결과는 계획서 진행 기록 2026-11-24
1. Claude가 `rojo serve` 실행(cwd 저장소 루트, 백그라운드).
2. 사용자: Studio에서 Rojo **Connect** → 편집 상태 Explorer에 `StarterPlayer > StarterPlayerScripts > Client`(Main·Controllers)와 `ServerStorage > Tests > ValidateSpec`이 있는지 확인 → **Play**.
3. 기대 출력: `[unit] UNIT PASS 192 / FAIL 0 (24 suites)`, `[World] MeadowWorld 생성: 부지 8개`, `[Client] GameData OK (17 files)`, 빨간 오류 없음.
4. 화면: 왼쪽 위 HUD `Dew 0 · Bloom 0 · Wick 21 · Meadow Materials 0`, 오른쪽 위 `Daily ready`. 모바일 가로(Device Emulator)에서 Roblox 메뉴·조이스틱·점프 버튼과 겹치지 않는지.
5. 잘못된 인자 거부: Play 중 테스트 탭에서 **클라이언트**로 바꾸고 명령 바에
   ```lua
   local r=game.ReplicatedStorage.Remotes; print(r.Craft:InvokeServer("wick_from_meadow", 0/0).code, r.GatherStart:InvokeServer(123).code, r.Craft:InvokeServer("wick_from_meadow","5").code, r.GatherStart:InvokeServer("meadow_dew").code, r.GetSnapshot:InvokeServer().ok)
   ```
   기대 `BAD_ARG BAD_ARG BAD_ARG NOT_IMPLEMENTED true`(세 번째가 `RATE_LIMITED`여도 정상). 서버 출력에 `[Net] ... 잘못된 인자 거부` 경고.
6. 레이트(선택): `local r=game.ReplicatedStorage.Remotes.ClaimDaily; local t={} for i=1,5 do t[i]=r:InvokeServer().code end print(table.concat(t," "))` → `NOT_IMPLEMENTED RATE_LIMITED ×4`, 추방 없음.
7. 정지 시 `저장 성공(Mock)`.

## 2. 지난번 Studio 1차 확인 결과 (부분)
- 확인됨: 월드 생성(부지 8개), 자기 부지 스폰, 받침대·전시대 표시, Mock 불러오기·저장.
- 미확인: HUD·클라이언트·Remote 거부. 원인은 S5 작업 중 `rojo serve`가 종료돼(Rojo 7.7.1 패닉) **새 파일이 Studio에 동기화되지 않은 것**(unit 136/18로 확인). 코드 문제 아님.
- 교훈: 파일을 대량으로 바꾼 뒤에는 `rojo serve`를 재시작하고 Studio에서 다시 Connect한 뒤 Explorer에서 새 파일 존재를 확인하고 Play.

## 3. 알려진 문제 — (2026-11-24) "Coming soon" 겹침은 예약 자리를 (22, 22)로 옮겨 해결
- crystal_forge 예약 자리 "Coming soon" 표지가 스폰 위치와 겹쳐 캐릭터를 가린다 → `World/MeadowBuilder.luau`·`Config.WORLD` 좌표 조정.
- 재확인에서 나오는 다른 화면 지적과 묶어서 한 번에 고친다.

## 4. 사용자 결정 (2026-11-24 결정됨, 계획서 끝 기록)
1. HUD 이동 버튼 → **`Travel(dest)` Remote 신설**(포획 중 BUSY 거부, 이동 시 채집 정지). 회사 Mac에서 구현 완료(Studio 미검증).
2. 귀환 수확 요약 → **현행 유지**(Ack Remote 없음).
3. Max Players = 8 → 다음 Studio 확인 때 사용자가 Game Settings에 설정.

## 4-1. 2026-11-24 회사 Mac 작업분의 Studio 확인 체크리스트 (S5 재확인과 함께)
- (a) 새 파일이 있으므로 `rojo serve` 재시작 → Connect → Explorer에 `ServerScriptService.Server.Services.TravelService`·`ServerStorage.Tests.TravelSpec`·`ReplicatedStorage.Remotes.Travel`(RemoteFunction) 확인 → Play. 기대 `[unit] UNIT PASS 216 / FAIL 0 (26 suites)`(2026-11-25 병합 후 Lune 기준).
- (b) 오른쪽 위 Daily 아래 **Meadow·Home 버튼**: Meadow → 초원 입구에서 필드 쪽을 봄, Home → 자기 부지 스폰에서 집 쪽을 봄. Device Emulator 모바일 가로에서 점프 버튼·조이스틱·Roblox 메뉴와 겹치지 않음.
- (c) 클라이언트 명령 바: `local r=game.ReplicatedStorage.Remotes.Travel; print(r:InvokeServer("Meadow").code, r:InvokeServer(1).code)` → `BAD_ARG` (두 번째는 `RATE_LIMITED`여도 정상).
- (d) 스폰 직후 캐릭터가 표지에 가리지 않음, crystal_forge "Coming soon" 표지가 집 오른쪽 뒤(부지 로컬 (22,22))에 있고 스폰은 (0,-12) — 2026-11-25 병합에서 집 PC 배치(3c15af1, Studio 확인 완료)를 채택했으므로 회귀 확인만.
- (e) 이동 시 채집 정지: 2026-11-25 병합에서 GatherService·Activity를 TravelService에 연결함 → 채집 중 Meadow/Home을 누르면 칩이 사라지고 그때까지 적립된 Dew가 지갑에 남는지 확인. 포획 중 거부(BUSY)는 S7에서 CaptureService 연결 뒤 확인(Main TODO(S7)).
- (f) Game Settings 최대 인원 8 설정.
- (g) 리뷰 Minor 확인: 작은 가로 모바일(iPhone SE·360×640급 Android)에서 Meadow·Home 버튼과 실패 안내가 점프 버튼과 겹치는지, 버튼을 1초 안에 두 번 누르면 "can't travel" 안내가 뜨는지(현행 동작), 사망 후 리스폰 대기 중 Travel 동작.

## 4-2. 사용자 판단 대기 (2026-11-25 리뷰 Minor, 계획서 끝 기록)
1. TravelService 주입 누락 시 제약이 조용히 꺼지는 위험 대책(권장: 세션 서비스 묶음 테이블 공유 + S6·S7 완료 기준에 Travel 확인 추가) — **S6 착수 전에 결정**.
2. 버튼 연타 UI 디바운스(응답 대기 중 무시·RATE_LIMITED 무표시) 여부.
3. 사망 후 리스폰 대기 중 Travel 처리(유지 / Health 조건 추가).
4. 모바일 겹침이 확인되면 안내를 화면 위쪽 토스트로 옮길지.

## 4-3. 미룬 작업
- S6은 집 PC에서 구현됨(ce421ee). 2026-11-25 병합에서 TravelService에 gather·activity를 연결했다(Capture는 S7).

## 5. 그 뒤 순서
S5 완료 → S6(직접 채집: GatherStart/Stop 결선, 1초 거리 재확인, ProximityPrompt → 기존 RF) → S7(외형 레지스트리·야생·포획) → S8(시설·방치·귀환 요약 화면) → S9(일일·제작) → S10(통합·실제 DataStore 재접속·2인 서버·리뷰). 각 단계에서 `Remoting.bind(name, fn, {mutates=true})`로 결선하고 SessionCleanup(PlayerRemoving은 releaseAsync 전, BindToClose는 closeAll 전)을 함께 넣는다.

## 6. (2026-11-24) S6 진행 상태
- S6 구현·Lune 검증 완료(unit 204/25), Studio 기동·테스트까지 확인. **다음에 할 일 = S6 채집 상호작용 Studio 확인**: Dew 노드에서 E → 칩 `Gathering Dew +160/h`·Dew 약 22.5초에 1 증가 → 원 밖으로 나가면 1초 안에 멈춤·토스트 → 연타해도 증가 속도 동일 → Bloom 노드는 +161/h → 정지 시 `저장 성공(Mock)`, `정리 실패` 없음.
- 교훈: 이전 세션의 `rojo serve`가 남아 있으면(포트 34872 점유) 새로 띄우지 말고 그 PID를 끄고 다시 띄운 뒤 Studio에서 변경 Accept. Studio 시작 창과 장소 창이 같이 떠 있으면 컴퓨터 조작 시 포커스가 시작 창으로 가므로 시작 창을 닫고 진행.
- 남은 판단: 계획서 진행 기록 2026-11-24 S6 항목 끝.
