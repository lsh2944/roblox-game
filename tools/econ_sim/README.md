# econ_sim — 경제 시뮬레이터 (1단계)

빛 정령 테마 방치·수집 Roblox 게임의 밸런스를 출시 전에 숫자로 확인하는 도구다. Python 3.12 표준 라이브러리만 쓰고 네트워크를 호출하지 않는다.

- 1단계: 공용 데이터 JSON, 검증기, 곡선 → 정수 강화표 생성, 순수 공식, 난수 파생, `static` 정적 분석
- 2단계: 페르소나 시뮬레이션(`run`), 대표 상태 수렴 분석(`converge`), 지표·판정·HTML 리포트(`report`), 일괄 실행(`all`)

## 폴더 구조

```
roblox-game/
├── data/                         # 게임(Luau)과 시뮬레이터가 함께 쓰는 순수 JSON
│   ├── manifest.json             # 진입점: 파일 목록(id·path·role)
│   ├── resources.json            # 자원(기본 3종·사냥 재료·연구 포인트·제작물 craft), purchasable, stack·trade_class 등 선택 키
│   ├── rules.json                # 적성 bps, 공식 상수, 게임 내 시계(밤)
│   ├── spirits.json              # 정령 10종, 특성, 놓아주기 보상
│   ├── curves.json               # 강화 곡선 설정(생성 근거)
│   ├── facilities.json           # 거점 시설(슬롯·필드별 레벨 상한·사냥 재료 게이트)
│   ├── tools.json                # 플레이어 도구
│   ├── fields.json               # 필드 4개(채집 노드·사냥·포획표)
│   ├── hub.json                  # 보관함·거점 등급·오프라인 상한
│   ├── daily_quests.json         # 일일 의뢰(방치 유저의 사냥 재료 경로)
│   ├── products.json             # 과금 상품(허용 kind만)
│   ├── releases.json             # 2주판/4주판 필드·정령 ID 목록
│   ├── research.json             # 연구 트리(예산 원장·슬롯·노드 10개, 2026-11-09)
│   ├── capture.json              # 전역 포획 규칙(심지·성공률·빛 구간·도망·시간·보급·약화 시간·활력/먹이, 2026-11-10 단계 2부터 시뮬이 사용)
│   ├── crafting.json             # 제작 레시피(심지·먹이 stock, 길표·부품 atomic)
│   ├── sinks.json                # 소비처(집 4~9단계·가구·의상, 반복 제단·모듈, 도감 기록). 효과 0
│   ├── variants/wick_recipe_codex.json # 심지 레시피 B 비교 패치(manifest 밖, --patch용)
│   ├── test_vectors.json         # 공식 골든 벡터(Luau 테스트도 같은 파일 사용 예정)
│   └── generated/upgrade_tables.json, sink_tables.json # gen-tables가 만드는 정수 강화표·소비처 반복 비용표(직접 수정 금지)
├── tools/econ_sim/
│   ├── README.md
│   ├── config/
│   │   ├── static_reference.json # static 기준 상태(정규화 가정)
│   │   ├── criteria.json         # 판정 임계값(approved/draft 구분, sim 블록은 시뮬 초안 기준)
│   │   └── personas.json         # 페르소나 6종(연구 모드 off/natural/cap, 심지 모드 required/unlimited)·시작 정령·정책 설정·master_seed·반복 수
│   ├── econ_sim/                 # 패키지
│   │   ├── __main__.py, cli.py   # 명령 입구(validate / gen-tables / static)
│   │   ├── paths.py              # 기본 경로(실행 cwd와 무관)
│   │   ├── jsonio.py             # 엄격 JSON(중복 키·NaN·BOM 거부), 정준 해시, 원자적 쓰기
│   │   ├── schema.py             # 표준 라이브러리 mini 스키마 검증기
│   │   ├── data_load.py          # manifest 기반 로더, 패치(ops), placeholder 수집
│   │   ├── model.py              # 데이터 인덱스·요구 비용 열거(검증·static·2단계 sim 공용)
│   │   ├── validate.py           # 스키마·참조·게임 규칙·표 최신 여부·지배 경고
│   │   ├── formulas.py           # 순수 공식(Luau Formulas 모듈로 1:1 이식 대상)
│   │   ├── tables.py             # 곡선 → 정수표 생성 + sha256
│   │   ├── rng.py                # sha256 기반 난수 파생
│   │   ├── dominance.py          # 정령 Pareto 지배표
│   │   ├── static_analysis.py    # static CSV 5종 + 메타
│   │   ├── report_html.py        # 외부 URL 없는 단일 HTML 부품(표·인라인 SVG 그래프)
│   │   ├── economy.py            # 상태 무관 경제 계산(시설 생산·직접 채집·사냥, 캐시)
│   │   ├── state.py              # 플레이어 상태·일별 집계(양은 milli 정수)
│   │   ├── placement.py          # 배치: 휴리스틱(탐욕+2-swap+연쇄 이동)·정확 탐색(부분집합 DP)·1시설 엄밀 최적(best_single, 종별 DP)
│   │   ├── policy.py             # 행동 정책(해금 ETA 기반 구매·병목 활동·동행 선택)
│   │   ├── sim.py                # 사건 기반 1인 시뮬(정수 분, 오프라인 상한·밤·일 경계 분할)
│   │   ├── sim_config.py         # personas.json 검증
│   │   ├── runner.py             # 페르소나×반복 실행, daily/events/spirit_daily.csv(병렬 가능)
│   │   ├── converge.py           # 대표 상태 정확 배치·종 제외 손실(allocation.csv)
│   │   ├── metrics.py            # 집계·판정(checks.csv, capture_stats.csv)
│   │   ├── report.py             # report.html
│   │   └── assumptions.py        # 시뮬 가정 목록(manifest·리포트에 기록)
│   └── tests/                    # unittest, fixtures/broken_*.json
└── outputs/                      # 실행 결과(실행 시 생성)
    └── static/
```

## 실행 명령

모든 명령은 `roblox-game/tools/econ_sim`에서 실행한다(경로 기본값은 패키지 위치로 정해지므로 다른 cwd에서 `--data`·`--out`을 주어도 된다).

```sh
cd roblox-game/tools/econ_sim

python3 -m econ_sim validate                 # data/ 검증. ERROR가 있으면 종료 코드 1
python3 -m econ_sim validate --patch tests/fixtures/broken_paid_capture.json   # 패치 적용 상태 검증(원본 불변)
python3 -m econ_sim gen-tables               # curves.json → data/generated/upgrade_tables.json·sink_tables.json
python3 -m econ_sim gen-tables --check       # 쓰지 않고 최신 여부만 확인(오래되면 종료 코드 1)
python3 -m econ_sim static                   # outputs/static/에 CSV 5종·static.html·static_meta.json
python3 -m econ_sim static --out /tmp/x      # 출력 위치 지정

python3 -m econ_sim all --quick              # validate→static→run(20시드)→converge→report, outputs/<UTC시각>_quick/
python3 -m econ_sim all --seeds 200 --workers 8 --out ../../outputs/full200   # 기본 200시드(병렬, 결과 바이트 동일)
python3 -m econ_sim run --quick --days 30 --seed 1 --out DIR   # 시뮬만
python3 -m econ_sim converge --out DIR       # 대표 상태 정확 탐색만
python3 -m econ_sim report --out DIR         # DIR의 CSV로 판정·report.html 재생성

python3 -m unittest discover -s tests        # 전체 테스트
```

