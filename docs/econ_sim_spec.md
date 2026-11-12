# 경제 시뮬레이터 구현 명세 (2026-11-06, 메인 작성)

## 배경
신규 Roblox 방치·수집 게임(빛 정령 테마, 아직 게임 코드 없음)의 밸런스를 출시 전에 검증하는 Python 도구.
설계는 Claude·Codex 토론으로 확정됐다. 상세 근거:
- 통합 결정: /Users/leeseunghak/project/.local/co-design/20261106T024157Z-ecaa78/artifacts/synthesis.md
- 양측 원안(CSV 열·공식·지표 초안 등 세부 참고): 같은 폴더의 codex/proposal.json, claude/proposal.json
- 원안과 통합 결정이 다르면 통합 결정·아래 명세를 따른다.

## 위치·제약
- 루트: /Users/leeseunghak/project/roblox-game/ (새로 만든다. Git 미사용 영역)
  - data/ : 공용 JSON(게임 Luau도 나중에 사용)
  - tools/econ_sim/ : 시뮬레이터 패키지, tests/, README.md
  - outputs/ : 실행 결과(실행 시 생성)
- Python 3.12 표준 라이브러리만. 외부 패키지·네트워크 호출 금지.
- roblox-game/ 밖의 파일은 수정하지 않는다.
- 코드 주석은 일본어, README·사용자 대상 문서는 한국어.

## 사용자 확정 규칙
1. 루프: 필드(직접 채집·사냥·포획) → 거점 시설 배치(방치 생산, 접속 중·오프라인 모두) → 시설·정령·도구 강화 → 다음 필드 해금.
2. G2: 직접 채집 추가 획득량 / 동일 상태 방치량 = 시간당 비율 R. 목표 2배, **항상 최대 3배**(초반 예외 없음). 하루 직접 비중 S도 보고만 한다(합격 기준 아님).
3. G3: 직접 플레이 전용 재료(사냥 드롭) 1건 요구량 = 그 단계 사냥 10~30분 분량 목표. 방치 유저는 일일 의뢰로 소량 획득.
4. 자원: 기본 3종(dew/bloom/crystal) + 사냥 재료 + 연구 포인트(놓아주기 보상). 기본 재료만 purchasable=true 가능.
5. 정령 10종 가안(brief 값): 반짝이★1 B/B/C 3/5, 이슬방울★1 A/C/— 2/6, 꽃등★1 C/A/— 2/6, 조각빛★2 —/C/A 5/5(큰 결정 노드), 노을새★2 B/B/B 6/4(동행 시 사냥 드롭+15%, 거점 −20%), 무지개 나비★3 A/A/C 4/8(혼합 배치 보너스), 등대곰★3 —/—/D 12/3, 달빛 여우★3 S/C/C 7/7(밤 보너스), 그림자 등불★4 C/—/S 11/6, 오로라 사슴★4 A/S/A 9/9. 적성 S1.5/A1.2/B1.0/C0.6/D0.3/—0.
6. 포획: 무료 랜덤, 천장 없음, 중복 제한 없음(모든 종 max_owned=0=무제한), 전체 보유 상한(기본 30, 거점 등급·유료 보관함으로 확장). 넘치면 놓아주기 → 연구 포인트. 포획 비용에 purchasable 자원 사용 금지(검증기 FAIL).
7. 2주판 정령(데이터에 ID 목록으로 명시)은 **두 필드 합집합** 중 어딘가에서 상시 획득 가능해야 한다(검증기 검사).
8. 유지비: **없음**(upkeep 필드는 스키마에 두되 모두 비움/0). 밤 보너스는 스키마에 두되 초기 데이터에서 효과 0 또는 미사용으로 둬도 된다(시간 구간 분할 로직은 구현).
9. 오프라인 상한 기본 12시간, 게임 내 업그레이드로 24시간까지.
10. BM: 정령 판매·유료 랜덤·확률/행운·정령 스탯 버프 효과는 검증기가 거부. 허용 상품 kind: cosmetic(시뮬 효과 0), storage_expand, placement_preset(효과 0), basic_material_pack(구매 직전 단계의 표준 무과금 방치율 × N시간, 기본 재료만), beginner_pass(가이드 미션별 추가 보상, 소급 지급).
11. 강화 곡선 가안: 시설 비용 ceil(base×1.15^(L−1)), 시설 생산 (1+0.10×(L−1))×Π(Lv10, Lv25에서 ×2), 정령 비용 ceil(base×1.12^L), 정령 능력 ×(1+0.04×(L−1)). 선형 해석. 곡선 설정 → 정수표 생성.

