# 연구 트리 경제 시뮬 반영 — 구현 명세 (2026-11-09, 메인 작성)

## 배경
- 설계 확정 문서: /Users/leeseunghak/project/roblox-game/docs/research_subscription_debate_20261109.md
  - "7. 토론 결과"와 맨 끝 "사용자 결정 (2026-11-09)"이 기준이다. 원안과 다르면 결정이 우선한다.
- 시뮬레이터: /Users/leeseunghak/project/roblox-game/tools/econ_sim (Python 3.12 표준 라이브러리, README.md에 구조·판정 설명)
- 직전 상태: unittest 90 OK, validate ERROR 0, 최종 run outputs/20261109T004917Z_quick(FAIL 0)
- 4단계 인계 메모: docs/econ_sim_stage4_handoff.md (구조 파악용)

## 제약
- roblox-game/ 밖 수정 금지. 표준 라이브러리만. 코드 주석은 일본어, README·사용자 문서는 한국어.
- 기존 outputs 폴더를 덮어쓰지 않는다(새 run_id). 출력 삭제 금지.
- 기존 밸런스 데이터(fields·facilities·tools·curves 등)는 바꾸지 않는다. 조정 대상은 research.json의 비용·시간뿐이다.
- 기존 판정 기준(G2·G3·과금 ≤50%·★4 등)은 그대로 유지하고 연구 포함 상태에서 다시 판정한다.

## 1. data/research.json (신규)
- budget: idle_cap_bps 1200, gather_cap_bps 1200, candidate_reserve_bps 300(notes: 시뮬 상한 시험 전에는 사용 불가, 검증기도 사용 금지)
- slots: 무료 공용 연구 슬롯 1개(동시 진행 1개)
- nodes 필드(가안, 이름은 구현에 맞게): id, name, track(production|ecology), required_fields, required_dex_count(영구 등록 종수), prerequisites, costs[{resource, amount}], duration_minutes, effects[{type, value_bps}], speedup_allowed(bool), release_id, placeholder
- 효과 타입은 basic_idle_bps(기본 재료 방치), basic_gather_bps(기본 재료 직접 채집), habitat_info(정보, 시뮬 효과 0)만 허용한다.
- MVP 노드 10개(토론 Codex 안 기반)
  - 비용 조정: 결정 I5에 따라 초원·숲 노드의 사냥 재료 비용은 제거한다.

| id | 이름 | 조건 | 효과 | 비용 | 시간 |
|---|---|---|---|---|---|
| I1 | 빛 순환 기초 | meadow·도감 3 | 방치 +400 | RP 12, dew 60, bloom 60 | 30분 |
| A1 | 채집 동선 기초 | I1 | 직접 +400 | RP 12, dew 60, bloom 60 | 30분 |
| I2 | 꽃빛 순환 | forest·도감 4·I1 | 방치 +400(누적 800) | RP 30, dew 300, bloom 300, crystal 60 | 120분 |
| A2 | 숲 채집 관찰 | forest·도감 4·A1·I2 | 직접 +400 | RP 30, 동일 | 120분 |
| I3 | 결정 공명 | cave·도감 5·I2 | 방치 +400(누적 1200) | RP 60, dew 3000, bloom 3000, crystal 1200, hunt_cave 3 | 360분 |
| A3 | 결정 채집 관찰 | cave·도감 5·A2·I3 | 직접 +400 | RP 60, 동일 | 360분 |
| E1 | 초원 생태 노트 | meadow·도감 3 | habitat_info | RP 6 | 60분 |
| E2 | 숲 생태 노트 | forest·도감 4·E1 | habitat_info | RP 12 | 120분 |
| E3 | 동굴 생태 노트 | cave·도감 5·E2 | habitat_info | RP 24, hunt_cave 3 | 240분 |
| E4 | 능선 생태 노트 | ridge·도감 6·E3 | habitat_info | RP 36, hunt_ridge 4 | 480분 |

- speedup_allowed: production 노드만 true, ecology는 false.
- 모든 값은 placeholder=true이며 run 메타의 placeholder 목록에 들어가야 한다.

## 2. 공식
- 연구 효과는 기존 계산 결과(도감 보너스 포함)에 경로별로 한 번 곱한다. 가산 금지(결정 C2).
  - 방치 = 기존 방치량 × (10000 + I) / 10000
  - 직접 = 기존 직접량 × (10000 + A) / 10000
  - I·A는 완료된 연구의 자원별 합이다.
- 정수 반올림은 기존 공식 관례(bps·milli)를 따른다. test_vectors.json에 골든 벡터를 추가한다.
- 오프라인·접속 중 생산은 연구 완료 시각을 경계로 구간을 나눈다. 완료 효과를 그 이전 구간에 소급하지 않는다.

## 3. 검증기 규칙 (validate, 각 규칙에 broken fixture 테스트)
1. 경로별 합계 예산: Σ basic_idle_bps ≤ idle_cap_bps, Σ basic_gather_bps ≤ gather_cap_bps. candidate_reserve 사용 금지.
2. R 중립: 선행 조건을 지키는 모든 도달 가능한 완료 상태에서 자원별 누적 A ≤ 누적 I. 전수 열거가 크면 선행 그래프 기반 보수 검사를 쓰고 방법을 문서화한다.
3. 금지 효과: 위 3종 외 효과 타입(오프라인 상한·보관함·슬롯·정령 능력치·사냥 재료·포획 확률·조우 등)은 ERROR.
4. research 자원은 purchasable=false여야 하고, 어떤 상품·패스도 research를 지급하면 ERROR.
5. speedup_allowed=true는 production 노드만 허용.
6. 상품 kind 추가
   - research_time_skip: 진행 중인 speedup_allowed 노드의 남은 시간만 줄인다. 비용·조건은 면제하지 않는다.
   - subscription: 효과는 cosmetic·event_track만, 시뮬 효과 0. 진행 효과를 넣으면 ERROR.
   - 오프라인 상한 효과를 가진 상품은 ERROR(기존 규칙 유지).

