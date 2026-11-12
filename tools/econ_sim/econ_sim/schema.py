"""標準ライブラリだけの小さな宣言型スキーマ検証器.

JSON Schema 全体の準拠は主張しない。ここで定義した型・必須・enum・範囲・ID 重複のみを検査する。
全オブジェクトでメタ情報キー placeholder(bool)・notes(str) を許可する。
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

META_KEYS = {"placeholder": "bool", "notes": "str"}


@dataclass(frozen=True)
class Issue:
    level: str  # "ERROR" | "WARN"
    code: str
    path: str
    message: str

    def format(self) -> str:
        return f"[{self.level}] {self.code} {self.path}: {self.message}"


def err(out: list[Issue], code: str, path: str, message: str) -> None:
    out.append(Issue("ERROR", code, path, message))


def warn(out: list[Issue], code: str, path: str, message: str) -> None:
    out.append(Issue("WARN", code, path, message))


def _type_name(v: Any) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, int):
        return "int"
    if isinstance(v, float):
        return "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    if isinstance(v, dict):
        return "object"
    return type(v).__name__


class Spec:
    expected = "?"

    def check(self, v: Any, path: str, out: list[Issue]) -> None:  # pragma: no cover - 抽象
        raise NotImplementedError

    def _null_or_type(self, v: Any, ok: bool, path: str, out: list[Issue]) -> bool:
        if v is None:
            err(out, "NULL_VALUE", path, "null은 금지")
            return False
        if not ok:
            err(out, "SCHEMA_TYPE", path, f"{self.expected} 필요, 실제 {_type_name(v)}")
            return False
        return True


class AnyValue(Spec):
    expected = "any"

    def check(self, v: Any, path: str, out: list[Issue]) -> None:
        find_nulls(v, path, out)


class Bool(Spec):
    expected = "bool"

    def check(self, v: Any, path: str, out: list[Issue]) -> None:
        self._null_or_type(v, isinstance(v, bool), path, out)


class Str(Spec):
    expected = "string"

    def __init__(self, enum: list[str] | None = None, pattern: str | None = None, min_len: int = 0):
        self.enum = enum
        self.pattern = re.compile(pattern) if pattern else None
        self.min_len = min_len

    def check(self, v: Any, path: str, out: list[Issue]) -> None:
        if not self._null_or_type(v, isinstance(v, str), path, out):
            return
        if len(v) < self.min_len:
            err(out, "SCHEMA_RANGE", path, f"최소 길이 {self.min_len}")
        if self.enum is not None and v not in self.enum:
            err(out, "SCHEMA_ENUM", path, f"{v!r}는 허용값 {self.enum}에 없음")
        if self.pattern is not None and not self.pattern.fullmatch(v):
            err(out, "SCHEMA_PATTERN", path, f"{v!r}가 형식 {self.pattern.pattern}과 불일치")


class Int(Spec):
    expected = "int"

    def __init__(self, min: int | None = None, max: int | None = None):
        self.min = min
        self.max = max

    def check(self, v: Any, path: str, out: list[Issue]) -> None:
        ok = isinstance(v, int) and not isinstance(v, bool)
        if not self._null_or_type(v, ok, path, out):
            return
        if self.min is not None and v < self.min:
            err(out, "SCHEMA_RANGE", path, f"{v} < 최소 {self.min}")
        if self.max is not None and v > self.max:
            err(out, "SCHEMA_RANGE", path, f"{v} > 최대 {self.max}")


class Num(Spec):
    expected = "number"

    def __init__(self, min: float | None = None, max: float | None = None, exclusive_min: bool = False):
        self.min = min
        self.max = max
        self.exclusive_min = exclusive_min

    def check(self, v: Any, path: str, out: list[Issue]) -> None:
        ok = isinstance(v, (int, float)) and not isinstance(v, bool)
        if not self._null_or_type(v, ok, path, out):
            return
        if self.min is not None and (v <= self.min if self.exclusive_min else v < self.min):
            err(out, "SCHEMA_RANGE", path, f"{v}가 최소 {self.min} 조건 위반")
        if self.max is not None and v > self.max:
            err(out, "SCHEMA_RANGE", path, f"{v} > 최대 {self.max}")


class Arr(Spec):
    expected = "array"

    def __init__(self, item: Spec, min_items: int = 0, unique_id: bool = False):
        self.item = item
        self.min_items = min_items
        self.unique_id = unique_id

    def check(self, v: Any, path: str, out: list[Issue]) -> None:
        if not self._null_or_type(v, isinstance(v, list), path, out):
            return
        if len(v) < self.min_items:
            err(out, "SCHEMA_RANGE", path, f"항목 최소 {self.min_items}개 필요")
        seen: set[str] = set()
        for i, item in enumerate(v):
            child = item_path(path, i, item)
            self.item.check(item, child, out)
            if self.unique_id and isinstance(item, dict) and isinstance(item.get("id"), str):
                if item["id"] in seen:
                    err(out, "SCHEMA_DUP_ID", child, f"id 중복: {item['id']}")
                seen.add(item["id"])


class MapOf(Spec):
    """キーが ID 形式の辞書（キー集合の妥当性は規則側で検査）."""

    expected = "object"

    def __init__(self, key: Str, value: Spec):
        self.key = key
        self.value = value

    def check(self, v: Any, path: str, out: list[Issue]) -> None:
        if not self._null_or_type(v, isinstance(v, dict), path, out):
            return
        for k, val in v.items():
            self.key.check(k, f"{path}/{k}(key)", out)
            self.value.check(val, f"{path}/{k}", out)


class Obj(Spec):
    expected = "object"

    def __init__(self, req: dict[str, Spec] | None = None, opt: dict[str, Spec] | None = None):
        self.req = req or {}
        self.opt = opt or {}

    def check(self, v: Any, path: str, out: list[Issue]) -> None:
        if not self._null_or_type(v, isinstance(v, dict), path, out):
            return
        for key, spec in self.req.items():
            if key not in v:
                err(out, "SCHEMA_REQUIRED", path, f"필수 키 누락: {key}")
            else:
                spec.check(v[key], f"{path}/{key}", out)
        for key, value in v.items():
            if key in self.req:
                continue
            if key in self.opt:
                self.opt[key].check(value, f"{path}/{key}", out)
            elif key in META_KEYS:
                (Bool() if META_KEYS[key] == "bool" else Str()).check(value, f"{path}/{key}", out)
            else:
                err(out, "SCHEMA_UNKNOWN_KEY", path, f"알 수 없는 키: {key}")


def item_path(path: str, index: int, item: Any) -> str:
    if isinstance(item, dict) and isinstance(item.get("id"), str):
        return f"{path}/{index}[{item['id']}]"
    return f"{path}/{index}"


def find_nulls(v: Any, path: str, out: list[Issue]) -> None:
    if v is None:
        err(out, "NULL_VALUE", path, "null은 금지")
    elif isinstance(v, dict):
        for k, val in v.items():
            find_nulls(val, f"{path}/{k}", out)
    elif isinstance(v, list):
        for i, val in enumerate(v):
            find_nulls(val, item_path(path, i, val), out)


ID = Str(pattern=r"[a-z][a-z0-9_]*")
