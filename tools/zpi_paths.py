"""
Where things are, worked out from where this tools folder sits.

Expected layout (the whole mission folder can be one git repository):

    <Arma profile>\\                      e.g. Documents\\Arma 3  or  Documents\\Arma 3 - Other Profiles\\<name>
      missions\\<Mission>.<World>\\        e.g. missions\\ZPI_scenario.Altis  (mission = repository root)
        mission.sqm, description.ext, init.sqf, zpi\\ ...
        tools\\                           <- this folder
        output\\                          <- everything the tools make (datasets, orthophotos, ...; not in git)
      Screenshots\\zpi\\<session>\\        <- screenshots taken by the mission
    %LOCALAPPDATA%\\Arma 3\\*.rpt          <- game logs with the labels and telemetry
"""
from __future__ import annotations

import os
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
MISSION_DIR = TOOLS_DIR.parent
PROFILE_DIR = MISSION_DIR.parent.parent
OUTPUT_DIR = MISSION_DIR / "output"
SCREENSHOT_DIR = PROFILE_DIR / "Screenshots"
RPT_DIR = Path(os.environ["LOCALAPPDATA"]) / "Arma 3"


def out_path(p: str | os.PathLike) -> Path:
    """Output location: absolute paths stay as they are, names go into OUTPUT_DIR."""
    p = Path(p)
    return p if p.is_absolute() else OUTPUT_DIR / p


def rpt_files() -> list[Path]:
    """Every game log, oldest first (a new log starts at every game launch)."""
    return sorted(RPT_DIR.glob("*.rpt"), key=lambda p: p.stat().st_mtime)


def find_image(rel: str, dirs: list[Path]) -> Path | None:
    """A logged image path (zpi/<session>/<file>) in the first Screenshots folder that has it."""
    for d in dirs:
        p = d / rel.replace("\\", "/")
        if p.exists():
            return p
    return None


def describe() -> str:
    return f"mission: {MISSION_DIR}\nscreenshots: {SCREENSHOT_DIR}\nlogs: {RPT_DIR}\noutput: {OUTPUT_DIR}"


if __name__ == "__main__":
    print(describe())
