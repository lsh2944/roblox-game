# econ_sim 4단계 인계 메모 (2026-11-06)

- 대상: /Users/leeseunghak/project/roblox-game (Git 미사용)
- 기준 run: outputs/20261106T065238Z_quick (3단계 결과, 4단계 코드로 다시 돌리지 않음)
- 이번 세션에서는 quick 실행을 하지 않음(범위 축소 지시)

## 테스트·검증 (마지막 확인)

cwd: /Users/leeseunghak/project/roblox-game/tools/econ_sim

| 명령 | 결과 |
|---|---|
| `python3 -m unittest discover -s tests` | 90개 OK (3단계 80 + 4단계 test_stage4.py 10) |
| `python3 -m econ_sim validate` | ERROR 0, WARN 0 |
| `python3 -m econ_sim gen-tables --check` | 최신 |

## 항목별 상태

### A. 리뷰 수정
- **Major 1 최대 R 분리 — 완료**
  - state.py: `RStat`(max_outside / max_transition 분리)
  - DayAcc: r_best / r_actual
  - runner.py: `R_KEYS`, 일별 열 `g2_{best,actual}_r_max_outside` / `_r_max_transition`
  - metrics: 사유 문구를 구간 밖·안으로 나눔
- **Major 2 소진 판정 — 완료**
  - policy.py:577 `is_exhausted`: 효과 0 거점 등급, 해당 페르소나에게 이득 0인 오프라인 상한 강화는 제외
- **Major 3 static 진입 상태 재정의 — 부분완료**
  - 코드 지원은 완료
    - static_analysis.py:45-46, 325 이하: `facility_levels_by_resource` / `staff_members_by_resource` / `companion_members_by_resource`
    - economy.py:214 `reference_idle_rates`도 같은 키를 지원
  - 미완: config/static_reference.json:60(forest_entry)·96(cave_entry)·132(ridge_entry)
    - 값과 notes(:4)가 아직 3단계 값입니다. ridge_entry는 시설 28로 동굴 상한 24를 넘는 불가능한 상태입니다.
    - 해금 직전 관측 스크립트: docs/stage4_tools/observe_entry.py
      - 실행: `PYTHONPATH=<tools/econ_sim> python3 observe_entry.py 10`
      - 관측 결과(D 착수 전 데이터): docs/stage4_tools/entry_obs.json
        - 숲: 1일차, 시설 Lv2, 도구 1
        - 동굴: 5.5일차, 이슬·꽃빛 Lv11, 결정 Lv13, 도구 15
        - 능선: 11일차, 22 / 24 / 16, 도구 18.5
    - 남은 일
      1. 데이터 재조정(D) 후 다시 관측합니다.
      2. *_entry에 `facility_levels_by_resource`와 실제 종 목록을 넣습니다.
      3. 관측 방법을 notes에 적습니다.
      4. static 진입 R을 다시 계산합니다.
- **Minor — 완료**
  - hunt_targets: 입수 경로 없는 재료 제외(policy.py:235)
  - assumptions 문구 갱신
  - cli manifest rng.streams에 `individual:day<N>`·`individual:start` 추가
  - g3 해금 대기의 빈 값은 "불가"로 표시
  - test_rules_f.py의 `unittest.main()`을 파일 끝으로 이동
- **테스트 (a)~(f) — 완료**
  - tests/test_stage4.py, 10개 통과
  - 축소 지시 전에 이미 추가돼 있어 그대로 둠

### B. G2 측정 기준 — 완료(데이터 영향 검증은 D와 함께)
- **원인 계측(스크래치 패치):** 전환 구간 밖 실제 R>3은 balanced 3회 실행에 29단계였습니다.
  - 대부분 동굴 진입 직후 시설 Lv9 상태의 이슬 노드였습니다(최선 배치 기준으로도 R 4.3 → 데이터 문제).
  - 꽃빛 정원 5칸 중 1마리 배치 사례가 있었습니다(진동).
