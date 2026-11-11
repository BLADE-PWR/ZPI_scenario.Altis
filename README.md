# ZPI scene pack

An Arma 3 mission that spawns military scenes (soldiers, tanks, vehicles, buildings, explosions), films them with a drone-like camera and labels every screenshot automatically. Python tools turn the screenshots into a YOLO dataset, measure the localisation error and stitch orthophotos.

## Setup

1. In the Arma 3 Launcher, under **Parameters → Advanced**, tick **Show Script Errors** and leave **No Logs** unticked: the labels are written to the game log. Turn **BattlEye** off: the telemetry extension is unsigned.
2. Clone the repository into your missions folder:
   ```
   cd "%USERPROFILE%\Documents\Arma 3\missions"
   git clone https://github.com/BLADE-PWR/ZPI_scenario.Altis
   ```
3. Install the Python packages: `python -m pip install -r ZPI_scenario.Altis\tools\requirements.txt`
4. With the game closed, add `maxScreenShotFolderSizeMB = 20000;` to `Documents\Arma 3\<profile>.Arma3Profile`
5. In the game, open the Eden Editor on map Altis, then **Scenario → Open → ZPI_scenario** and **Play in Singleplayer**
6. Video settings: keep the **Overall Quality** at the highest. Make sure **HDR quality** is Standard, and turn **Bloom, Radial Blur and Rotation Blur** off

## Taking pictures

Press **H** in the mission for all keys and scenes. The main ones:

- **P** takes a screenshot and labels it.
- **Home** starts the dataset generator, which visits scenes and takes labelled pictures on its own until it is done. **Home** again stops it.
- **Z** flies an orthophoto of the scene area.

Every setting (what the generator makes, zoom, label rules, ...) is in `zpi\config.sqf`, with a comment on each.

Screenshots go to `Documents\Arma 3\Screenshots\zpi\<session>\`, the labels and telemetry to the game log in `%LOCALAPPDATA%\Arma 3\`. The tools find both on their own.

## Tools

Run them from the mission folder. Everything they make goes to `output\`, and every tool lists its options with `--help`.

```
python tools\make_yolo_dataset.py --latest   # YOLO dataset from the newest session  -> output\dataset
python tools\eval_geolocation.py             # localisation error of the labels      -> output\geoloc_eval
python tools\make_ortho.py                   # orthophoto map after Z                -> output\ortho
python tools\rpt_extract.py                  # telemetry and ground truth as JSONL   -> output\sessions
python tools\clean_start.py                  # delete outputs, screenshots and old logs
```

After making a dataset with `make_yolo_dataset.py`, look at `output\dataset\previews\` before training. Each image also gets a JSON in `output\dataset\meta\` with the camera pose, intrinsics, laser range, terrain grid and the map position of every object.

## Live telemetry (optional)

The extension sends the same records over UDP as they happen, without waiting for the log. Build it with the MSVC build tools; with the game folder as an argument, it is also copied there:

```
extension\build.bat "<PATH_TO_ARMA3>"
```

The target address is `ZPI_cfg_udpTarget` in `zpi\config.sqf`. When it works, the game log has a line `ZPI|info|extension zpi_telemetry ... reply ok`.