종료 코드: 0 성공 / 1 검증 오류·표 오래됨 / 2 인자·입출력·설정 오류.

### static 출력

| 파일 | 내용 |
|---|---|
| `facility_payback.csv` | 시설 레벨별 비용·생산 증가·회수기간. **정규화 값**(기본 자원 1단위=1, 기준 배치 3칸). 마일스톤(Lv10·25) 불연속 표시 |
| `dominance.csv` | 정령 쌍별 지배 관계(시설 기여 3·동행 기여 3·전투 7차원). `trait_protected`는 고유 특성으로 보호된 경우 |
| `capture_quantiles.csv` | 첫 획득 조우 수의 기하분포 p50/p90/p99(조우당 q = (w/W)·Q_등급, Q는 간편 모드 조우당 포획 확률)와 분 환산(조우 수 × 필드 기대 조우 초 `encounter_seconds_mean`, 동등급 Lv1·활력 최대 약화 기준). `success_bps`는 간편 모드 시도 1회 성공률. 심지 부족·이월은 미포함. `release:*` 행은 릴리스 필드 중 가장 빠른 단일 필드 |
| `g3_hunt_minutes.csv` | 사냥 재료 요구 1건마다 추천 전투력 기준 사냥 분, 노을새 동행 시 분, 일일 의뢰만으로 걸리는 일수 |
| `g2_ratio.csv` | 기준 상태별 직접 채집/방치 비율 R과 하루 직접 비중 S(보고용) |
| `static_meta.json` | 데이터·설정 해시, 표 해시, 검증 경고, placeholder 전체 목록 |
| `static.html` | 위 내용의 요약·표·로그 축 회수기간 그래프(외부 URL 0) |

판정 열: `draft_evaluation`(PASS/WARN/FAIL), `approval_state`(approved = 사용자 확정 규칙에 근거, draft = 초안), `evidence_status`(`static_reference` = 기준 상태 추정). static 값은 곡선 모양과 불연속을 보는 용도이며 실제 정체·해금 시점은 2단계 시뮬레이션에서 판정한다.

### run 출력 (`outputs/<run_id>/`)

| 파일 | 내용 |
|---|---|
| `daily.csv` | 실행(페르소나×반복)×일 1행: 활동 분, 오프라인 인정/손실 분, 보유·상한, 누적 포획·놓아주기, 강화 상태, 직접 비중 S, 채집 시점 R(`g2_best_*` 판정용·`g2_actual_*` 참고: 평균·정의 분·구간 밖/안 3배 초과 분·미정의 분·구간 밖/안 최대), 도감 등록 수, F1 방치 사냥 재료 등급별 획득(`home_g1~4`), 포획 상태 기계 열(`attempts_cum`, 결과별 누적 `capture_{success,flee,wick_out,scatter}_cum`, 그날 `capture_budget_seconds`·`capture_seconds`(사용 초 ≤ 예산), 날 끝 미완료 조우 남은 초 `capture_carry_seconds`, 약화 수·초·등롱 보조 수, 급식 수 `food_eaten`, 활력 ≤50 동행의 사냥 분 `vigor_low_hunt_min`), 필드별 완료 조우 수·초(`enc_done_<필드>`·`enc_seconds_<필드>`, 완료일 기준), 자원별 잔액·출처별 획득(idle/direct/hunt/quest/paid/release/craft/grant/sink)·지출 |
| `events.csv` | 필드 해금·종별 첫 포획·보관함 가득·콘텐츠 소진(미도달도 `observed=false`로 1행, 모든 행에 `censor_time_minutes`), 구매(패스 보상 행은 2026-11-11 초심자 패스 제거로 현재 없음) |
| `spirit_daily.csv` | 페르소나×일×종의 반복 평균(보유 수·평균 레벨·시설 배치 분·동행 분·놓아주기) |
| `capture_stats.csv` | 종별 첫 획득률(D14/D30/기간), 미획득률, 첫 획득일 p10~p99(미도달을 +∞로 포함, 공란=기간 내 미도달), p99 표본 부족 표시, 완료자 조우 수, 해석식 조우 수 |
| `checks.csv` | 판정: `estimate`·`draft_evaluation`(PASS/WARN/FAIL/INCONCLUSIVE/INFO)·`approval_state`·`evidence_status` |
| `allocation.csv` | 대표 상태 32개(필드 진입/종료 8 × 병목 가중 4) × 재고 2모드의 정확 최적 배치·종 제외 손실. `one_of_each_available`(종별 1마리, 부분집합 DP, 휴리스틱 gap 기록)은 칸이 남으면 모든 종이 자동으로 쓰여 참고용이고, 수렴 판정은 `unlimited_copies`(종 복제 무제한, 시설별 중복조합 전수)만 쓴다. 동행(파티) 역할은 대상 외 |
| `manifest.json` | run_id, 입력 데이터·설정 해시, master_seed·반복 수·일수, 난수 키 정의, 단계별 실행 시간, 가정·placeholder·검증 경고 |
| `report.html` | 판정 요약(상단) → 해금 곡선 → 직접/방치 비중 → 정령 사용 분포 → 포획 CDF → 보관함 → 과금 비교 → 수렴 분석 |

같은 입력·인자면 CSV는 바이트 단위로 같다(`--workers` 수와 무관). `manifest.json`과 `report.html`에는 실행 시간·run_id가 들어가 매번 다를 수 있다.

