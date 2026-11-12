"""既定パス（実行 cwd に依存しないようパッケージ位置から解決する）."""
from __future__ import annotations

from pathlib import Path

PKG_DIR = Path(__file__).resolve().parent
TOOL_DIR = PKG_DIR.parent  # roblox-game/tools/econ_sim
GAME_ROOT = TOOL_DIR.parent.parent  # roblox-game
DEFAULT_DATA_DIR = GAME_ROOT / "data"
DEFAULT_CONFIG_DIR = TOOL_DIR / "config"
DEFAULT_OUTPUT_DIR = GAME_ROOT / "outputs"