- **진동 대책:** policy.py:439 부근. weights()의 균형 보정을 지수 평활(0.5) 방치량 기준으로 바꿈.
- **판정 분모:** 최선 배치 기준 R로 바꿈.
  - sim.py:249 `best_idle_rate`: 그 자원 시설에 현재 보유 정령 중 최선 조합(배치 휴리스틱)을 놓았을 때의 방치량, 도감 보너스 포함
  - 실제 배치 R은 참고 행 `g2_r_actual_reference`(INFO)

### C. 사용자 결정 — 설정·판정은 완료, 데이터 의존 부분은 미착수
- **C1 전환 구간 4320분:** 완료(criteria.json g2.transition_minutes)
- **C2 필드별 R 대역 1.5~2.5(draft)·하드코어 선행 ≥2일(draft):** 판정 행은 완료
  - metrics: `g2_r_field_band`, `heavy_user_lead`
  - criteria: g2.field_band_*, sim.lead
  - 도구 곡선 조정은 D로 미룸
- **C3 방치 특수재화:** 기간별(마지막 필드 해금까지 / D1~14 / D15+)·필드별·등급별 INFO 완료
  - sim의 등급별 적립 → daily `home_g1..4`
- **C4 ★4:** 완료
  - `star4_first_capture_p99`: balanced만 approved(진입 필드 첫 진입 후 일수 p99 ≤14), 나머지는 INFO
  - light_1h는 포획 30분 + 채집·사냥 flex 30분(personas.json). README에는 아직 미기재.
- **C5 적체:** 완료(`hunt_material_stock_end` INFO)

### D. 데이터 재조정 — 미착수(시도 후 원복)
- 시도했던 조합: 도구 곡선을 시설과 같은 모양(+10%/Lv, Lv10·25 ×2) + 결정 공방 15 → 25 + 동굴 꽃빛 노드 830
  - 10시드 결과: 전환 구간 밖 R>3 약 87%, 필드별 R 6~7 → 노드량을 재보정하지 않아 과대
  - 원복 완료: data/curves.json:26(per_level 0.05, 마일스톤 없음), facilities.json:47(base 15), cave_bloom 노드 제거, gen-tables 재생성
- 현재 데이터(D 착수 전, 4단계 코드)로 10시드 측정한 기준값
  - balanced 능선 p50 11일 → approved 목표(11.2~16.8일) FAIL
  - 하드코어 선행 0일
  - 필드별 R(최선 배치 기준): 동굴 0.5~0.8, 능선 약 1.25(대역 아래)
  - 전환 구간 밖 R>3: balanced 0.02%, light_1h 0.55%
  - ★4 balanced p99: 5일 / 7일 PASS
  - 과금 단축 ≤0.15 PASS

### E. quick 실행·보고 — 미착수

## 바꾼 파일 (4단계)
- **econ_sim/:** state.py, sim.py, runner.py, metrics.py, policy.py, economy.py, static_analysis.py, cli.py, assumptions.py
- **config/:** criteria.json, personas.json
- **tests/:** test_stage4.py(신규), test_sim_rules.py(G2 구조 변경에 맞춘 기대값), test_rules_f.py(main 위치)
- **data/:** 최종적으로 변경 없음(D 시도분 원복, 강화표 재생성 결과는 원래 값과 같은 정의)

## 다음 순서
1. D: 도구 곡선을 가파르게 하고 필드별 노드량을 시뮬 R 기준으로 비례 재보정(목표 R 약 2).
   - 결정 공방 기본량·동굴 꽃빛 노드·능선 노드는 함께 판단
   - 능선 해금 비용으로 balanced p50 14일, 사냥 요구로 하드코어 −2일
   - 유지 제약(지배 경고 0, G3 10~60분, 의뢰 3일, 과금 ≤50%, balanced ★4 p99 ≤14)
   - 반복 측정 도구: docs/stage4_tools/iter.sh `<out이름>` [시드 수] → run·report 후 핵심 판정 요약
2. Major 3 마무리: D 이후 observe_entry.py로 다시 관측 → static_reference *_entry 값·notes 갱신 → static 재계산
3. README에 4단계 내용 반영(G2 최선 배치 기준, 전환 4320분, light_1h 배분, 새 INFO 지표)
4. 전체 unittest·validate → `python3 -m econ_sim all --quick --workers 8`(새 run_id, 덮어쓰기 금지) → 보고