### 시뮬레이션 요지
- 시간: 정수 분. 접속 중에는 5분 활동 단계마다 진행하고, 오프라인은 로그아웃 시각부터 상한까지만 인정(초과분은 손실). 생산률이 일정한 구간만 닫힌식으로 적립하며 밤(게임 내 시계: 현실 60분 = 게임 하루, 매시 30~60분 밤, UTC 에폭 분 기준)·일 경계에서 구간을 나눈다(`rules.night`의 cycle_minutes·night_start_offset_minutes·night_minutes, 검증 `RULE_NIGHT_CLOCK`: 0 ≤ offset < cycle, night ≤ cycle, cycle은 1440의 약수). 단위는 milli 정수와 나머지 이월.
- 정책: 다음 필드 해금 비용을 목표로 ETA(=max 자원 부족량/실효 획득률)를 늘리지 않고 획득률을 올리는 강화를 ETA가 가장 작아지는 순으로 구매. 마지막 필드 이후에는 회수기간 7일 이내 강화를 회수기간 순으로 구매. 활동은 포획 예산을 먼저 쓰고, 채집·사냥은 병목 자원으로 고른다.
- 난수: `sha256(master_seed, pairing_group_id, replicate_id, stream)`. 포획은 `capture:day<N>`, 개체값은 `individual:day<N>`(시작 정령 추첨 시 `individual:start`)으로 분리. persona_id·구매 여부는 키에 없으므로 balanced와 balanced_paid는 같은 날 같은 조우 순서면 같은 추첨값을 쓴다.
- 판정: `approved`는 사용자 확정·승인 기준(R 최대 3배와 전환 구간 4320분(3일) 허용, G3 10~60분, 과금 해금 단축 ≤50%, balanced 능선 p50 14일±20%·p90 ≤21일, balanced ★4 첫 획득 필드 진입 후 p99 ≤14일, 규칙 검증). 나머지는 `criteria.json`의 `draft`(필드별 R 대역 1.5~2.5, 하드코어 능선 p50 ≤ balanced −2일 등). 목표가 없는 해금일은 INFO. 비율은 Wilson 95% 구간이 임계값을 걸치면 INCONCLUSIVE. check 행은 임계값마다 나뉘며 approval_state는 결과와 무관하다.
- R 판정(G2): 채집 단계마다 R=직접 채집/같은 자원 방치. **판정 분모는 현재 보유 정령 전체로 그 자원 시설에 최선 조합(1시설 엄밀 최적 `placement.best_single`, 2026-11-10부터. 이전 휴리스틱은 기여 상위 슬롯+3마리만 봐서 Lv1 혼합 보너스 정령을 빠뜨려 분모를 최대 7.9% 작게 잡았다)을 놓았을 때의 방치량**(`g2_best_*` 열), 시뮬 정책의 실제 배치 기준은 참고(`g2_actual_*` 열, `g2_r_actual_reference` INFO). 새 필드(시작 필드 제외) 해금 후 `g2.transition_minutes`(4320분) 동안의 R>3·R 미정의는 허용하고 `g2_r_transition`으로 보고, 그 밖은 `g2_r_over_max`·`g2_r_undefined`가 approved FAIL. 최대 R은 구간 안/밖을 나눠 기록. 필드별(그 필드가 최고 해금 필드인 동안) 채집 가중 R은 `g2_r_field_band`(draft 1.5~2.5).
- 페르소나: light_1h(2회 30분: 포획 30분 + 채집·사냥 flex 30분, 사용자 결정 '포획 최소 30분'), balanced(3회 180분: 채집·사냥 flex 120·포획 30·꾸미기 30), hardcore(3회 360분: flex 270·포획 60·꾸미기 30), balanced_paid(balanced와 같은 일정 + 외형·편의 상품만 구매: 1일차 등불 외형·배치 프리셋, day 4부터 보관함 +10 하루 1개씩 총 10개. 2026-11-11 사용자 결정으로 재료 상자·초심자 패스를 제거해 '외형·편의 구매자'로 재정의). 완전 방치 유저는 상정하지 않는다(사용자 결정).
- 4단계 추가 지표: `heavy_user_lead`(draft, 하드코어 능선 p50이 balanced보다 2일 이상 빠른가), `star4_first_capture_p99`(★4가 나오는 필드 첫 진입일부터 첫 획득까지의 꼬리 분위수 — 기본 p99, criteria `star4_first_capture.quantile`로 변경. 2026-11-09 사용자 결정으로 0.985(p98.5, 14일 초과 1.5%까지 허용). check_id는 과거 run 비교를 위해 유지. balanced만 approved, 나머지 INFO), `hunt_material_idle_share`(사냥 재료 중 F1 방치 비중: 마지막 필드 해금까지 / D1~14 / D15+, INFO), `hunt_material_idle_share_by_field`·`hunt_material_idle_by_grade`(INFO), `hunt_material_stock_end`(기간 끝 사냥 재료 보유량, 적체 허용 INFO), `g2_r_actual_reference`(INFO). 콘텐츠 소진은 정책이 사지 않는 효과 0·이득 0 강화를 제외하고 판정.

### 시뮬 가정(메인 지시·구현 판단)
`econ_sim/assumptions.py`(전체 목록)에 있고 실행마다 `manifest.json`·`report.html`에 기록된다. 주요 항목:
- 게임 시작 = 첫 세션 시작(그 전 생산·손실 없음). 일일 의뢰는 해금한 가장 높은 필드의 사냥 재료만 지급
- 혼합 배치 보너스는 조건 충족 시 그 시설 전체 생산에 적용(최댓값 1개). 밤은 게임 내 시계(rules.night, UTC 에폭 분 기준 전 세계 동기, 2026-11-11 결정). 연구 포인트는 적립만
- 시작 정령 ★1 3종 Lv1(개체값 1.00), 배치와 동행은 배타(활동 중 동행 정령은 시설에서 빠짐)
- 사냥 드롭은 기대값 결정적 적립. 난수는 포획과 개체값에만
- 콘텐츠 소진 = 모든 필드 해금 + 시설·슬롯·도구·거점 등급·오프라인 상한 최대(정령 레벨 제외)
- 정책: 사냥 재료만 부족한 유익한 강화(게이트 등)의 재료를 예약해 먼저 모은다(하위 필드 사냥 포함). 같은 자원의 직접 채집 R<1이면 사냥 재료 부족분을 먼저 사냥. 열린 시설은 비워 두지 않는다. 배치 가중치는 해금 목표 부족분 × 자원 간 균형 보정
- "시설에 쓸모 있는 정령은 남기고 배치한다"(2026-11-10 사용자 결정 B, G2 꼬리 대응): 놓아주기 우선순위는 중복 종 → **시설에 유용하지 않음** → 낮은 등급 → 낮은 레벨 → 개체값 합계 → 미배치 → 새 개체. "유용" = 각 시설의 최대 슬롯에서 그 자원의 1시설 엄밀 최적(`best_single`, 낮 기여)에 드는 개체의 합집합(`Simulator.facility_keepers`). 배치 후보는 시설별 기여 상위(슬롯+1)에 종별 최상위 1마리를 더한다(혼합 보너스 정령이 후보에서 빠져 배치·레벨업이 안 되던 문제). 레벨업 후보는 배치된 정령을 이미 포함하므로 바꾸지 않았다
- 시뮬 미구현 데이터(availability=event, placement_cost≠1, 특성별 시간대)는 run 시작 시 중단, validate는 `RULE_SIM_UNSUPPORTED` WARN

### 사용자 규칙 F (2026-11-06)
| 규칙 | 데이터 | 시뮬 동작 |
|---|---|---|
| F1 고유 필드 특수재화 | `spirits[].home_field`, `rules.home_material.per_day_milli_by_grade`(★1~4 0.5/0.8/1.2/1.8개/일), `apply_individual_to_home_material`·`apply_dex_to_home_material`(기본 false) | 시설에서 일하는(동행 중 아닌) 정령이 고유 필드의 첫 사냥 드롭 재료를 방치 생산. 일 단위 나머지 이월 적립(`earned_idle_<사냥 재료>`) |
| F2 개체값 | `rules.individual_stats`(채집·전투 각 10000~12000bps, stream `individual`, `start_spirit_bps`, `roll_start_spirits` 기본 false) | 포획 성공 시 독립 균등 정수 추첨. 채집 배율은 시설·동행 기여, 전투 배율은 사냥 전투력의 능력 배율에 곱함. 놓아주기는 개체값 합계가 낮은 개체부터 |
| F3 생산 슬롯 | 시설당 3→최대 5(게임 내 비용) 유지 | 과금으로 늘리는 효과(`production_slot`·`facility_slot`·`working_spirits`)는 금지 |
| F4 보유 상한 | `hub.storage`(base 100, max 200), 거점 등급 보너스 0, 보관함 상품 +10 × 10회 | `min(max_capacity, 100 + 보관함 상품)` |
| F5 도감 보너스 | `rules.dex_bonus`(종당 100bps, 상한 1000), `spirits[].event`(시뮬 미사용) | 처음 획득한 종 수(시작 정령 포함, 놓아줘도 유지) × 1%를 시설 기본 재료 생산에 곱함 |

