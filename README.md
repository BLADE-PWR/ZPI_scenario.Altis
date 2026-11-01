# ZPI Arma 3 scene pack: drone ISR scenes, auto-labelled YOLO dataset, orthophoto

## Setup

1. In the Arma 3 Launcher, go to **Parameters → Advanced** and tick **Show Script Errors**. Leave **No Logs** unticked: the labels are written to the logs.
2. Clone the repository into your Arma 3 missions folder. On Windows, in a terminal:

```
cd "%USERPROFILE%\Documents\Arma 3\missions"
git clone https://github.com/Matistan/ZPI_scenario.Altis
```

3. Install Python and the tools' packages: `python -m pip install -r ZPI_scenario.Altis\tools\requirements.txt`
4. Raise the screenshot folder limit: add `maxScreenShotFolderSizeMB = 20000;` to `Documents\Arma 3\<profile>.Arma3Profile`, with the game closed.
5. Start Arma, open Eden Editor, open ZPI scenario: **Scenario → Open → ZPI_scenario** and click **Play in Singleplayer**.
6. Change video settings: set ultra overall quality, set **HDR quality** to **Standard** and turn **Bloom** off. You can also increase the **Sampling** to 200 % for 4K screenshots, but that only helps when training on tiles.

## Overview

Script-generated scenes with soldiers and armour are filmed by a camera a player flies himself or by the automatic dataset generator.

- **P** takes a screenshot and labels it automatically: soldiers by stance (standing, kneeling, prone), tanks, military vehicles, explosions, tank gun fire (`tank_fire`) and buildings.
- **Home** starts the **dataset generator**: it visits 23 scenes on green, open ground and makes `ZPI_cfg_tourTarget` labelled pictures by itself (1018 per run now: 982 + 1018 = 2000).
- **Every screenshot gets a JSON file** with the camera telemetry and intrinsics, the laser-rangefinder reading, a terrain height grid under the view and the map coordinates of every labelled object.
- **Z** flies an orthophoto of the scene area, which `tools/make_ortho.py` turns into a georeferenced map with the soldiers drawn on it.

The whole mission folder, including the Python tools, is one git repository: nothing has to be copied anywhere else.

```
ZPI_scenario.Altis\           mission folder = repository root (any name ending in .Altis)
  mission.sqm                 the Eden mission (player unit, ZPI_center_* markers) - saved by Eden
  description.ext             frame-number bar + on-screen readout (HUD), mission settings
  init.sqf                    entry point
  README.md                   this file
  .gitignore                  keeps output\, Python caches and trained models out of git
  zpi\                        script's source code
    config.sqf                everything you will want to tweak
    scenes.sqf                the 24 scenes (23 in the generator + "mixed")
    tour.sqf                  Home key: the dataset generator (sites, bursts, zoom, firing, explosions)
    sites.sqf                 where scenes go: green ground, few buildings, buildings a squad can enter
    drone.sqf                 camera, FOV, laser rangefinder, constant-pixel-size lock, HUD, telemetry
    capture.sqf               P key: freeze, screenshot, labels, terrain grid; explosion and gun-fire pictures
    ortho.sqf                 Z key: orthophoto tile flight
    spawn.sqf                 spawning, object registry, road/terrain queries
    env.sqf                   locations, time of day, weather, exposure, artillery barrage
    core.sqf                  shared helpers (logging, JSON, random)
    keys.sqf                  controls
  tools\                      Python tools (run them from the mission folder, see below)
    make_yolo_dataset.py      screenshots + logs -> YOLO dataset, per-screenshot JSON, previews, Roboflow zip
    eval_geolocation.py       localisation error from the camera model + terrain grid (CEP50/90)
    make_ortho.py             orthophoto tiles -> one map (PNG + world file) + map with soldiers
    zpi_enhance.py            haze correction (used by the dataset tool; also for live frames)
    clean_start.py            deletes outputs, screenshots and old logs to start from clean folders
    rpt_extract.py            logs -> per-session telemetry / ground truth JSONL (also live over UDP)
    frame_code.py             decode / strip the frame-number bar (screen captures only)
    zpi_paths.py              finds the screenshots, logs and output folder (shared by all tools)
    requirements.txt          required Python packages
  output\                     everything the tools make: dataset\, ortho\, sessions\, geoloc_eval\
```

What lives **outside** the mission folder, because Arma writes it there:

| What | Where | Found by the tools |
|---|---|---|
| screenshots | `Documents\Arma 3\Screenshots\zpi\<session>\` (or `Documents\Arma 3 - Other Profiles\<name>\Screenshots\...`) | automatically: the Screenshots folder of the profile the mission is in comes first |
| game logs with labels and telemetry | `%LOCALAPPDATA%\Arma 3\*.rpt` | automatically |

`python tools\zpi_paths.py` prints the four folders the tools will use (mission, screenshots, logs, output). Every tool also takes `--shots` / `--rpt` / `--out` to override them.

## On-screen readout (HUD)

The top-left corner shows, updated live:

```
LASER 734.2 m   TGT 051062  (5123, 6245)  elev 143.0 m  [Land_House_...]
ALT 612 m ASL / 469 m AGL   HDG 312.4   PITCH -32.0   CAM 048059
FOV 20.00 deg   GSD 0.077 m/px  soldier ~23 px   SCALE LOCK 0.080
GROUND #GdtGrassGreen (green 1.0)   BUILDINGS IN VIEW 2
BUILDING 0: 3 / 8 soldiers inside
```

- **LASER:** distance from the camera to whatever is under the crosshair in the middle of the screen: ground, building, tree or vehicle. It also gives the map grid, coordinates and elevation of that point, and the name of the object hit.
- **ALT / HDG / PITCH:** camera altitude above sea level and above the ground below it, compass heading, and pitch.
- **GSD:** metres per pixel at the crosshair, and how tall a standing soldier would be in pixels.
- **GROUND / BUILDINGS IN VIEW:** the ground type under the crosshair with its green score (what the generator uses to pick green sites), and how many buildings would get a box in a picture taken now. The generator never takes a picture with more than 3.
- **BUILDING:** only in the building scenes: soldiers inside / squad size.

The readout and the crosshair are UI, so they never appear in **P** screenshots: the screenshot command does not capture UI. **U** hides them.

## Controls

**Camera:**

| Key | Action |
|---|---|
| W A S D / E Q / Shift | move horizontally / up, down / faster |
| Mouse or arrow keys | look |
| Mouse wheel, PgUp / PgDn | change the FOV |
| R | constant pixel size on/off (see below) |

**Dataset:**

| Key | Action |
|---|---|
| P | screenshot + labels + JSON |
| Shift+P | auto-capture every 2 s on/off |
| K | firefight on/off: every 4 s, 2 vehicles and 4 soldiers fire at clear ground, so the shells explode in the picture |
| Shift+K | one volley |
| B | artillery barrage around the point you are looking at |
| I | automatic screenshot when an explosion happens on screen, on/off (default on) |
| Z | orthophoto of the scene area (takes about a minute; no input during the flight) |
| **Home** | **dataset generator:** makes 1000 labelled images by itself (clear weather, noon). Home again stops it |

**Scenes:**

| Key | Action |
|---|---|
| 0–9, - [ ], Shift + (0-9, - [ ] ; ' \\) | scenes (below) |
| N | new layout (seed + 1) |
| X | clear |
| L | next marker location |
| C | move scene to the middle of the screen |
| J | jump the camera to the scene |
| T / Y | time of day / weather |
| U | quiet mode (no text, no HUD) |
| H | help |

## Scenes

| Key | Scene | Good for |
|---|---|---|
| 1 | checkpoint | soldiers at a road block, sandbags, bunker, 2 wheeled vehicles |
| 2 | parked_column | 6 vehicles close together, crews standing nearby |
| 3 | dug_in_infantry | prone and kneeling soldiers behind sandbags: **hardest small objects** |
| 4 | convoy | 6 vehicles driving a road loop |
| 5 | foot_patrols | two walking squads |
| 6 | tank_platoon | 4 tanks with dismounts in the open: **easiest, start here** |
| 7 | village_occlusion | soldiers at walls, tanks in tree lines and under a camo net |
| 8 | size_ladder | rows of standing, kneeling and prone soldiers on a grid |
| 9 | hard_negatives | civilian cars and people, tank wrecks: images with **no** labels |
| 0 | mixed | three random scenes together |
| **-** | **building_entry** | squad of 8 walks up to a building; 4 go inside, 4 wait outside |
| **[** | **tank_column** | 5 tanks / tracked APCs driving along a road |
| **]** | **squads_split** | two squads of 8 walk out together; after 10 s each splits: 4 head into the nearest forest, 4 walk on across the fields |
| **Shift+1** | **building_fireteam** | fireteam of 6 into a small house: 3 go in, 3 cover the door |
| **Shift+2** | **building_dismount** | an MRAP / APC has just dropped 8 soldiers next to a building: 4 go in, 4 wait by the vehicle |
| **Shift+3** | **building_pair** | two buildings 10–45 m apart, squad of 8: 2 into each, 4 wait between them |
| **Shift+4** | **building_file** | 8 soldiers walk up in a single file from ~60 m, 4 go in one by one, 4 stay outside |
| **Shift+5** | **tank_column_field** | 4–5 tanks driving in a column across open fields (no road, no village) |
| **Shift+6** | **tank_firing** | 3 crewed tanks in a loose line on open ground, a few soldiers behind; **K** / **Shift+K** make them fire. Every main-gun shot gets an automatic picture with a `tank_fire` label |
| **Shift+7** | **tank_column_long** | 7 tanks / tracked APCs close together (26 m) on a country road |
| **Shift+8** | **patrol_field** | a squad of 6–8 on patrol across open fields, weapons up, in a line, wedge, echelon or staggered column |
| **Shift+9** | **patrol_road** | a squad of 8 walking along a country road in a file or staggered column (turns back before a village) |
| **Shift+0** | **building_lone** | squad of 8 enters a **lone** building (no other building within 120 m, `ZPI_cfg_loneRadius`): 4 go in, 4 wait; generator pictures show only that one building |
| **Shift+-** | **groups_down** | two groups 35–55 m apart, kneeling or lying: prone firing line, kneeling line, all-round defence circle, wedge gone to ground, or a tight cluster; nobody walks |
| **Shift+[** | **tank_escort** | 6 soldiers run beside a tank, then split into two groups of 3 walking on either side of it |
| **Shift+]** | **infantry_spread** | a platoon spread over ~80 m in every pose: a standing group, sentries, a walking fireteam, a kneeling group and a prone group; made for pictures from far away |
| **Shift+\\** | **wheeled_convoy** | 5 MRAPs / trucks / wheeled APCs on a country road (`military_vehicle`) |
| **Shift+;** | **motor_pool** | 4–6 wheeled vehicles parked in rows, herringbone or spread out, a few crew members standing around |
| **Shift+'** | **clutter** | **no targets** (background pictures): logs, rocks, rubble, wrecks, civilian cars, often among bushes, sometimes a smoking wreck or civilians walking past; nothing gets a label (`ZPI_clutterProps` in `config.sqf`) |

**Where scenes go.** Scenes look for green ground with few buildings: open-ground scenes take the greenest flat spot with no buildings around, road scenes a road piece out in the country (at most 1 building within 150 m; columns turn back before a village), building scenes a building with at most 3 buildings within 70 m (a farm, not a village). The ground type comes from the game (`surfaceType`); how green each type counts is set in `ZPI_cfg_surfaceGreen` in `config.sqf`.

**Building scenes (-, Shift+1 … Shift+4, Shift+0).** The squad forms up close together, walks to a waiting point 6 m outside the door and gathers there in a tight block. Then the entry team goes through the door **one by one** (1.2–2.5 s apart), while the rest stops right there, half of them kneeling, watching outwards, so they stay visible next to the building. The squad always comes from the greenest side of the building. The script counts how many soldiers are inside the building at every moment. A soldier counts as inside when he stands within the building's footprint *and* a ray straight up from his head hits that building's roof, with Arma's `insideBuilding` as a backup check. The count shows in the HUD, every change is logged as an `occupancy` event, and each screenshot's JSON includes `building_occupancy` (inside / squad). Soldiers inside are mostly hidden from the drone, so they get no box unless at least 30 % of them is visible, through a door or window for example. This is the ground truth for "how many soldiers did the drone see go in". Every soldier box, in every scene, also has `inside_building: true/false`.

## Dataset generator (Home)

Press **Home** and leave the game running: the mission makes **1000 labelled screenshots on its own** (`ZPI_cfg_tourTarget`), always in clear weather at noon. For every location marker it goes through a shuffled list of scenes (`ZPI_cfg_tourScenes`: all 23 except "mixed"; tank columns, patrols, lone-building entries and kneeling / prone groups are listed twice, so they come twice per round), with a new layout every time. The first scene of a run is always the tank-firing scene, so even a short test has firing pictures.

**Plan: stages with their own targets (`ZPI_cfg_tourPlan`).** One Home press can run several stages one after another. Each stage is `[profile, pictures]`; the profile (`ZPI_tourProfiles` in `config.sqf`) changes some `ZPI_cfg_*` settings for that stage only (which scenes, how many pictures per scene, zoom, camera distance and angle, explosions, ...). The current plan, about 1850 pictures (~4 hours, ~25 GB of screenshots):

| Stage | Pictures | What it makes |
|---|---|---|
| `far` | 700 | soldiers **from far away, ~20–60 px** (zoom 0.025–0.06 m/px, `ZPI_cfg_tourFarGSD`), camera 300–700 m away, 40–70° above the horizon (so 200–650 m high); patrols, groups kneeling / prone, infantry spread out, checkpoint, dug-in, size ladder, lone building |
| `tank_fire` | 200 | the tank-firing scene only (`tank_fire`), zoom 0.009–0.016 m/px |
| `prone` | 200 | groups down with **prone layouts only** (line, wedge, scattered, 2-man pairs), dug-in, infantry spread out (`soldier_prone`) |
| `vehicles` | 200 | wheeled convoy, motor pool, checkpoint, convoy (`military_vehicle`) |
| `explosions` | 200 | a few pictures of a scene, then 6 shells with **2 pictures each** (0.35 s and ~1.3 s after the explosion, same reference picture, so both boxes are measured), zoom 0.025–0.05 m/px |
| `negatives` | 350 | the clutter scene (and civilian cars / wrecks): **no labels at all**, no building in the picture (`ZPI_cfg_maxBuildings` 0 in this stage), half at the soldier zoom, half at the far zoom |

The numbers are pictures, not boxes. Each picture's JSON says `"tour_stage"`, `manifest.csv` has a `tour_stage` column, and `make_yolo_dataset.py` prints how many pictures contain each class and how many came from each stage. To continue a plan after a stop, remove the finished stages from `ZPI_cfg_tourPlan` (or lower their numbers); `ZPI_cfg_tourPlan = [];` runs the normal generator (`ZPI_cfg_tourScenes`, `ZPI_cfg_tourTarget`). Raise `maxScreenShotFolderSizeMB` in your `.Arma3Profile` (with the game closed) so the new screenshots fit next to the old ones.

**Soldier size.** Measured on the October pictures: a soldier's longest box side is about K / zoom pixels, K ≈ 0.95 m kneeling, 1.2–1.7 m standing, 1.6–2.1 m prone. The normal soldier zoom (0.009–0.0115 m/px) therefore gives about 90–170 px, the far zoom (0.025–0.06 m/px) about 20–60 px. Build with `--classes size` if the detector should tell small from large soldiers.

**No repeats between runs.** Every mission start writes its screenshots into a new folder (`Screenshots\zpi\<start time>\`), and the layout seed of every scene continues from where the last generator run on this PC stopped (stored in the Arma profile, starting at 1000; runs before this version used seeds below 1000). Sites and camera positions are random anyway, so no two runs repeat a picture.

**Sites.** Each scene gets its own site within 3 km of the marker (`ZPI_cfg_siteRadius`): the greenest ground with the fewest buildings that suits the scene (open field, country road, or a lone building / farm). The region (train/val/test split) stays the marker number. If the best site near a marker is still not very green, a message says so; place markers in greener parts of the map then.

**Bursts.** The camera stays at one position and takes a picture **every 2 s** (`ZPI_cfg_burstInterval`), 5 pictures for moving scenes and 3 for static ones; then it moves to the next position. So the movement of soldiers and tanks shows between the pictures of one burst. Burst pictures are named `<scene>_b<burst>_<n>_<frame>.png` (e.g. `tank_column_b0042_3_00123456.png` = burst 42, picture 3), and the JSON has `"burst": {"id": 42, "index": 3, "length": 5}`. The camera aims where the targets will be in the middle of the burst, so they move through the picture.

**One soldier size everywhere.** Every generator picture that can contain soldiers uses the same zoom: soldier close-ups, groups, building scenes, patrols, static vehicle scenes and tank firing at 0.009–0.0115 m/px (`ZPI_cfg_tourSoldierGSD`). A soldier is therefore always about 55–90 px, so the detector does not have to learn many sizes of the same class. Only driving columns (no soldiers in view) and explosion pictures (shot away from the soldiers) are filmed wider.

**At most 3 buildings per picture** (`ZPI_cfg_maxBuildings`; lone-building scenes: 1, `ZPI_cfg_loneMaxBuildings`). Before a burst, the generator counts the buildings that would get a box; if there are more, it tries another angle at the same zoom, up to 4 times (`ZPI_cfg_viewTries`), and otherwise skips that view.

| Scenes | What the camera does |
|---|---|
| static layouts (1, 2, 3, 6, 7, 8, 9) | 40 % of the standing soldiers walk around their spot (`ZPI_cfg_tourAnimate`; kneeling and prone soldiers stay down); bursts of 3 on soldiers and groups within 8 m (soldier scale, camera 35–60° down so more of the soldier's height shows) and on vehicles (also the soldier scale when soldiers can be in view), 120–300 m away |
| driving columns (4, [, Shift+5, Shift+7) | the column drives through a fixed view, 220–450 m away, from 30–60° above the horizon (`ZPI_cfg_tourElevColumn`), so also from the side: whole column (0.05–0.09 m/px) and single vehicles (0.025–0.05 m/px); columns drive at 20 km/h (`ZPI_cfg_convoySpeed`) |
| walking soldiers (5, ], Shift+8, Shift+9) | a group walks through a fixed view: group shots and close-ups, all at the soldier scale; two of three bursts from a flatter angle, 30–45° (`ZPI_cfg_tourElevPatrol`), the rest at 35–60° |
| building entries (-, Shift+1 … Shift+4, Shift+0) | **15–25 pictures per scene**, at most 8 soldiers, about half go in: the squad walking up together, gathering at the door, going in one by one, the rest waiting outside. The camera aims at the soldiers outside (plus the door once they are near it), at the same zoom as all soldier pictures; the camera stays on the side where the squad waits, so nobody outside is hidden by the building |
| groups down (Shift+-) | bursts of 3 on a whole group or part of it, half at 30–45°, half at 35–60°; nobody moves |
| tanks in static scenes (6, 2, 7, 8) | after the normal pictures, 2 firing episodes (`ZPI_cfg_tourFiringPerScene`), like the tank-firing scene |
| tanks firing (Shift+6) | **first scene of every run**; the camera goes beside a tank at the soldier scale (`ZPI_cfg_tourFireGSD`, tank and muzzle blast still fit); the tank turns its turret, the camera holds still for a reference picture (at least 2 s after the previous shot, so no old flames are in it), the shot triggers the picture automatically 0.05 s later, two more follow while the smoke drifts |

Each scene except the negatives, the building scenes and tank firing also gets one explosion picture with a measured box. It is **zoomed out** (0.03–0.045 m/px, picture 58–86 m wide, `ZPI_cfg_tourExplosionGSD`) and aimed at the middle of the smoke column, so the smoke is a part of the picture and the measured box fits it (zoomed in, the smoke filled the whole picture). Images per scene are set in `ZPI_cfg_tourShots` (6–25). One round over the 31 scene visits gives about 520 images, so 1018 images take about 2 hours and ~12 GB of disk. Mouse and keys (except Home, U and H) are ignored while it runs. Press **Home** again to stop after the current picture. All settings are in the `ZPI_cfg_tour*`, `ZPI_cfg_burst*` and "clean, green pictures" blocks of `config.sqf`.

**Green.** The camera films from 120–300 m (columns 220–450 m). Far away, Arma shows the low-detail ground texture through a lot of haze, which makes the pictures pale brown; closer in, the grass and its colour come through. After every move the camera waits 3.5 s (`ZPI_cfg_tourSettle`) so the sharp textures have loaded.

**Buildings are labelled in every screenshot** (class `building`): every house, church, chapel, hospital or fuel station whose box is at least 30 % visible. Walls, fences, ruins and small sheds are skipped. Their boxes use the same tight method as vehicles.

## Constant pixel size (R)

The lock is **on from the start**: the zoom follows the laser range automatically, so the scale on screen stays the same however far away you look. A standing soldier stays about `1.8 / GSD` pixels tall. The default is **0.010 m/px**: close-ups where a standing soldier seen from the side is ~180 px tall; from the generator's 35–60° angle he covers roughly 60 × 90 px. **R** turns the lock off and on.

Each JSON records `gsd_center_m_per_px`, `scale_lock` and `target_gsd`, so you can also filter the dataset by scale afterwards.

## Labels and classes

**Vehicle boxes.** The box Arma reports for a whole vehicle model is padded on every side; for a T-100 it is 6.7 m wide and 4.5 m tall instead of about 3.5 × 2.3 m. The mission therefore takes the boxes of several model LODs (visual, fire, view and geometry) and keeps their overlap, which is the tightest box that still contains the vehicle. Each vehicle type's boxes are written to the log once as `ZPI|vbox|`.

**Soldier boxes (tight).** Earlier versions labelled a soldier with *one* 3D box around his body, projected into the picture. Seen from above at an angle, the near-bottom corners of that box land below his feet, so the box was loose at the bottom (10–40 % of its height below the feet) and a bit too wide. Now every body part of the visible model (head, upper arms, forearms, hands, thighs, shins, feet, toes, …) has its own small box; their corners are projected and the label is the union, which hugs the silhouette. A helmet (+8 cm) and a backpack (+22 cm behind the back) are added, rifles are not. If the game does not give animated body parts, the hit-point parts are used instead (bigger, still much tighter). Each soldier in the JSON says `"box_method"`: `body_parts`, `hit_point_parts`, `corrected_3d_box` (older picture, corrected, see Building the dataset) or `3d_box` (older picture, uncorrected). `ZPI_cfg_soldierTightBox = false` goes back to the old box.

When you press **p**, the scene freezes for one frame. Boxes are computed from the game's 3D geometry and the screenshot is taken in that frame, then the scene unfreezes. An object to be detected needs to be ≥ 30 % visible, ≥ 4 px, and mostly inside the image. Civilians and wrecks never get a box.

The class names are chosen when the dataset is built (`--classes`), so you never need to retake screenshots to change them:

| `--classes` | YOLO classes |
|---|---|
| `stance` (default) | soldier_standing, soldier_kneeling, soldier_prone, tank, military_vehicle, explosion, tank_fire, building |
| `simple` | soldier, tank, military_vehicle, explosion, tank_fire, building |
| `size` | soldier_small, soldier_large, tank, military_vehicle, explosion, tank_fire, building |
| `stance_size` | soldier_{standing,kneeling,prone}_{small,large}, tank, military_vehicle, explosion, tank_fire, building |

- **Stance** comes from the game (`stance` command). For screenshots taken with older versions, the script recovers it from the ground-truth log.
- **Size:** small = box area below 32×32 px in the image (the COCO definition), large = everything bigger. The JSON also has the 3-step COCO size: small, medium or large.
- **tank_fire:** the muzzle blast and smoke of a vehicle's main gun (tank cannon or autocannon; machine guns don't count). Every such shot that is in view gets an automatic picture 0.05 s after firing. When the camera could hold still before the shot, a reference picture is taken and the box is **measured** from what changed, like explosions (`"box_method": "image_difference"`); otherwise it is estimated around the muzzle. The tank itself keeps its own `tank` box. Soldiers' rifle fire is not labelled.

**One dataset folder uses one class scheme.** If the script says the folder was built with another scheme, delete the folder (it is rebuilt from the logs in a minute) or use `--out` with a new name.

## Explosions

Explosions are not objects in the game, so the game can only *estimate* their box. The box is now **measured from the image** instead:

1. Just before a shell lands, the camera and zoom are held still: the HUD shows `[CAMERA HELD]` for up to 5 s. The script then takes a reference picture (`ref_….png`). This happens for the barrage (**B**), for tank fire (**K**) and for the generator's explosion close-ups and firing pictures.
2. 0.35 s after the explosion, the labelled screenshot is taken from exactly the same view.
3. `make_yolo_dataset.py` compares the two pictures. Only changes that look like smoke (grey) or fire (very bright) in the new picture count; tan dust doesn't. Smoke rises in a column above the impact point, while dust spreads sideways along the ground. So the box width comes from the dense core of the smoke column above the impact point (plus the fireball), the top from the smoke, and the bottom sits just below the impact point (logged by the game). For tank firing it is the light the flash and the muzzle-brake flames add around the muzzle; the tank's own recoil is ignored. Tuned on 5 real explosions and 3 real tank shots from the game.

Each explosion in the JSON says `"box_method": "image_difference"` (measured) or `"estimated"`. The fallback is used when there was no reference picture or nothing convincing changed, and the script prints how many of each it found. Previews mark measured boxes "(measured)". **I** turns automatic explosion shots and the camera holding off.

## Running the tools

Open a terminal in the mission folder and run them as `python tools\<tool>.py`. They work from any folder (paths are found from where the tools sit), and everything they make goes to `output\`:

```
cd "%USERPROFILE%\Documents\Arma 3\missions\ZPI_scenario.Altis"
python tools\make_yolo_dataset.py          # -> output\dataset
python tools\eval_geolocation.py           # -> output\geoloc_eval
python tools\make_ortho.py                 # -> output\ortho
```

A plain `--out name` goes to `output\name`; an absolute path is used as it is.

## Per-screenshot JSON (`output\dataset\meta\<name>.json`)

There is one file per screenshot, with the same name as the image:

```json
{
 "image": "images/train/20261017_105648_tank_platoon_b0042_3_00184233.png", "width": 1920, "height": 1080,
 "scene": "tank_platoon", "region": 0, "world": "Altis", "frame": 184233,
 "burst": {"id": 42, "index": 3, "length": 3},
 "camera": {"pos_asl": [5021.3, 6133.8, 612.4], "grid": "050061", "alt_asl_m": 612.4, "alt_agl_m": 469.0,
            "heading_deg": 312.4, "pitch_deg": -32.0, "hfov_deg": 20.0, "vfov_deg": 11.4,
            "right_axis": [...], "up_axis": [...], "forward_axis": [...]},
 "laser_rangefinder": {"range": 214.6, "pos_asl": [5123.0, 6245.0, 143.0], "grid": "051062", "hit": ""},
 "gsd_center_m_per_px": 0.0104, "scale_lock": true, "intrinsics": {...}, "terrain_grid": {...}, "pixel_rays": [...],
 "environment": {"time_label": "noon", "daytime_h": 12.0, "weather": "clear"},
 "haze_corrected": true, "green_fraction": 0.71,
 "objects": [
   {"class": "soldier_prone", "type": "soldier", "object_id": 12, "stance": "prone", "size": "small",
    "inside_building": false, "box_px": [1287.3, 597.7, 1302.7, 632.3], "box_norm": {...},
    "world_pos_asl": [5110.1, 6290.2, 150.3], "grid": "051062", "distance_m": 214.5, "visible": 0.95,
    "ground_pos_asl": [5110.12, 6290.21, 149.84], "ground_px": [1295.0, 633.1]},
   {"class": "explosion", "box_method": "image_difference", "world_pos_asl": [...], ...}
 ],
 "building_occupancy": [{"building": "Land_i_House_Big_01_V1_F", "inside": 3, "squad": 8}]
}
```

`world_pos_asl` uses Arma map metres: x = east, y = north, z = height above sea level. This is the same coordinate system as the orthophoto and its world file, so detected objects can be placed directly on the map.

**Geometry for localisation.** Every picture also has:

| Field | What it is |
|---|---|
| `camera.right_axis / up_axis / forward_axis` | unit vectors, 7 decimals (orthonormal); `heading_deg`, `pitch_deg`, `bank_deg` to 4 decimals |
| `intrinsics` | `fx`, `fy`, `cx`, `cy` in pixels (pinhole); ray of pixel (u, v) = forward + right·(u−cx)/fx − up·(v−cy)/fy |
| `projection_check_px` | our pinhole projection vs the game's own `worldToScreen` for up to 4 objects, in pixels; should be ~0 |
| `terrain_grid` | terrain heights (ASL) on a grid under the whole view: `heights_asl[j][i]` at (`x0` + i·`spacing_m`, `y0` + j·`spacing_m`), up to 33 × 33 points, spacing 2 m or more |
| `pixel_rays` | for 9 × 5 image points: `[u, v, x, y, z, kind, id]`, the first surface the camera really sees there (u, v normalized; kind `g` ground, `b` building/roof, `t` tree, `e` scene object, `o` other) |
| `objects[].ground_pos_asl` | where the object stands: a soldier's feet (floor height inside buildings), the terrain under a vehicle's or building's centre, an explosion's impact point; cm precision |
| `objects[].ground_px` | that ground point projected into the image, in pixels (the keypoint of `--pose` labels) |

Why the precision changed: map positions near 13 km are only exact to about 1 mm in the game's 32-bit floats. The camera axes are measured over 1 km, and the FOV is computed exactly from the FOV setting and the screen aspect ratio. Labels use the same camera model, so boxes got slightly more exact too.

## Orthophoto (Z)

1. Spawn a scene and press **Z**. The camera flies a grid of tiles over an 800 × 800 m area around the scene center. It looks straight down from 700 m above ground with north up, and takes one screenshot per tile. All units are frozen during the flight, and their positions are logged once. Afterwards the camera returns to where it was.
2. Run:
   ```
   python tools\make_ortho.py
   ```
3. It writes these files to `output\ortho\`:
   - `ortho_<tag>.png`: the stitched map;
   - `ortho_<tag>.pgw`: the world file, so QGIS or ArcGIS places the map in Arma metres;
   - `ortho_<tag>_objects.png`: the map with soldiers (colour = stance, square = inside a building), tanks and vehicles drawn as rotated outlines, plus a 100 m grid, scale bar, north arrow and legend;
   - `ortho_<tag>_objects.csv` and `ortho_<tag>.json`.

The area size, height and FOV are set by `ZPI_cfg_ortho*` in `config.sqf`. Only the central part of each tile is used, so perspective distortion stays small. Hills and tall buildings still shift slightly (relief displacement), as in any single-camera orthophoto. Mention this in the thesis.

## Starting from clean folders

```
python tools\clean_start.py
```
lists and deletes (after you type YES; `--yes` skips the question) everything in `output\` (datasets, orthophotos, sessions, evaluation), all screenshot sessions (`Screenshots\zpi`) and the old Arma logs and crash dumps. The mission files, tools, README, trained models (`runs\`, `*.pt`) and game settings stay. Close Arma first, or the current log stays (it is in use).

## Building the dataset

```bash
python tools\make_yolo_dataset.py                    # default classes (stance), all logs -> output\dataset
python tools\make_yolo_dataset.py --watch            # keep adding shots while you play
python tools\make_yolo_dataset.py --roboflow --jpg   # + Roboflow zip(s)
python tools\make_yolo_dataset.py --latest           # only the newest session (e.g. the last generator run)
python tools\make_yolo_dataset.py --latest --limit 100 --out dataset_first100 --roboflow --jpg   # small test set for Roboflow
python tools\make_yolo_dataset.py --latest --min-green 0.05   # leave out pictures with almost no green
python tools\make_yolo_dataset.py --out dataset_pose --pose     # YOLO-pose labels: box + ground-point keypoint
```

**Soldier boxes of older pictures.** Pictures taken before the tight soldier boxes have the loose one-3D-box labels. Pictures from the new mission log both boxes for every soldier, so the tool learns, per stance and camera pitch, how to turn the old box into the tight one (`box_calibration.json`, needs 40+ soldiers from new pictures) and corrects the soldiers of the older pictures with it. At the end it prints how far the box bottom of standing soldiers is below the feet, per box method; tight and corrected boxes should be close to 0. The dataset folder is built incrementally, so after taking new pictures **build into a new folder** (`--out dataset_v2`) or delete the old one, otherwise the older pictures keep their old labels. `--no-box-fix` turns the correction off.

**Ground-point keypoint (`--pose`).** Every label line also gets one keypoint, the object's ground point (`ground_px`: a soldier's feet, the terrain under a vehicle's hull centre, an explosion's impact point; buildings and gun fire get none), and `data.yaml` gets `kpt_shape: [1, 3]`. Train it as YOLO-pose (`yolo pose train model=yolo11s-pose.pt data=output\dataset_pose\data.yaml ...`) and the detector predicts the ground point directly: localisation then no longer depends on how the box edges sit. A pose dataset is its own folder (one folder = one format).

**Filters.** Pictures with more than 3 labelled buildings are left out (`--max-buildings`, `-1` keeps all), so this also cleans up older sessions. `--min-green` leaves out pictures with too little green (the share of green pixels, 0–1). `manifest.csv` lists `green_fraction`, `ground_surface` and the burst of every picture, so pick the threshold from real numbers first. A damaged or half-written PNG (e.g. after a PC crash) is skipped and counted as `broken`; the rest of the dataset is built normally.

The output in `output\dataset\` is: `images/`, `labels/`, `data.yaml`, `meta/` (JSON per screenshot), `previews/` (check these!), `manifest.csv` and `scheme.txt`. The split goes by location marker (region) when there are 2 or more regions, otherwise by scene instance. For Roboflow: don't re-split, and don't resize to 640.

## Localisation error

```bash
python tools\eval_geolocation.py                                        # output\dataset, steps 1 + 2
python tools\eval_geolocation.py --pred runs\detect\predict\labels       # + step 3 (YOLO detections)
python tools\eval_geolocation.py --anchor center                        # box centre instead of box bottom
python tools\eval_geolocation.py --dataset run1 --out geoloc_run1        # output\run1 -> output\geoloc_run1
```

Each box gives one pixel (default: bottom-centre). That pixel is turned into a ray with the picture's camera model and intersected with the picture's terrain grid; the hit is compared with the object's true ground point. The errors are split by source:

| Step | Input pixel | Measures |
|---|---|---|
| 1 geometry | the true ground point projected into the image | camera model + DEM; should be ~0 (objects on floors or roofs are left out) |
| 2 labels | bottom-centre of the label box | + the offset between the box bottom and the true ground point |
| 3 detector | bottom-centre of a YOLO detection matched to a label (IoU ≥ 0.5) | + the detector's error |

It reports per class: CEP50 (= median horizontal error), CEP90 (90th percentile), mean, RMSE, max, and the mean error along the viewing direction and across it. It also writes `output\geoloc_eval\per_object.csv` and `summary.json`. Buildings are listed separately and left out of "ALL": for them the box bottom is not where the building stands. For YOLO predictions, run `yolo predict ... save_txt=True save_conf=True` on the dataset images; the .txt files have the same names as the images.

**Keypoint.** With a YOLO-pose model (`--pose` dataset), `--anchor keypoint --pred runs\pose\predict\labels` uses the predicted ground point; step 2 then uses the labelled ground point.

**Bottom vs centre.** On older pictures, the label boxes gave CEP50 ≈ 0.9 m for soldiers and ≈ 3.4 m for tanks with the bottom-centre, and ≈ 0.5 m and ≈ 1.6 m with `--anchor center`. Seen at an angle, a box's bottom edge is the *near* edge of the vehicle, not its centre. `--anchor center` uses the box centre and assumes it is half the object's height above the ground (soldier 0.9 m, vehicle 1.2 m).

Pictures taken before this version have no terrain grid and no ground points. The tool then intersects each object's ray with a flat plane at the object's own true height (so terrain error is left out) and says so. Take new pictures for the real numbers.

## Telemetry and ground truth

Every frame the mission logs the camera pose, FOV, laser range and platform position. Every object is logged at spawn, and true positions are logged every 10 frames. `python tools\rpt_extract.py` writes them as JSONL to `output\sessions\`; `--follow --udp 127.0.0.1:5005` streams them live while you play.

## Screenshot quality

**Why the pictures looked washed out.** Arma's automatic exposure opens up when the camera sees little sky. A drone camera looking down at sunlit ground therefore comes out over-exposed (average brightness ~190 of 255, burnt-out highlights). Flat noon light and distance haze add a grey-white veil on top. Three fixes:

1. **Fixed exposure.** A fixed exposure is used at noon in clear weather; raise it if pictures are too bright, lower it if too dark.
2. **Closer camera, more loading time.** The generator films from 120–300 m (columns 220–450 m) and waits 3.5 s at each new position before the first picture, so the sharp ground textures have loaded (`ZPI_cfg_tourDist`, `ZPI_cfg_tourSettle`).
3. **Haze correction (dataset tool, default on).** `make_yolo_dataset.py` takes the remaining veil off each picture: black point at the haze level, a common white point (colours stay natural), mid-grey brightness at a fixed level and a slight colour lift. Labels are unchanged, and each JSON says `"haze_corrected": true`. `--no-enhance` copies the screenshots unchanged. **Use the same correction on live frames** before detection, so the detector sees what it was trained on:
   ```python
   from zpi_enhance import enhance      # tools\zpi_enhance.py (add tools\ to sys.path)
   frame = enhance(frame)               # PIL image in, PIL image out
   ```
   To try it on single pictures: `python tools\zpi_enhance.py shot.png --compare` (writes a before/after JPEG).

## Status

**Verified in the game** (October 2026 runs, ~1000 generator pictures):
- HUD, laser rangefinder, constant pixel size;
- camera model: `projection_check_px` 0.00 px, hfov and vfov agree with square pixels; step 1 of `eval_geolocation.py` is centimetres;
- dataset generator: green sites, ≤ 3 buildings, bursts, building scenes with 8 soldiers (4 go in), one soldier scale;
- tank firing: automatic pictures with measured `tank_fire` boxes, in the tour and with **K**;
- explosions: measured boxes on real pairs (smoke column above the impact point);
- exposure test, haze correction;
- dataset tool on a session cut off by a PC crash (broken PNGs skipped);
- all tools run from `<mission>\tools` with outputs in `output\` (tested on a copy of real sessions).

**New in this version, check on the first run:**
1. **Tight soldier boxes:** build the dataset and read the "box bottom below the feet" lines at the end: `body_parts` should be near 0 (a few % for boots and toes); look at a few previews. If most soldiers say `hit_point_parts`, the game gave no animated body parts (still fine, a bit looser).
2. **New scenes** (Shift+7 … Shift+0, Shift+-): press each once and look; groups down should stay kneeling / prone, the lone building should have no other house nearby.
3. **Explosion pictures:** the smoke column should be a part of the picture, not fill it.

**Check after changing things:**
1. **HUD** missing after an update: re-open the mission in Eden (`description.ext` is only read then).
2. **Building scenes** say "No enterable building with few others around": move the scene (L or C) near a farm or lone house.
3. **Green sites:** if green-looking ground shows a `GROUND` name that scores 0 in the HUD, add it to `ZPI_cfg_surfaceGreen` in `config.sqf`.
4. **Short generator test** before a long run: set `ZPI_cfg_tourTarget = 50`, build the dataset with `--latest` and look at `output\dataset\previews`.
5. **Z:** check that the tiles have north up and line up in `ortho_<tag>.png`; if tiles look blurry, raise `ZPI_cfg_orthoSettle`.
