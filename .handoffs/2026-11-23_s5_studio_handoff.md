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

## 4. 사용자 결정 대기
1. HUD "Meadow"/"Home" 이동 버튼: Remote 계약에 없음 → `Travel(dest)` Remote 신설 여부.
2. 귀환 수확 요약을 클라이언트 확인 후 서버에서 지울지(Ack Remote 필요). 현재는 세션 동안 유지·클라이언트가 1회만 표시.
3. Experience Max Players = 8(W1): Studio Game Settings에서 사용자 설정.

## 5. 그 뒤 순서
S5 완료 → S6(직접 채집: GatherStart/Stop 결선, 1초 거리 재확인, ProximityPrompt → 기존 RF) → S7(외형 레지스트리·야생·포획) → S8(시설·방치·귀환 요약 화면) → S9(일일·제작) → S10(통합·실제 DataStore 재접속·2인 서버·리뷰). 각 단계에서 `Remoting.bind(name, fn, {mutates=true})`로 결선하고 SessionCleanup(PlayerRemoving은 releaseAsync 전, BindToClose는 closeAll 전)을 함께 넣는다.

## 6. (2026-11-24) S6 진행 상태
- S6 구현·Lune 검증 완료(unit 204/25), Studio 기동·테스트까지 확인. **다음에 할 일 = S6 채집 상호작용 Studio 확인**: Dew 노드에서 E → 칩 `Gathering Dew +160/h`·Dew 약 22.5초에 1 증가 → 원 밖으로 나가면 1초 안에 멈춤·토스트 → 연타해도 증가 속도 동일 → Bloom 노드는 +161/h → 정지 시 `저장 성공(Mock)`, `정리 실패` 없음.
- 교훈: 이전 세션의 `rojo serve`가 남아 있으면(포트 34872 점유) 새로 띄우지 말고 그 PID를 끄고 다시 띄운 뒤 Studio에서 변경 Accept. Studio 시작 창과 장소 창이 같이 떠 있으면 컴퓨터 조작 시 포커스가 시작 창으로 가므로 시작 창을 닫고 진행.
- 남은 판단: 계획서 진행 기록 2026-11-24 S6 항목 끝.
