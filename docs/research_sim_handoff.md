# 연구 트리 시뮬 반영 인계 메모 (2026-11-09 착수)

- 대상: /Users/leeseunghak/project/roblox-game (Git 미사용)
- 명세: docs/research_sim_spec.md, 설계 확정: docs/research_subscription_debate_20261109.md(7절·사용자 결정)
- 직전 기준: unittest 90 OK / validate ERROR 0·WARN 0 / gen-tables --check 최신 / 최종 run outputs/20261109T004917Z_quick

## 테스트·검증 (마지막 확인)

cwd: /Users/leeseunghak/project/roblox-game/tools/econ_sim

| 시점 | unittest | validate | gen-tables --check |
|---|---|---|---|
| 착수 전(기준) | 90 OK (70초) | ERROR 0·WARN 0 | 최신 |
| 1~5단계 구현 후 | 115 OK (137초, test_research.py 25 추가) | ERROR 0·WARN 0 | 최신 |

## 명세 변경 (메인 전달, 사용자 결정 2026-11-09)
- 7-4 최종 판정 실행: 200시드 → **100시드**(`--seeds 100 --workers 8`, 새 run_id). docs/research_sim_spec.md 7-4에 반영.
- approved 판정 중 INCONCLUSIVE이거나 ★4 p99처럼 기준선에 걸린 항목은 200시드로 자동 재실행하지 않고 '200시드 재확인 후보'로 보고.

## 진행 상태 (명세 7절 순서)

- [x] 1. data/research.json(노드 10개, ID는 스키마 규칙상 소문자 i1·a1·…·e4)·manifest 등록·products(research_skip_60, monthly_membership)·검증기 규칙(validate.py `_check_research`, `research_r_neutral`)·broken fixture 6종
- [x] 2. 공식 `formulas.research_scaled_milli`·`idle_dex_research_milli`, 골든 벡터 6건(test_vectors.json)
- [x] 3. 시뮬: state(research_done/_time/_active), sim.py(완료 경계 분할 `advance`→`_advance`, cap 즉시 완료, 단축 구매), policy.py(`research_step`·`pick_research`·`_research_ok`·`eta_delayed`), personas.json(research 모드, 새 페르소나 3종)
- [x] 4. 지표: metrics.py `median_ci`·`research_checks`, criteria.json `sim.research`
- [x] 5. 테스트: tests/test_research.py, test_e2e.py 기대값(4→7 페르소나)
- [x] 6. quick: outputs/20261109T020716Z_quick(140회, 8병렬, all 300초) — PASS 68, WARN 13(모두 draft), FAIL 0, INCONCLUSIVE 44, INFO 146
  - cap 구간 S 중앙값[95% CI]: 초원→숲 0.000[0.000, 0.396] INCONCLUSIVE / 숲→동굴 0.007[−0.083, 0.139] PASS / 동굴→능선 0.110[0.086, 0.145] PASS, 누적 0.103(INFO)
  - 자연 연구 이득 0.048[0.036, 0.054] PASS, 무연구 능선 p50 15·p90 15 PASS, 도달률 1.000(n=20 Wilson 하한 0.839 → INCONCLUSIVE, draft)
  - 연구 단축 이득 0.000(INFO): 자연 연구 일정은 연구 포인트 수입에 막혀 있어 시간 단축이 해금에 거의 영향 없음
  - 기존 판정(직전 20261109T004917Z_quick 대비): G2 approved PASS 유지, balanced 능선 p50 15→14·p90 15→15 PASS, 과금 단축 능선 0.086→0.072 PASS, ★4 balanced 그림자 등불 14→14(기준선)·오로라 사슴 11→5 PASS, 헤비 선행 1일 PASS
  - 초원→숲 INCONCLUSIVE 원인: 20쌍 중 13쌍 ≤0, 7쌍 0.40~0.42. 숲 해금(1일차 아침 세션)이 전날 저녁 세션으로 당겨지는 세션 양자화. cap은 비용·시간을 무시하므로 research.json 비용·시간으로 조정 불가 → 사용자 질문