개체 상태(향후 게임 저장 스키마에도 필요): `uid`, `species`, `level`, `gather_bps`(채집·생산 개체값), `combat_bps`(전투 개체값). 플레이어 상태: 도감 등록 종 집합(`dex`), 보관함 상품 구매 수.

## 연구 트리 (2026-11-09)

설계 근거: docs/research_subscription_debate_20261109.md 7절·사용자 결정, 구현 명세 docs/research_sim_spec.md, 진행 메모 docs/research_sim_handoff.md.

### 데이터 (`data/research.json`)
- `budget`: `idle_cap_bps` 1200 / `gather_cap_bps` 1200 / `candidate_reserve_bps` 300(검증 전 후보, 사용 불가). `slots.free_shared` 1(동시 진행 1개).
- `nodes[]`: `id`(소문자, i1·a1·i2·a2·i3·a3·e1~e4), `track`(production|ecology), `release_id`, `required_fields`, `required_dex_count`(영구 도감 등록 종 수), `prerequisites`, `costs`, `duration_minutes`, `effects[{type, value_bps, resources?}]`, `speedup_allowed`. 모두 placeholder.
- 효과 3종만: `basic_idle_bps`(기본 재료 방치), `basic_gather_bps`(기본 재료 직접 채집), `habitat_info`(정보, 효과 0). `resources`가 없으면 기본 재료 3종 모두.
- 상품: `monthly_membership`(kind `subscription`, 외형·이벤트 트랙, 299 Robux 가안, 시뮬 효과 0).
- **연구 시간 단축 상품은 MVP에서 제외(사용자 결정 2026-11-09).** 근거: 단축 상품만 사는 비교군(balanced_skip)의 능선 해금 단축이 100시드에서 %p·상대 모두 0.000(outputs/20261109T021251Z_full). 자연 연구 일정은 시간이 아니라 연구 포인트 수입(보관함 만석 시 놓아주기)에 막혀 있어 시간 단축이 해금을 앞당기지 못한다. kind `research_time_skip`·검증 규칙·시뮬 기능(`when=production_research_active` 구매)과 노드의 `speedup_allowed`는 나중을 위해 남겼다(테스트는 시험용 상품을 패치로 추가해 검사).

### 공식
- 방치 = 기존 방치량(도감 보너스 포함, 자원별 합) × (10000 + I) / 10000, 직접 = 기존 직접량 × (10000 + A) / 10000, 각각 버림(`formulas.research_scaled_milli`). 가산 금지(결정 C2). 골든 벡터 `research_*`.
- 연구 완료 시각을 생산 구간 경계로 나눈다(`Simulator.advance`). 완료 효과는 그 이전 구간에 소급하지 않는다. 연구 타이머는 실제 시간으로 진행(오프라인 상한과 무관).

### 검증기 규칙
| 코드 | 내용 |
|---|---|
| `RULE_RESEARCH_BUDGET` | 자원별 Σ basic_idle_bps ≤ idle_cap_bps, Σ basic_gather_bps ≤ gather_cap_bps(예비 300은 사용 불가) |
| `RULE_RESEARCH_R_NEUTRAL` | 선행 조건으로 닫힌 모든 완료 상태에서 자원별 누적 A ≤ 누적 I. 상태 수 ≤ 65536이면 전수 열거(현재 데이터), 넘으면 선행 그래프 보수 검사(직접 노드를 위상 순서로 조상 방치 노드의 남은 용량에 탐욕 배정 — 배정되면 모든 상태에서 보장, 실패는 거짓 양성 가능) |
| `RULE_RESEARCH_EFFECT` / `RULE_RESEARCH_TRACK` | 허용 3종 외 효과 ERROR. 생산 효과는 production, habitat_info는 ecology만 |
| `RULE_RESEARCH_PAID` | 연구 포인트 purchasable=true, 또는 상품이 연구 포인트를 지급 |
| `RULE_RESEARCH_SPEEDUP` | speedup_allowed=true는 production만 |
| `RULE_RESEARCH_GRAPH` / `RULE_RESEARCH_RELEASE` | 선행 순환·도감 수 초과 / 필요 필드가 릴리스 밖·선행이 더 늦은 릴리스 |
| `RULE_SUBSCRIPTION_EFFECT` | subscription 효과는 cosmetic·event_track만 |
| `RULE_PAID_OFFLINE_CAP` | 오프라인 상한 효과를 가진 상품(모든 kind) |
| `RULE_PRODUCT_EFFECT` | research_time_minutes에 minutes 외 키(비용·조건 면제 시도) |
| `RULE_RESEARCH_DURATION` | duration_minutes가 활동 단계(5분)의 배수가 아님(완료가 단계 중간에 떨어지면 그 단계 직접 채집 전체에 새 A가 적용되므로) |

생산 효과의 `resources`에 기본 재료가 아닌 자원(사냥 재료 등)을 넣으면 `RULE_RESEARCH_EFFECT`로 보고하고, 예산·R 중립 합산에서는 그 자원을 무시한다(`Model.research_effect_bps`).

### 시뮬
- 페르소나 `research`: `off`(무연구) / `natural`(자연 연구, 기본) / `cap`(상한 시험: 필드·도감·선행 조건을 만족하는 순간 비용·대기 없이 완료).
- 페르소나 `wick_mode`(2026-11-10 단계 2): `required`(기본, 시도마다 심지 1개, 없으면 새 조우를 시작하지 않음) / `unlimited`(심지를 소비·제작하지 않는 비교용).
- 페르소나 `sink_preference`(단계 4): `normal`(기본) / `high` / `none`. 정책은 assumptions(소비처 구매) 참조. `ablation`(12절): `weaken_level_off`(약화 레벨 효과 끔), `vigor_off`(활력 끔).
- 비교 실행 파일(단계 7용): `config/personas_wick_compare.json`(심지 required 대 unlimited, 레시피 B는 `--patch ../../data/variants/wick_recipe_codex.json`), `config/personas_sink_pref.json`(소비처 선호 none/normal/high), `config/personas_ablation.json`(레벨 효과 off·활력 off). `run`·`all`은 `--patch`를 받는다(manifest `patch`에 경로·sha 기록, `report`를 따로 실행하면 같은 패치를 자동 적용하고 파일이 없거나 바뀌었으면 경고).
- 심지 공급(2026-11-10 조정, placeholder): 시작 21개(사용자 결정 고정), 일일 의뢰 meadow 40·forest 25·cave 35·ridge 25, 해금 보급 forest 120·cave 200(단계 7 루프 결과).

