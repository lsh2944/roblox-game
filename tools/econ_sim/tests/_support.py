"""テスト共通: 実データ・fixture の場所（cwd に依存しない）."""
from pathlib import Path

from econ_sim.paths import DEFAULT_CONFIG_DIR, DEFAULT_DATA_DIR

TESTS_DIR = Path(__file__).resolve().parent
FIXTURES_DIR = TESTS_DIR / "fixtures"
DATA_DIR = DEFAULT_DATA_DIR
CONFIG_DIR = DEFAULT_CONFIG_DIR
