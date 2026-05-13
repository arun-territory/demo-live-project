import sys
from pathlib import Path

# Allow tests to import the gateway module
sys.path.insert(
    0,
    str(Path(__file__).resolve().parents[2] / "docker" / "apikey-gateway"),
)