### 단계 5 지표 (2026-11-10, 전부 draft 또는 INFO — 기존 approved 판정의 코드·임계값·check_id는 그대로)
| check_id | 내용 | 상태 |
|---|---|---|
| `capture_rule_conformance` | 등급별 조우당 성공 실측(심지 소진 제외, 비교군별 첫 페르소나)과 Q의 Wilson CI 비교 | draft(WARN) |
| `capture_time_conservation` | 하루 사용 초 > 예산 초인 날 수 | draft(위반 시 FAIL) |
| `encounter_seconds_mean`·`capture_outcome_share` | 필드별 조우 평균 초(해석값 병기), 등급별 결과 비율 | INFO |
| `wick_shortage_share` | 심지 부족 분 ÷ 포획 예산(D1-14 / D15+), balanced·hardcore ≤0.01 | draft |
| `wick_procure_minutes`·`wick_paid_free_gap`·`wick_vs_unlimited` | 조달 분, 과금·무과금 짝 차이, 무제한 대비(비교 파일 실행 시) | INFO |
| `star4_exposure`·`capture_pending_at_horizon` | ★4 필드 조우 분·조우 수·종료 사유, 기간 끝 미완료 조우 | INFO |
| `finite_cosmetic_completed_day` | balanced 유한 외형 완료 p50이 D45~D60 | draft |
| `finite_cosmetic_progress`·`sink_absorption`·`repeat_sink_available_rate` | D30/D60 진척, D21+ 소비처 지출 ÷ 기본 재료 획득(합계/유한/반복), 반복 소비처 개방 일 비율 | INFO |
| `weaken_seconds_mean`·`vigor_low_share`·`food_per_day`·`food_shortage`·`assist_weaken_share` | 12절 약화·활력·먹이 | INFO |
| `vigor_paid_free_gap`·`ablation_effect` | 과금·무과금 짝의 약화·먹이 차이, ablation 대비(비교 파일 실행 시) | INFO |
- 임계값·짝 지정은 `config/criteria.json` `sim.capture_sinks`. 이벤트 `finite_cosmetic_completed`(미도달 observed=false), 유한 품목 `sink_purchase`. static `sink_catalog.csv`(소비처 전개 비용, 유한 합계). report.html에 "포획·심지·활력"·"소비처" 절.

### 포획 상태 기계·활력 (2026-11-10 단계 2·3)
- 근거: `docs/capture_rules_debate_20261109.md`·`docs/weaken_hunger_debate_20261110.md` 끝의 사용자 결정, `docs/sinks_capture_impl_plan.md` 3·4·12절.
- 순수 함수(`formulas.py`, 골든 벡터 `data/test_vectors.json`): `capture_attempt_bps`·`flee_bps`·`capture_k_max`·`weaken_needed`·`easy_attempt_light`·`weaken_seconds`·`weaken_vigor_cost`·`resolve_encounter`·`encounter_expectation`·`vigor_hunt_scaled_milli`. 확률 함수에는 성장·활력·상품·연구 입력이 없고, 성장·활력은 약화 초에만 들어간다(대상·H·심지 수·난수를 고정하면 result·attempts가 같고 seconds만 다름 — 테스트 `test_capture_sm.InvarianceTest`).
- 간편 모드 조우당 포획 확률 Q / 기대 시도 E[A]: ★1 1/1, ★2 0.9788/1.3051, ★3 0.8074/2.1531, ★4 0.4639/3.0923. 필드 기대 조우 초(동등급 Lv1 약화, ★1 약화 생략): 초원 65.2, 숲 67.3, 동굴 72.1, 능선 71.7(계획서 해석값 72.2/72.6/74.1/74.3은 ★1도 8초 약화한 값).
- 시뮬 흐름: 포획 단계(5분=300초)마다 미완료 조우를 먼저 진행하고 남은 초로 새 조우를 시작한다. 조우 시작 때 `capture:day<N>`에서 21개 난수를 항상 소비해 종·결과를 확정하고 심지를 차감, 결과(성공·첫 포획·개체값·놓아주기)는 완료 시각에 적용. 하루 사용 초 ≤ 예산 초(daily `capture_seconds` ≤ `capture_budget_seconds`).
- 집계 기준: 조우 시작 수·시도·약화 초·등롱 보조·심지 차감은 **시작 시각의 날**, 결과(성공·도망·심지 소진)·`enc_done_*`·`enc_seconds_*`·첫 포획·놓아주기는 **완료 시각(완료 초를 포함한 분)의 날**. 급식 실패는 `food_short_window`(개체당 60분 2개 상한)·`food_short_stock`(재고·제작 불가)로 나눠 센다. 근사: 공격하지 않은 포획 동행은 회복으로 보고, 사냥 산출 배율·급식은 단계 시작 시각의 활력으로 판정한다. 활력 `applies_to`는 검증기가 정확히 weaken·hunt로 강제한다(시뮬은 이 키를 읽지 않고 두 활동에 적용).
- 길표: `fields.json` 해금 비용은 `key_meadow`·`key_forest`·`key_cave`(atomic)로 표기하고, 해금 순간 `sim.craft_atomic`으로 제작·소비한다. `policy.goal`·G3·검증기는 전개 비용(`Model.expand_costs`)을 쓴다. `sim.craft`(stock 제작: 투입 `spent_*`, 산출 `earned_craft_*`), `sim.buy_sink`(효과 없음, `sinks_owned`·`repeat_levels`·`finite_completed_time`, 이벤트 `sink_purchase`). `policy.is_exhausted`는 바꾸지 않았다.
- 추가 페르소나(모두 pairing_group `balanced`, 같은 난수): `balanced_noresearch`(off), `balanced_research_cap`(cap). `balanced_paid`는 외형·편의 상품만(연구 단축 제외). light_1h·hardcore도 자연 연구(실제 유저는 모두 연구).
- 자연 연구 정책(관리 시점마다): 슬롯이 비면 production(데이터 순서 I→A) → ecology. 생산 연구는 효과를 연구 시간만큼 늦춘 목표 ETA(`Policy.eta_delayed`, 목표 = 다음 필드 해금 비용 + 예약 중 강화의 사냥 재료)가 강화 구매와 같은 허용 규칙(`_eta_acceptable`)을 만족할 때만 시작 — 기본 재료가 해금·강화 목표를 해치지 않게 하는 기존 예약 로직과 같은 기준. 마지막 필드 이후는 (기본 재료 비용/획득률 증분 + 연구 시간) ≤ 7일. 생태 연구는 조건을 채운 미착수 생산 연구의 연구 포인트·사냥 재료를 예약한 뒤 남을 때, 목표 ETA를 악화시키지 않을 때만.
- 연구 포인트 수입은 기존대로 보관함 만석 시 놓아주기에서만(자발적 놓아주기 없음).
- 출력: daily `research_done`(완료 노드 수), `wallet/earned/spent_research`. events `research_complete`(노드마다 1행, 미완료 observed=false)·`research_start`.