## 4. 시뮬
- 플레이어 상태: 완료 노드 집합, 진행 중 노드·완료 시각.
- 정책(자연 연구): 슬롯이 비면 조건·비용을 만족하는 다음 노드를 시작한다.
  - 우선순위: production(I → A 순서 유지) → ecology.
  - 기본 재료를 연구에 쓸 때 해금·강화 목표를 해치지 않게 기존 예약 로직과 맞춘다. 판단 방법을 문서화한다.
- 연구 포인트 수입: 현행대로 놓아주기(보관함 만석 시)에서만. 자발적 놓아주기 정책은 추가하지 않는다. 대신 수입·잔고를 지표로 보고한다.
- 새 페르소나(같은 pairing_group으로 공통 난수 공유)
  - balanced_noresearch: balanced와 같은 일정, 연구 비활성.
  - balanced_research_cap: 조건(필드·도감·선행)을 만족하는 즉시 비용·대기 없이 완료(상한 시험).
  - balanced(자연 연구)와 balanced_paid는 연구 활성.
  - balanced_paid는 생산 연구가 진행 중이면 research_time_skip을 구매한다(하루 구매 상한 가안 placeholder).
- 시간은 기존 정수 분·사건 기반 방식을 따른다. 연구 완료를 사건 경계로 추가한다.

## 5. 지표·판정 (criteria.json)
- research_cap_shortening
  - 필드 구간별 S = 1 − Δcap/Δnone(Δ = 다음 필드 해금 분 − 현재 필드 진입 분, 분 단위 사건 시각, 같은 replicate 짝).
  - 판정: 중앙값과 95% 신뢰구간 상단 ≤ 0.15. approved(사용자 R2). 신뢰구간 계산법(표준 라이브러리, 결정적)을 README에 적는다. 경계를 걸치면 INCONCLUSIVE.
  - 능선 누적 단축도 함께 보고한다(INFO, 목표 0.10~0.15 참고).
- research_natural_gain: balanced 대 balanced_noresearch의 능선 누적 해금 단축 중앙값 ≥ 0.03. approved(사용자 결정 2026-11-09).
- noresearch_unlock: balanced_noresearch 능선 도달률·p50 ≤ 16.8일·p90 ≤ 21일. approved.
- research_skip_gain: balanced_paid 대 balanced에서 연구 단축 효과. 공통 무연구 분모 %p 차이, 자연 연구 대비 상대값을 따로 보고(INFO, 결정 C3). 다른 상품 효과는 분리한다(가능하면 단축만 하는 비교군 또는 분해 방법을 문서화).
- 기존 paid_unlock_shortening(≤0.5), g2_r_*, unlock 목표, ★4는 연구 포함 페르소나로 다시 판정한다.
- INFO: 일별 연구 포인트 수입·누적·잔고, 노드별 완료일 분포, 연구 완료 후 연구 포인트 적체.

## 6. 테스트 (unittest)
- 공식 골든 벡터(곱셈 순서, 반올림)
- 검증기 broken fixture: 예산 초과, 중간 상태 A>I, 금지 효과, research 지급 상품, ecology 노드 speedup_allowed, subscription 진행 효과
- 연구 완료 경계에서 오프라인 생산 분할(소급 없음)
- cap 페르소나의 즉시 완료, noresearch의 연구 0
- 새 페르소나 공통 난수 키(구매 여부·persona_id 미포함)
- 결정성(같은 입력 → 같은 CSV 바이트)

## 7. 실행·조정·보고
1. unittest·validate·gen-tables --check 통과를 단계마다 체크포인트로 남긴다.
2. quick 실행(새 run_id).
3. 판정이 어긋나면 research.json의 비용·시간만 조정한다.
   - 10시드 반복은 최대 4회로 제한한다.
   - 그래도 못 맞추면 가장 나은 조합에서 멈추고 원인을 '사용자 질문'으로 남긴다.
   - 효과 상한(1200)이나 다른 밸런스를 바꾸는 판단은 하지 않는다.
4. ~~최종 판정용 기본 200시드 실행(새 run_id, 8 workers).~~ → **변경(사용자 결정 2026-11-09): 최종 판정은 100시드(새 run_id, `--seeds 100 --workers 8`).** 시간이 크게 걸리면 소요 시간을 보고한다.
   - 100은 criteria.json min_samples_tail과 같아 꼬리(p99) 판정도 가능하다.
   - approved 판정 중 신뢰구간이 경계를 걸친 항목(INCONCLUSIVE)이나 ★4 p99처럼 기준선에 걸린 항목은 200시드로 자동 재실행하지 않고 보고에 '200시드 재확인 후보'로 남긴다.
5. 보고(한국어, 간결)
   - 테스트·validate 결과, 바꾼 파일
   - 구간별·누적 cap 단축(중앙값·CI), 자연 연구 이득, 무연구 p50/p90
   - 연구 포인트 수입과 노드 완료일
   - 연구 포함 상태의 기존 판정(G2·과금·★4·해금 목표) 변화
   - FAIL·WARN 목록, 사용자 질문
6. docs/econ_sim_stage4_handoff.md와 같은 형식으로 docs/research_sim_handoff.md에 진행 상태를 남긴다(중단 대비).
