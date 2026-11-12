"""data/ の読み込み（manifest.json を入口とする）とパッチ適用.

読み込みエラーは例外にせず Issue として返し、validate がまとめて報告できるようにする。
パッチ（検証用の壊れたデータ・将来の --set 感度分析）は読み込んだ辞書に適用し、元ファイルは変更しない。
"""
from __future__ import annotations

import copy
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import jsonio
from .schema import Issue, err

MANIFEST_NAME = "manifest.json"
REQUIRED_FILES = (
    "resources",
    "rules",
    "spirits",
    "curves",
    "facilities",
    "tools",
    "fields",
    "hub",
    "daily_quests",
    "products",
    "releases",
    "capture",
    "upgrade_tables",
    "test_vectors",
)
_SAFE_REL = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_./-]*\.json")


@dataclass
class GameData:
    data_dir: Path
    manifest: dict[str, Any] | None = None
    docs: dict[str, Any] = field(default_factory=dict)
    rel_paths: dict[str, str] = field(default_factory=dict)
    roles: dict[str, str] = field(default_factory=dict)
    file_sha256: dict[str, str] = field(default_factory=dict)
    issues: list[Issue] = field(default_factory=list)
    patched: bool = False

    def label(self, name: str) -> str:
        return self.rel_paths.get(name, name)


def _resolve_inside(data_dir: Path, rel: str) -> Path | None:
    """manifest の相対パスを data_dir 内に限定して解決する（.. ・絶対パス・外部へのリンクを拒否）."""
    if not _SAFE_REL.fullmatch(rel) or ".." in Path(rel).parts:
        return None
    candidate = data_dir / rel
    try:
        resolved = candidate.resolve()
        resolved.relative_to(data_dir.resolve())
    except (OSError, ValueError):
        return None
    return candidate