### 판정 (`criteria.json` `sim.research`)
| check_id | 내용 | 상태 |
|---|---|---|
| `research_cap_shortening` | 필드 구간별 S = 1 − Δcap/Δnone(Δ = 다음 필드 해금 분 − 현재 필드 진입 분, 같은 replicate 짝)의 중앙값·95% CI. CI 상단 ≤ 0.15 PASS, 하단 > 0.15 FAIL, 걸치면 INCONCLUSIVE(표본 < min_pairs 10도 INCONCLUSIVE) | approved |
| `research_cap_cumulative` | 게임 시작→능선 누적 단축(참고 0.10~0.15) | INFO |
| `research_natural_gain` | balanced 대 balanced_noresearch 능선 누적 단축 중앙값 ≥ 0.03(CI는 보고만) | approved |
| `noresearch_unlock` | balanced_noresearch 능선 p50 ≤ 16.8일·p90 ≤ 21일(approved), 기간 내 도달률 ≥ 0.9(Wilson, 임계값은 구현 판단 draft) | approved/draft |
| `research_skip_gain` | criteria `sim.research.skip`에 페르소나를 지정할 때만 출력(현재 미지정, MVP 상품 없음). (T_nat − T_skip)/T_none(무연구 공통 분모 %p)와 1 − T_skip/T_nat — 반복별 짝 값의 중앙값(결정 C3) | INFO |
| `research_natural_segment`, `research_points`, `research_node_complete_day`/`_dist`, `research_points_backlog` | 구간별 자연 연구 단축, 연구 포인트 기간별 하루 수입·누적·잔고, 노드별 완료일, 전 노드 완료 후 적체 | INFO |

**미도달 처리**(기존 `paired_shortening` 관례): 기준(무연구)만 다음 필드에 미도달이면 Δ기준 ≥ 기간 끝(검열 시각) − 진입 분으로 값을 넣는다(진짜 단축률의 하한). 시험(cap·자연 연구)만 미도달이면 같은 방식으로 Δ시험을 기간 끝까지로 넣는다(진짜 단축률의 상한). 둘 다 미도달이거나 어느 쪽이 그 구간에 진입하지 못한 짝만 제외하고, 모든 행 reason에 '양쪽 도달·기준 미도달·시험 미도달·미도달 제외 N'을 적는다. 판정: 상한 시험(≤0.15)은 기준 미도달 짝이 있으면 PASS를 확정하지 않고 INCONCLUSIVE, 시험 미도달 짝이 있으면 FAIL을 확정하지 않고 INCONCLUSIVE. 자연 연구 이득(≥0.03)은 반대로 시험 미도달이 있으면 PASS, 기준 미도달이 있으면 FAIL을 확정하지 않는다.

**신뢰구간 계산법**: 분포 무관 순위 신뢰구간. n개 짝 값을 정렬하고 P(B(n, 1/2) ≤ j) ≤ 0.025를 만족하는 최대 j를 정수 이항계수(`math.comb`)와 `Fraction`으로 정확히 구해 [x₍ⱼ₊₁₎, x₍ₙ₋ⱼ₎]를 쓴다(실제 포함 확률 ≥ 95%, 결정적). n ≤ 5면 구간 없음 → INCONCLUSIVE. 중앙값은 다른 판정과 같은 최근순위(nearest-rank, 짝수 n이면 아래쪽 가운데) 값. 예: n=20 → 6번째~15번째, n=100 → 40번째~61번째.

기존 판정(G2·과금 ≤50%·★4·해금 목표·헤비 선행)은 연구가 켜진 기존 페르소나로 그대로 판정한다. 과금 단축(`paid_unlock_shortening`)의 balanced_paid는 외형·편의 상품만 산다(연구 단축 상품은 MVP 제외, 2026-11-09). 2026-11-11부터 이 판정은 '과금 상품이 진행을 가속하지 않는다'는 회귀 감시이며 기대값은 ≈0(임계값 ≤0.5·approved는 그대로).

## 포획 보조 도구 (2026-11-11 사용자 결정, `docs/late_sinks_showcase_debate_20261111.md` 끝)

- 데이터: `capture.json` `capture_tool`(도구 4종 `lure_<필드>`, 등급 배율 ★2 11000·★3 11500·★4 12000 bps, ★1 없음, 결과 상한 `max_bps` 10000, `per_attempt` 1, `applies_to` home_field, `unlock_after_field` ridge, `requires_prior_direct_capture` true), `resources.json` `lure_<필드>`(craft·stock·비매·untradable·account·origin craft), `crafting.json` `lure_from_<필드>`(그 필드 사냥 재료 1 → 도구 2, group lure). 수치는 placeholder.
- 공식(`formulas.py`): `capture_tool_mult_bps`, `capture_tool_attempt_bps`(= min(max_bps, 기본 성공률 × 등급 배율), 내림), `capture_tool_item`(home_field·전역 해금·직접 포획 이력 판정, 없으면 None — 골든 벡터에서는 ""), `resolve_encounter_tool`(시도 직전 재고가 있으면 1개 소비·도구 성공률, 없으면 그 시도는 기본 성공률. 반환 끝에 `tools_used`), `encounter_expectation(..., with_tool=True)`. `resolve_encounter`는 도구 0개 호출과 같다(구현 1개).
- 검증기: `RULE_CAPTURE_TOOL`(도구 자원 속성, 레시피 입력 hunt만, ★1 배율 없음, ★2~4 배율 10000~12000, max_bps ≤ 10000, per_attempt ≥ 1, applies_to home_field, 직접 포획 이력 필수, 전 필드 도구, `fields[].capture`에 tool·lure 키 금지). `RULE_CAPTURE_NO_PITY`는 그대로(도구는 명시 예외). `RULE_PAID_CAPTURE` 확장: 상품의 사냥 재료 지급 금지, 도구를 전개한 자원의 구매 가능·상품 지급 금지. broken fixture `broken_capture_tool_*`(7개)·`broken_paid_lure_product`·`broken_paid_hunt_product`.
- 시뮬: 페르소나 `capture_tool`(`off` 기본 | `star4`), personas `policy.capture_tool_stock_days`(제작 상한 = 1일 예상 사용량 × 일수, 기본 2)·`policy.capture_tool_min_stock`(사용 쪽 재고 하한, 기본 0: 조우에서 '재고 − 하한'만 사용, 난수 순서 불변, 2026-11-11 결정 M1). 도구 on 페르소나만 심지 제작이 유한 외형 사냥 재료를 먼저 피하고 모자라면 진행 예약 기준으로 폴백(결정 M2, off 불변). 1일 예상 사용량은 최고 해금 필드·낮 출현표·해석 조우 초 기준 근사(assumptions). star4는 ★4 조우에서만 자동 사용. 조우 난수 블록은 그대로이고 확률 값만 바꾼다. 제작 정책·예약 순서는 assumptions 참조. 비교 파일 `config/personas_tool_star4.json`(기본 personas 전원 star4).
- daily 열: `tool_attempts`·`tool_enc`·`tool_success`(완료일), 감시용 `tool_first_capture`·`tool_pre_unlock`(항상 0이어야 함), `craft_hunt_lure`, `g<등급>_tool_{enc,success,full_enc,full_success}`, `lure_craft_<필드>`(제작 수)·`lure_used_<필드>`(소비 수, 시작일). 도구를 쓴 조우는 `g*_full_enc/full_success`(기존 적합도)에서 빠진다(off에서는 항상 0건이라 기존 값 불변). 집계 시점: `lure_used_*`·도구 차감은 조우 시작일, `tool_attempts`·`tool_enc`·`tool_success`·`g*_tool_*`는 완료일이라 날짜 경계에서 하루 값이 어긋날 수 있다. 지표의 '전역 해금 후(@u)'는 그날 daily `highest_field`가 unlock_after_field 이상인 날로 근사한다(해금 당일 전체를 포함).
- 지표(criteria `sim.capture_sinks.tool_balance_days`): `capture_tool_first_capture_zero`(draft, 0이 아니면 FAIL), `capture_tool_conformance`(도구 조우 적합도, draft), `capture_tool_usage`·`capture_tool_field`(전역 해금 후 하루 도구 제작/소비·사냥 재료 중 도구 몫·D14/30/60 잔고)·`star4_success_per_day_after_unlock`(INFO). report "포획 보조 도구" 절. 도구 check·절은 manifest personas에 `capture_tool` ≠ off가 있을 때만 나온다(off run에는 없음).
- 정책 표시: 도구 재료는 비매 사냥 재료뿐이라 유료 랜덤 경로가 아니다(유료 재료가 들어가면 RULE_PAID_CAPTURE). 확률 공개 대상(도구 적용 후 성공률)은 게임 UI에서 표시해야 한다.