## 4단계 완료/미완 (2026-11-09 재개분)

### 완료
- **D 데이터 재조정**
  - iter.sh 10시드 6회(iter_d2~d7). 최종 조합 = outputs/iter_d7.
  - 정책 보완 1건(policy.py `_eta_acceptable`): 회수기간 1일 이내 강화는 목표 ETA 1% 악화까지 허용. 하드코어가 병목 자원 때문에 게이트 강화를 영구 보류하던 문제를 고침.
- **Major 3 마무리**
  - observe_entry.py가 해금으로 새로 열린 시설의 직후 배치도 기록하도록 수정 → 재관측(entry_obs.json 갱신)
  - static_reference `*_entry`·notes 갱신 → static 재계산
- **README 4단계 반영:** G2 최선 배치 기준, 전환 4320분, light_1h 배분, 새 지표, 데이터 표
- **검증:** unittest 90 OK, validate ERROR 0·WARN 0, gen-tables --check 최신
- **quick:** outputs/20261109T002523Z_quick(80회, 8병렬, 120초). 판정 PASS 54, WARN 13, FAIL 1, INCONCLUSIVE 24, INFO 65.

### 미완·확인 필요
- **light_1h 전환 구간 밖 R>3 0.30%(approved FAIL)**: 능선 해금 +3~6일 구간입니다. light_1h는 시설을 따라잡는 속도가 느려 3일 전환 구간을 넘깁니다.
- **heavy_user_lead(draft)**: 20시드에서는 1일(하드코어 14 / balanced 15)로 WARN입니다(10시드에서는 2일).
- **콘텐츠 소진(draft)**: balanced D30에 100% 도달해 WARN입니다(Major 2 수정 후 판정 가능해지면서 드러남). 모든 시설·도구가 Lv30에 도달합니다.
- **static `*_entry` R**: 해금 순간이라 2.7~6.7이고 3 초과는 FAIL입니다. static 판정에는 전환 구간 면제가 없습니다(사용자 질문).
- **`*_exit` 상태**: 가상 기준 정령(일부는 실재하지 않는 적성·채집력 조합)이 그대로입니다.

### 출력 폴더 정리 제안(삭제는 하지 않음)
- 남길 것: outputs/20261109T002523Z_quick(최종), outputs/iter_d7(최종 조합 10시드·static_entry_check 포함)
- 정리 후보(사용자 판단): outputs/iter_d2~d6(중간 조합)

## 4단계 마감 (2026-11-09, 메인)
- 사용자 결정(2026-11-09)
  - 헤비 선행 1~2일 수용(lead.min_days 1)
  - 3배 판정은 3시간 이상 페르소나만(sim.g2_approved_personas, light_1h는 INFO)
  - MVP는 D30 콘텐츠 소진 수용(exhaustion_info_only, 새 필드 업데이트로 대응)
  - static 진입 순간 행은 전환 구간 면제(static_reference *_entry의 transition_exempt → INFO)
- 코드: metrics.py(g2 참고 페르소나·소진 INFO), static_analysis.py(transition_exempt), tests/test_static.py(면제 규칙 반영)
- 검증(cwd tools/econ_sim): unittest 90 OK / validate ERROR 0·WARN 0 / gen-tables --check 최신
- 최종 run: outputs/20261109T004917Z_quick — PASS 54, WARN 10(모두 draft), FAIL 0, INCONCLUSIVE 24, INFO 69
  - 직전 run 20261109T002523Z_quick은 기준 변경 전 결과
- 정리: outputs/iter_d2~d6 삭제(사용자 승인). iter_d7 보관. outputs/static은 11/06 단독 static 결과(구버전)
- 다음 설계 주제(사용자 요청 2026-11-09, 미착수): 자원 소비처 확대(포획 도구·건축·지역 전용 제작·다음 지역 해금 재료), 장기적으로 유저 간 거래·교환 경제