def load_data(data_dir: Path | str, patch_ops: list[dict[str, Any]] | None = None) -> GameData:
    data_dir = Path(data_dir)
    gd = GameData(data_dir=data_dir)
    manifest_path = data_dir / MANIFEST_NAME
    if not manifest_path.is_file():
        err(gd.issues, "LOAD_MISSING", MANIFEST_NAME, f"manifest가 없음: {manifest_path}")
        return gd
    try:
        manifest = jsonio.load_strict(manifest_path)
    except (OSError, ValueError) as exc:
        err(gd.issues, "LOAD_JSON", MANIFEST_NAME, str(exc))
        return gd
    gd.manifest = manifest
    files = manifest.get("files") if isinstance(manifest, dict) else None
    if not isinstance(files, list):
        err(gd.issues, "LOAD_MANIFEST", MANIFEST_NAME, "files 배열이 필요")
        return gd
    for i, entry in enumerate(files):
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str) or not isinstance(entry.get("path"), str):
            err(gd.issues, "LOAD_MANIFEST", f"{MANIFEST_NAME}:/files/{i}", "id·path 문자열이 필요")
            continue
        name, rel = entry["id"], entry["path"]
        if name in gd.rel_paths:
            err(gd.issues, "LOAD_MANIFEST", f"{MANIFEST_NAME}:/files/{i}", f"id 중복: {name}")
            continue
        gd.rel_paths[name] = rel
        gd.roles[name] = str(entry.get("role", "source"))
        path = _resolve_inside(data_dir, rel)
        if path is None:
            err(gd.issues, "LOAD_PATH", f"{MANIFEST_NAME}:/files/{i}", f"data 디렉터리 밖이거나 허용되지 않는 경로: {rel}")
            continue
        if not path.is_file():
            err(gd.issues, "LOAD_MISSING", rel, "파일이 없음")
            continue
        try:
            raw = path.read_bytes()
            gd.file_sha256[name] = jsonio.sha256_hex(raw)
            gd.docs[name] = jsonio.loads_strict(raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as exc:
            err(gd.issues, "LOAD_JSON", rel, str(exc))
    for name in REQUIRED_FILES:
        if name not in gd.rel_paths:
            err(gd.issues, "LOAD_MANIFEST", MANIFEST_NAME, f"필수 파일 항목 누락: {name}")
    if patch_ops:
        apply_patch_ops(gd, patch_ops)
    return gd


class PatchError(ValueError):
    pass


def _select(container: Any, seg: str) -> tuple[Any, Any]:
    """パス区切り 1 個を解決し (親, キー) を返す。配列は数値添字・id:<値>・<キー>=<値> で指定する."""
    if isinstance(container, list):
        if seg.startswith("id:") or "=" in seg:
            key, want = ("id", seg[3:]) if seg.startswith("id:") else seg.split("=", 1)
            for i, item in enumerate(container):
                if isinstance(item, dict) and item.get(key) == want:
                    return container, i
            raise PatchError(f"{key}={want} 항목이 없음")
        if seg.isdigit() and int(seg) < len(container):
            return container, int(seg)
        raise PatchError(f"배열 인덱스 오류: {seg}")
    if isinstance(container, dict):
        return container, seg
    raise PatchError(f"경로를 더 내려갈 수 없음: {seg}")


def apply_patch_ops(gd: GameData, ops: list[dict[str, Any]]) -> None:
    """ops: [{op: set|remove|append, file: manifest id, path: "/a/id:x/b", value}]."""
    for n, op in enumerate(ops):
        name = op.get("file")
        if name not in gd.docs:
            raise PatchError(f"ops[{n}]: 파일 {name}이 로드되지 않음")
        doc = copy.deepcopy(gd.docs[name])
        segs = [s for s in str(op.get("path", "")).split("/") if s]
        kind = op.get("op")
        if not segs and kind != "append":
            raise PatchError(f"ops[{n}]: 경로가 비어 있음")
        cur = doc
        for seg in segs[:-1] if kind != "append" else segs:
            parent, key = _select(cur, seg)
            if isinstance(parent, dict) and key not in parent:
                raise PatchError(f"ops[{n}]: 키 없음 {seg}")
            cur = parent[key]
        if kind == "append":
            if not isinstance(cur, list):
                raise PatchError(f"ops[{n}]: append 대상이 배열이 아님")
            cur.append(copy.deepcopy(op["value"]))
        elif kind == "set":
            parent, key = _select(cur, segs[-1])
            parent[key] = copy.deepcopy(op["value"])
        elif kind == "remove":
            parent, key = _select(cur, segs[-1])
            if isinstance(parent, dict) and key not in parent:
                raise PatchError(f"ops[{n}]: 키 없음 {segs[-1]}")
            del parent[key]
        else:
            raise PatchError(f"ops[{n}]: 알 수 없는 op {kind}")
        gd.docs[name] = doc
    gd.patched = True


def load_patch_file(path: Path | str) -> dict[str, Any]:
    doc = jsonio.load_strict(Path(path))
    if not isinstance(doc, dict) or not isinstance(doc.get("ops"), list):
        raise PatchError("패치 파일에는 ops 배열이 필요")
    return doc


def collect_placeholders(gd: GameData) -> list[dict[str, str]]:
    """placeholder: true が付いたオブジェクトの一覧（run メタ・README 用）."""
    found: list[dict[str, str]] = []

    def walk(v: Any, file: str, path: str) -> None:
        if isinstance(v, dict):
            if v.get("placeholder") is True:
                found.append(
                    {
                        "file": file,
                        "path": path or "/",
                        "id": str(v.get("id", "")),
                        "notes": str(v.get("notes", "")),
                    }
                )
            for k, val in v.items():
                walk(val, file, f"{path}/{k}")
        elif isinstance(v, list):
            for i, val in enumerate(v):
                sub = f"{path}/{i}"
                if isinstance(val, dict) and isinstance(val.get("id"), str):
                    sub = f"{path}/{i}[{val['id']}]"
                walk(val, file, sub)

    for name in sorted(gd.docs):
        walk(gd.docs[name], gd.label(name), "")
    return found