## 데이터 수정 방법

1. `data/*.json`을 고친다. 순수 JSON만 허용한다(주석·null·NaN·Infinity·중복 키 금지). 배열 항목은 `id`를 가진다.
2. 값이 가안이면 해당 객체에 `"placeholder": true`, 설명은 `"notes"`를 단다. 모든 객체에서 이 두 키를 쓸 수 있다.
3. `curves.json`을 고쳤다면 `python3 -m econ_sim gen-tables`를 실행한다. 표가 오래되면 validate가 `STALE_TABLES`로 실패한다. `generated/upgrade_tables.json`·`generated/sink_tables.json`은 직접 고치지 않는다(해시 불일치로 실패). 두 표 모두 curves.json 전체의 해시를 기록하므로 `sink_curves`만 고쳐도 둘 다 다시 생성된다(강화표 본문은 그대로).
4. `python3 -m econ_sim validate` → `python3 -m econ_sim static`.

단위와 규칙:
- 배율은 bps(10000 = 1.0배), 생산량 계산은 milli(1000 = 1개) 정수. 데이터의 `base_per_hour`는 정수(시간당 개수).
- 적성 문자: `S A B C D X`(X = 불가 —). `aptitude` 키는 기본 자원 3종과 정확히 같아야 한다.
- 비용 곡선: `ceil(base × growth^(L + exponent_offset))`가 L→L+1 비용(시설 offset −1, 정령 0). 유리수로 정확히 계산한다.
- 보너스 곡선: `(1 + per_level × (L−1)) × Π(도달한 milestone의 mult)` — 선형 해석.
- 소비처 반복 비용(`sink_curves`): `exp_ceil_capped` = 레벨 L(≥1) 비용 `ceil(amount × growth^min(L, cap_level))`(성분별 growth), `linear_ceil_capped` = n번째(≥1) 비용 `ceil(amount × (1 + step × min(n−1, cap_steps)))`. 표의 마지막 행 이후는 마지막 행과 같다.
- 제작물 전개(`Model.expand_costs`): stack=atomic 품목(길표·부품)은 유일한 레시피로 재귀 전개해 재료 비용으로 본다. 필드 해금 요구량(`iter_requirements`)과 해금 그래프 검사는 전개 비용을 쓴다(단계 1에서는 해금 비용에 길표가 없어 결과 동일). 소비처 품목은 `include_sinks=True`일 때만 `source_kind="sink"`로 나온다(G3 approved 대상 아님)
- 특수 노드: 노드에 `requires_node_trait: true`와 `node_kind`, 정령 특성 `special_node`의 `params.node_kind`가 같아야 한다.

검증기가 ERROR로 막는 규칙(사용자 확정 규칙 기반):
- `purchasable=true`는 기본 재료만, 기본 재료는 정확히 3종(2026-11-11 판매 경로 제거로 현재 모든 자원이 false)
- 포획 비용에 구매 가능 자원 또는 상품이 지급하는 자원 사용 금지(`RULE_PAID_CAPTURE`). 2026-11-10 확장: `capture.json` `attempt_cost`(심지)와 그 레시피 입력을 끝까지 전개한 자원에 구매 가능·상품 지급 자원이 있으면 금지, 상품이 craft 자원을 지급해도 금지. 상품 효과 `grant_wick`·`capture_supply`는 `RULE_FORBIDDEN_PRODUCT`
- 포획 규칙(`capture.json`, 2026-11-10): ★1~4 성공률 각 1개, 빛 구간 배율은 빛이 낮을수록 줄지 않고 모두 10000 이상, `stop_at_light` > 흩어짐 한계, 도망 확률은 줄지 않고 실패 20회 안에 100% 도달, 시간 값 > 0(`RULE_CAPTURE_PARAMS`). 천장·실패 보정·보장 키(pity·ceiling·guarantee·success_bonus·fail_bonus·bad_luck·override 포함 키)가 `capture.json`이나 `fields[].capture`에 있거나, `fields[].capture`에 성공률·확률 키(success·bps·prob·rate 포함, 예: 옛 `success_bps_by_grade`)가 있으면 `RULE_CAPTURE_NO_PITY`(스키마 미지 키 대신 규칙으로 보고). 단계 2(2026-11-10)부터 필드에는 출현 표만 둔다
- 약화·활력(`capture.json` `weaken`·`vigor`, 2026-11-10): 등급 차 배율 −3~+3 각 1개·양수·등급 차가 클수록 줄지 않음, 1 ≤ min ≤ max초, 등롱 보조 초와 자동 공격자 상한이 min~max 안(`RULE_WEAKEN_PARAMS`). 활력 최대 ≥1·소모 ≥0·비활동 회복 ≥1·저활력 배율 0~10000·먹이 수치·먹이 자원은 비매 craft stock(`RULE_VIGOR_PARAMS`). `applies_to`는 weaken·hunt만(집 방치 생산·보유에는 유지비 없음, `RULE_VIGOR_SCOPE`). 먹이 레시피 입력은 kind hunt만이고 1개 이상(`RULE_FOOD_RECIPE_INPUT`). 상품 효과 food·grant_food·vigor·vigor_restore·vigor_recovery·recovery·stamina는 `RULE_FORBIDDEN_PRODUCT`, 상품이 먹이(craft 자원)를 지급하면 `RULE_PAID_CAPTURE`
- 제작(`crafting.json`): 심지 레시피 입력은 kind hunt만(`RULE_WICK_RECIPE_INPUT`). 레시피 참조 오류·순환·산출물 kind≠craft·mode≠stack·atomic 레시피 수≠1 또는 산출량≠1·atomic 품목을 보급/의뢰/상품으로 지급(`RULE_CRAFT_GRAPH`)
- 소비처(`sinks.json`): 효과는 빈 배열만(`RULE_SINK_EFFECT`). 반복 소비처는 `curves.json` `sink_curves`의 상한 공식(`exp_ceil_capped`·`linear_ceil_capped`)만, 기본 재료만 쓰는 반복 소비처 1개 이상, 공식별 매개변수 일치(`RULE_SINK_REPEAT`). `trade_class`는 `untradable`만(`RULE_TRADE_RESERVED`, 거래는 미구현·필드 예약)
- 상품 kind는 cosmetic / storage_expand / placement_preset / research_time_skip / subscription만. 정령 판매·유료 랜덤·확률/행운·스탯 버프 kind·효과는 `RULE_FORBIDDEN_PRODUCT`. `basic_material_pack`(기본 재료 상자)·`beginner_pass`(초심자 패스)는 2026-11-11 사용자 결정으로 상품 후보에서 제거해 금지 kind(`RULE_FORBIDDEN_PRODUCT`)로 옮겼다(조용한 재추가 방지)
- 릴리스의 각 정령은 그 릴리스 필드 **합집합** 중 한 곳에서 `availability: "always"`·가중치>0·성공 확률>0(`RULE_RELEASE_ACCESS`)
- 유지비 없음(`upkeep` 빈 배열), `max_owned`=0(무제한), 오프라인 상한 최대 24시간
- 참조 오류(`REF_UNKNOWN`), 해금 순환·도달 불가, 슬롯 해금 목록, 사냥 재료 드롭원
- 개체값 재추첨(리롤)·생산 슬롯 확장 유료 효과 금지(`RULE_FORBIDDEN_PRODUCT`), 보유 상한 합계 > `max_capacity`(`RULE_STORAGE_CAP`), 고유 필드 포획표에 없는 종·드롭 없는 고유 필드(`RULE_HOME_FIELD`), 개체값 min>max
- 경고(WARN): 고등급이 저등급을 특성 보호 없이 지배(`WARN_DOMINANCE`), 일일 의뢰로 얻을 수 없는 사냥 재료, 릴리스 목록 밖 정령 출현, 시뮬 미구현 데이터(`RULE_SIM_UNSUPPORTED`)