- [x] 7. 비용·시간 조정: 불필요(조정 가능한 approved 판정이 모두 PASS). 10시드 조정 반복 0/4회 사용. 초기값 진단 10시드 2회(scratchpad)는 조정 반복이 아님
- [x] 8. 최종 100시드: outputs/20261109T021251Z_full(700회, 8병렬, run 1408초·all 1411초) — PASS 109, WARN 13(모두 draft), FAIL 3, INCONCLUSIVE 0, INFO 146. placeholder 56건(research.json 노드·예산, 새 상품 포함)
  - cap 구간 S 중앙값[95% CI]: 초원→숲 0.000[0.000, 0.034] / 숲→동굴 −0.014[−0.073, 0.000] / 동굴→능선 0.134[0.116, **0.150**] 모두 PASS(동굴→능선은 상단이 기준선 0.15와 같음), 누적 0.101[0.089, 0.112](INFO, 참고 0.10~0.15)
  - 자연 연구 이득 0.047[0.039, 0.050] PASS(구간: 0/0/0.063), 무연구 능선 p50 15·p90 16일 PASS, 도달률 1.000(Wilson 하한 0.963) PASS
  - 연구 단축 구매 이득 0.000(%p·상대 모두, INFO). 참고 상한 s_cap−s_nat ≈ 0.054
  - 연구 포인트(balanced 중앙값): 하루 수입 D1-14 11.0 / D15-30 26.5 / D31-60 37.5, 누적 154/581/1696, 잔고 50/299/1414. 노드 완료일 p50: i1 6, a1 7, i2 9, a2 11, i3 15, a3 17, e1 15, e2 17, e3 18, e4 20(능선 해금 p50 14일 → i3·a3는 능선 이후). 전 노드 완료 후 적체 기간 끝 잔고 1414
  - 기존 판정: balanced 능선 p50 14·p90 15 PASS, 과금 단축 숲 0.396/동굴 0.120/능선 0.077 PASS, ★4 balanced 그림자 등불 13·오로라 사슴 12 PASS, 헤비 선행 1일 PASS
  - **FAIL 3: g2_r_over_max balanced 0.0005 / hardcore 0.0020 / balanced_paid 0.0009(approved)**. 진단: 연구가 꺼진 balanced_noresearch에서도 0.0006(2회, 최대 R 3.386, 능선·동굴 후반)이 나옴. A≤I 곱셈 구조라 연구는 R을 높이지 않음 → 20시드에서 안 보이던 기존 데이터·정책의 꼬리. 밸런스 데이터 변경은 범위 밖 → 사용자 질문
  - 200시드 재확인 후보: research_cap_shortening 동굴→능선(CI 상단 = 0.150), star4 balanced 그림자 등불 p99 13(기준 14)
- 최종 검증(cwd tools/econ_sim): unittest 115 OK(135초) / validate ERROR 0·WARN 0 / gen-tables --check 최신
- [x] 9. README 연구 섹션 추가(데이터·공식·검증 규칙·정책·판정·CI 계산법)

## 후속 작업 (2026-11-09, 리뷰 수정·사용자 결정 반영)

### 사용자 결정
- A1 연구 시간 단축 Robux 상품은 MVP에서 제외. 근거: 단축 상품만 사는 비교군(balanced_skip)의 능선 해금 단축이 100시드(outputs/20261109T021251Z_full)에서 %p·상대 모두 0.000. 자연 연구는 연구 포인트 수입에 막혀 있어 시간 단축이 해금을 앞당기지 못함.
  - 제거: products.json research_skip_60, personas.json balanced_skip·balanced_paid의 단축 구매, criteria.json research.skip(→ research_skip_gain 판정은 skip 지정 시에만 출력)
  - 유지: kind research_time_skip·검증 규칙(생산 노드만), sim의 when=production_research_active 구매 기능, research.json speedup_allowed. 테스트는 시험용 상품(test_skip_60)을 패치로 추가해 검사(SkipMechanicsTest)
- A2 연구 포인트 적체 허용(INFO 유지). A3 G2 3배 꼬리 FAIL은 다음 단계(자원 소비처)에서 조사, 이번에는 데이터 무변경.