미정 수치(필드 수·해금 비용·포획 확률·조우 가중치·사냥 드롭·의뢰 지급량·도구 곡선·상품 수량·페르소나 일정 등)는 합리적 placeholder로 채우고 데이터에 `"placeholder": true`나 notes로 표시하며, run 메타에 placeholder 목록을 남긴다. 필드는 최소 4개(2주판 2 + 4주판 2) 가안.

## 통합 설계 요지 (synthesis 요약)
- 데이터: 순수 JSON(주석·null·NaN 금지), 배열+id 또는 명시적 순서. 검증기는 표준 라이브러리 mini validator: 타입·필수·enum·교차참조·금지 규칙·2주판 접근성·고등급 Pareto 지배 경고.
- 곡선 설정 → 결정적 정수 강화표 생성(+설정·표 sha256), 정적 분석·시뮬·게임이 같은 표 사용. test_vectors.json(공식 입출력 골든 벡터).
- static 서브커맨드: 시설 회수기간표(정규화 값임을 명시), 정령 지배표, 해석적 포획 분위수(고정 확률에만), 사냥 분 환산표(G3), R(G2) 정적 계산.
- 시간: 사건 기반 정수 분. 생산률 일정 구간만 닫힌식, 상한·(밤) 경계에서 분할. 활동 결정 간격 5분.
- 정책: 다음 필드 해금 ETA를 줄이는 강화 구매, 병목 기반 활동 선택, 배치는 휴리스틱(탐욕+2-swap), 결과는 '발견한 배치'로 표기.
- 페르소나: idle_once(하루 1회 5분), idle_twice(12시간 간격 2회 5분), balanced(180분: 채집60/사냥60/포획·관리30/꾸미기30), hardcore(360분), balanced_paid(balanced와 동일 일정+초심자 패스·재료팩). 60일 실행, 30일 결과 추출.
- 난수: sha256(master_seed, pairing_group_id, replicate_id, stream) 파생. 구매 여부·persona_id는 키에서 제외해 비교군 공통 난수.
- 통계: 모든 실행 observed·censor_time 기록, 도달률·미획득률 병기. 반복 수 기본은 작게(--quick 20, 기본 200), 처리량 측정 후 조정.
- 판정: checks에 estimate, draft_evaluation(PASS/WARN/FAIL), approval_state(draft/approved), evidence_status. 규칙 위반은 FAIL. criteria.json에 초안 임계값.
- 출력: CSV(daily, events, spirit_daily, capture_stats, allocation, checks, facility_payback, g3_hunt_minutes) + manifest.json + report.html(외부 URL 0, 인라인 SVG, 판정 요약 상단).
- 수렴 분석: 소수의 대표 상태에서 정확 탐색(작은 조합) + 종 제외 손실. 증명 안 된 결과는 추정으로 표시.
- 테스트(unittest): 공식·정수표 생성, 검증기(정상+broken fixture), 결정성(같은 입력→같은 CSV 바이트), 오프라인 경계, 패스 소급 중복 방지, 비교군 공통 난수, 배치 휴리스틱 vs 작은 전수 탐색, HTML에 외부 URL 없음, e2e smoke.
