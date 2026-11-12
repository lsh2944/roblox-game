"""乱数の派生.

seed = sha256(JSON[version, master_seed, pairing_group_id, replicate_id, stream]) の先頭 8 バイト。
購入有無・persona_id はキーに含めない（比較群が同じ潜在抽選値を共有する共通乱数のため）。
JSON 配列で連結するので "a|b"+"c" と "a"+"b|c" のような区切り衝突は起きない。
"""
from __future__ import annotations

import hashlib
import json
import random

RNG_VERSION = "econ_sim.rng/1"
# 2 段階で使う予定のストリーム名（用途ごとに系列を分け、ある用途の抽選回数が他に影響しないようにする）
STREAMS = ("capture", "hunt_drop", "session_jitter", "policy_tiebreak")


def derive_seed(master_seed: int, pairing_group_id: str, replicate_id: int, stream: str) -> int:
    if isinstance(master_seed, bool) or not isinstance(master_seed, int):
        raise TypeError("master_seed는 int")
    if isinstance(replicate_id, bool) or not isinstance(replicate_id, int) or replicate_id < 0:
        raise TypeError("replicate_id는 0 이상의 int")
    if not isinstance(pairing_group_id, str) or not pairing_group_id:
        raise TypeError("pairing_group_id는 비어 있지 않은 str")
    if not isinstance(stream, str) or not stream:
        raise TypeError("stream은 비어 있지 않은 str")
    payload = json.dumps(
        [RNG_VERSION, master_seed, pairing_group_id, replicate_id, stream],
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return int.from_bytes(hashlib.sha256(payload).digest()[:8], "big")


def make_rng(master_seed: int, pairing_group_id: str, replicate_id: int, stream: str) -> random.Random:
    return random.Random(derive_seed(master_seed, pairing_group_id, replicate_id, stream))
