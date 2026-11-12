"""厳格な JSON 入出力と正準化ハッシュ.

- 重複キー・NaN/Infinity・BOM を拒否する（Luau 側の JSONDecode と同じ解釈に揃えるため）。
- null の検出はスキーマ検証側で行う（パスを付けて報告するため）。
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import tempfile
from pathlib import Path
from typing import Any


class StrictJsonError(ValueError):
    """厳格 JSON の規則違反."""


def _no_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    obj: dict[str, Any] = {}
    for key, value in pairs:
        if key in obj:
            raise StrictJsonError(f"중복 키: {key!r}")
        obj[key] = value
    return obj


def _reject_constant(name: str) -> Any:
    raise StrictJsonError(f"비유한 수는 금지: {name}")


def _parse_float(text: str) -> float:
    value = float(text)
    if not math.isfinite(value):
        raise StrictJsonError(f"비유한 수는 금지: {text}")
    return value


def loads_strict(text: str) -> Any:
    if text.startswith("﻿"):
        raise StrictJsonError("BOM 포함 UTF-8은 허용하지 않음")
    return json.loads(
        text,
        object_pairs_hook=_no_duplicate_keys,
        parse_constant=_reject_constant,
        parse_float=_parse_float,
    )


def load_strict(path: Path) -> Any:
    return loads_strict(Path(path).read_text(encoding="utf-8"))


def canonical_bytes(obj: Any) -> bytes:
    """キー順・空白を固定した正準表現（ハッシュ用）."""
    return json.dumps(
        obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False
    ).encode("utf-8")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_sha256(obj: Any) -> str:
    return sha256_hex(canonical_bytes(obj))


def dump_pretty(obj: Any) -> str:
    return json.dumps(obj, indent=2, ensure_ascii=False, allow_nan=False) + "\n"


def write_text_atomic(path: Path, text: str) -> None:
    """同じディレクトリの一時ファイルに書いてから置き換える（途中失敗で壊れたファイルを残さない）."""
    path = Path(path)
    if path.is_symlink():
        raise OSError(f"심볼릭 링크에는 쓰지 않음: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