### 리뷰 수정
- M1: Model.research_effect_bps가 기본 재료 외 자원을 무시(합산 KeyError 제거, 검증기는 RULE_RESEARCH_EFFECT로 보고). fixture broken_research_hunt_resource_effect.json 추가
- M2: metrics.segment_pairs를 paired_shortening 관례로 변경(기준만 미도달 → 하한값, 시험만 미도달 → 상한값, 둘 다 미도달·구간 미진입만 제외). 상한 시험은 기준 미도달 짝이 있으면 PASS 대신 INCONCLUSIVE, 시험 미도달 짝이 있으면 FAIL 대신 INCONCLUSIVE. 자연 이득은 반대. README에 기록
- m1: 검증기 RULE_RESEARCH_DURATION(duration_minutes % activity_step_minutes ≠ 0이면 ERROR)
- m2: 오프라인 상한과 완료가 겹치는 테스트 2건(cap_end 전 완료 1020분 / 후 완료 1180분, wallet·off_credited 720·off_lost 80 확인)
- m3: 모든 연구 판정 행 reason에 '양쪽 도달·기준 미도달·시험 미도달·미도달 제외 N(둘 다 미도달·구간 미진입)' 표시

### 검증 (cwd tools/econ_sim)
- unittest 119 OK(116초) / validate ERROR 0·WARN 0 / gen-tables --check 최신
- quick: outputs/20261109T031642Z_quick(120회, all 132초) — PASS 65, WARN 12, FAIL 0, INCONCLUSIVE 38, INFO 127. 연구 판정 수치는 직전 quick과 같음(단축 효과가 0이었으므로)
- 100시드: outputs/20261109T031903Z_full(600회, 8병렬, run 900초·all 902초) — PASS 100, WARN 12(모두 draft), FAIL 3, INCONCLUSIVE 0, INFO 127
  - 연구 판정·기존 판정 수치는 직전 100시드(20261109T021251Z_full)와 같음. 모든 짝 양쪽 도달(미도달 0)이라 M2 수정은 수치에 영향 없음
  - cap 구간 0.000[0.000, 0.034] / −0.014[−0.073, 0.000] / 0.134[0.116, 0.150] PASS, 누적 0.101[0.089, 0.112] INFO. 자연 이득 0.047[0.039, 0.050] PASS. 무연구 p50 15·p90 16 PASS, 도달률 1.000 PASS
  - 과금 단축 숲 0.396/동굴 0.120/능선 0.077 PASS, ★4 balanced 13·12 PASS, balanced 능선 p50 14·p90 15 PASS
  - FAIL 3: g2_r_over_max balanced 0.0005·hardcore 0.0020·balanced_paid 0.0009(사용자 결정 A3: 다음 단계에서 조사)
  - 200시드 재확인 후보: cap 동굴→능선(CI 상단 0.150 = 기준), ★4 balanced 그림자 등불 p99 13(기준 14)

## 200시드 재확인 (2026-11-09, 메인)
- run: outputs/20261109T065330Z_full (`econ_sim all --seeds 200 --workers 8`, 3609초). PASS 98 / WARN 13 / FAIL 4 / INCONCLUSIVE 0.
- 연구 경계 항목 확정: cap 동굴→능선 0.131 [0.120, 0.142] PASS, 누적 0.099, 자연 이득 0.047 [0.043, 0.048] PASS.
- 새 FAIL: star4_first_capture_p99 balanced:aurora_deer 17일(100시드 때 12일). 진입 필드 ridge(가중치 5/79). 200회 중 14일 초과 3회(rep 86=22일, 191=18일, 152=17일), 초과율 1.5%. 100시드에서도 rep 86(22일)이 있었지만 p99 순위상 드러나지 않았다. 그림자 등불 balanced p99 = 14일(경계 PASS).
- G2 꼬리 FAIL 3건 유지(balanced 0.0010, hardcore 0.0032, paid 0.0011).
- WARN 증가 1건: light_1h forest R 1.474(초안, 1시간 유저 참고).
- 대응은 사용자 결정 대기.
- 사용자 결정(2026-11-09): ★4 기준을 '운 나쁜 1%'에서 1.5%(p98.5)로 완화. criteria.json star4_first_capture.quantile=0.985, metrics.py가 설정 분위수를 사용(check_id 유지, statistic 라벨 p98.5), README 반영. unittest 119 OK, validate ERROR 0.
- 재판정: 200시드 run 사본 outputs/20261109T065330Z_full_q985에서 `report`만 재실행 → PASS 99 / WARN 13 / FAIL 3(G2 꼬리만). balanced 오로라 사슴 14일(경계 PASS), 그림자 등불 13일.