### broken fixture

`tests/fixtures/broken_*.json`은 실제 데이터에 적용할 패치(`ops`)와 기대 오류 코드(`expect_codes`)를 담는다. 패치 경로는 `/배열/id:값/...` 또는 `/배열/키=값/...`으로 항목을 고른다. op는 `set`·`remove`·`append`.

## placeholder 목록 (2026-11-06 기준)

전체 목록은 static 실행 시 `outputs/static/static_meta.json`의 `placeholders`에 자동으로 기록된다(현재 41건). 영역별 요약:

| 영역 | 파일 | 가안으로 채운 값 |
|---|---|---|
| 강화 비용 base | curves.json | 시설 3종·정령 등급별·도구 비용 base(성장률 1.15/1.12는 brief 가안) |
| 도구 곡선 | curves.json, tools.json | 도구 비용(base 50/50, growth 1.18로 시설보다 비쌈)·직접 채집 배율(+10%/Lv, 마일스톤 없음 — 4단계: 동굴 이후에도 필드별 R 약 2 유지, 사용자 결정 '헤비 유저 보상'), 필드별 레벨 상한 |
| 시설 | facilities.json | 시간당 기본 생산(결정 공방 20 — 4단계 15→20), 필드별 레벨 상한(동굴 24 — Lv25 ×2 마일스톤은 능선부터), 슬롯 4·5 해금 비용, 사냥 재료 게이트(이슬·꽃빛 13개, 결정 9개, 1건 9개·능선 6개 = 일일 의뢰 3일분) |
| 필드 | fields.json | 필드 4개 구성. 해금 비용(동굴: 기본 15000/15000/결정 3000 + 숲 24·초원 30, 능선: 60만/60만/24만 + 동굴 20·숲 24·초원 30 — 사냥 1건 60분 이내). 채집 노드량(4단계: 시뮬 필드별 R≈2로 비례 재보정 — 초원 160, 숲 이슬·꽃빛 240·결정 160·큰 결정 200, 동굴 이슬·꽃빛 1030(꽃빛 노드 신설)·결정 775·큰 결정 875, 능선 2190/2190/1630). 추천 전투력·드롭량, 조우 가중치(출현 표). 해금 비용의 사냥 재료는 단계 3(2026-11-10)부터 길표(key_meadow/forest/cave, atomic)로 표기하며 전개하면 위 값과 같다. 포획 성공률·시간은 capture.json(전역)으로 이동 |
| 포획·약화·활력 | capture.json | 시도 성공률 ★1 100/★2 50/★3 25/★4 10%, 빛 구간 ×1/1.25/1.5, 도망 3%+12%p, 조우 60초+약화+4초/시도, 시작 심지 21(사용자 결정). 약화 등급 차 배율 0.5~1.6·레벨 +2%/Lv(상한 +40%)·2~12초·등롱 12초(사용자 결정 B, placeholder), 활력 소모(약화 4+2×등급 차, 사냥 분당 2)·회복 20/시·≤50 효율 75%·먹이 +25·60분 2개(사용자 결정) |
| 먹이 레시피 | crafting.json | 필드별 사냥 재료 1 → 먹이 2(심지와 사냥 재료를 경쟁하므로 작게 둔 placeholder) |
| 사냥 재료 | resources.json | 필드별 1종(이름 가칭) |
| 공식 상수 | rules.json | gather_ref=5, 동행 직접 채집 k=10%, 사냥 전투력비 0.5~1.5, 게임 내 시계(60분 주기, 매시 30~60분 밤) |
| 거점 | hub.json | 거점 등급 2·3 비용(보관함 보너스 0, 등급의 다른 효과 미정), 오프라인 상한 16/20/24시간 비용 |
| F 규칙 수치 | rules.json | 특수재화 하루량, 도감 보너스 1%·상한 10% |
| 일일 의뢰 | daily_quests.json | 필드별 사냥 재료 지급량(3/3/3/2). 건설 요구량(시설 게이트·슬롯·거점 등급·오프라인 상한)은 단계별 지급량×3(9/9/9/6)으로 통일, 필드 해금 비용은 대상 외 |
| 상품 | products.json | 상품 4종(외형·보관함·배치 프리셋·구독)의 가격·수량·한도. 재료 상자·초심자 패스는 2026-11-11 제거 |
| 릴리스 | releases.json | 2주판 정령 목록(★1 3종·★2 2종·★3 무지개 나비) |
| 정령 | spirits.json | 적성(고등급 특화: 달빛 여우 이슬 S/D/D, 오로라 사슴 D/S/D, 무지개 나비 C/C/B — 지배 경고 0건), 놓아주기 연구 포인트, 무지개 나비 혼합 보너스(+10%, 3종 이상), 달빛 여우 밤 보너스(효과 0) |
| static 기준 상태 | config/static_reference.json | `*_entry`는 해금 순간(unlock 직전, 직전 필드 상한 이하)의 balanced 관측 상태를 실제 종·레벨로 지정(`facility_levels_by_resource`·`staff_members_by_resource`·`companion_members_by_resource`, 관측 도구 docs/stage4_tools/observe_entry.py). `*_exit`는 가상 기준 정령. 하루 포획 30분, 하루 직접 채집 60분 |
| 판정 초안 | config/criteria.json | G2 WARN 하한 1.5·필드별 R 대역 1.5~2.5, G3 WARN 대역 5~90분, 일일 의뢰 대기 3일, 하드코어 선행 2일, 사용 분포·보관함·소진 기준(sim 블록) |
