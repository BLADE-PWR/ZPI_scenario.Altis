// =====================================================================
//  ZPI scene pack - configuration
//  Everything a team member is likely to tweak lives in this file.
// =====================================================================

// ---- scene generation ------------------------------------------------
ZPI_cfg_faction      = "CSAT";   // target faction: "CSAT" | "NATO" | "AAF"
ZPI_cfg_seed         = 1;        // base seed; same seed + same location = same layout (N key = seed+1)
ZPI_cfg_startScene   = 6;        // scene launched at mission start (-1 = none)

// ---- camera ------------------------------------
ZPI_cfg_mouseSens     = 15;      // mouse sensitivity (higher = faster)
ZPI_cfg_keyLookRate   = 60;      // deg/s for arrow-key look at 60 deg FOV
ZPI_cfg_MinSpeed      = 10;      // m/s; speed grows with height above ground ...
ZPI_cfg_MaxSpeed      = 200;     // ... up to this
ZPI_cfg_FastMul       = 5;       // Shift multiplier
ZPI_cfg_Smoothing     = 6;       // higher = snappier, lower = smoother movement
ZPI_cfg_zoomStep     = 0.9;      // FOV multiplier per mouse-wheel step
ZPI_cfg_startFov     = 30;       // deg, horizontal FOV at mission start

// ---- dataset capture (P = shot, Shift+P = auto) -------------------------------------
ZPI_cfg_viewDist      = 500;     // m: when a scene is out of view, the camera jumps this far from it ...
ZPI_cfg_viewHeight    = 250;     // ... and this high above it, looking at the scene
ZPI_cfg_minBoxPx      = 4;       // smaller boxes are dropped (px, on screen resolution)
ZPI_cfg_minVisible    = 0.3;     // fraction of the object visible (trees, walls, nets, terrain)
ZPI_cfg_minInFrame    = 0.35;    // fraction of the box inside the image (cut at edges)
ZPI_cfg_maxLabelDist  = 3000;    // m
ZPI_cfg_soldierPad    = 0.12;    // m of padding around the soldier's body points (one-3D-box method, also the visibility test)
ZPI_cfg_soldierTightBox = true;  // label = union of the projected body parts (tight); false = one projected 3D box (old, loose at the bottom)
ZPI_cfg_soldierPartPad  = 0.03;  // m around each body part (uniform, vest)
ZPI_cfg_soldierHelmet   = 0.08;  // m added above the head (helmet)
ZPI_cfg_soldierBackpack = 0.22;  // m added behind the back when he carries a backpack
ZPI_cfg_labelsPerLine = 3;       // boxes per log line (log lines over ~1000 characters may get cut off)
// explosion label size by ammo power: [radius m, height m, duration s]
ZPI_cfg_expLarge  = [9, 14, 3];
ZPI_cfg_expMedium = [5, 8, 2.5];
ZPI_cfg_expSmall  = [2.5, 4, 1.5];
ZPI_cfg_shootersMax    = 4;      // soldiers that fire per volley
ZPI_cfg_vehShootersMax = 2;      // vehicles that fire per volley
ZPI_cfg_vehShots       = 2;      // rounds per vehicle per volley
ZPI_cfg_fireInterval   = 4;      // s between volleys while the firefight (K) is on
ZPI_cfg_fireRange      = [250, 500];  // m: vehicles aim at clear ground this far away, so impacts are in the picture
ZPI_cfg_turretTurnTime = 2.5;    // s to let the turret turn before the first shot
// automatic screenshot when an explosion happens on screen (I toggles)
ZPI_cfg_captureOnExplosion = true;
ZPI_cfg_expCaptureDelay    = 0.35;   // s after detonation: fireball + start of the dust cloud
ZPI_cfg_eventCaptureGap    = 0.8;    // s minimum between automatic event shots
// gun firing (muzzle blast + smoke of a vehicle's main gun): label class "tank_fire"
ZPI_cfg_fireMinHit         = 35;     // ammo "hit" value from which a shot counts (tank shells ~300+, 30 mm ~40, 12.7 mm MG ~30)
ZPI_cfg_fireSize           = [2.5, 4];   // m, blast radius: autocannon / tank cannon
ZPI_cfg_fireDuration       = 1.5;    // s the firing label stays (flash, then smoke)
ZPI_cfg_captureOnFiring    = true;   // automatic picture right after a shot
ZPI_cfg_fireCaptureDelay   = 0.05;   // s after the shot (flash + first smoke)
ZPI_cfg_tourFireGSD        = [0.009, 0.0115];  // generator zoom on a firing tank: the soldier scale (tank + blast still fit)
ZPI_cfg_tourFiringPerScene = 2;      // generator: firing pictures per static scene with tanks (tank platoon, parked column, ...)
// Explosion boxes are measured from the image: just before a shell lands the camera is held
// still and a reference picture is taken; make_yolo_dataset.py boxes what changed.
ZPI_cfg_explosionRefShots  = true;
ZPI_cfg_refTimeout         = 5;      // s the camera is held still waiting for the explosion

// ---- orthophoto (Z): nadir tile flight over the scene, stitched by tools/make_ortho.py --
ZPI_cfg_orthoSize    = 800;      // m, side of the square area around the scene center
ZPI_cfg_orthoAlt     = 700;      // m above ground at each tile
ZPI_cfg_orthoFov     = 30;       // deg horizontal -> ~375 m wide tiles, ~0.2 m/px at 1920 px
ZPI_cfg_orthoOverlap = 0.2;      // fraction of tile overlap
ZPI_cfg_orthoSettle  = 1.2;      // s to wait at each tile (terrain and objects load in)

// ---- dataset generator (Home key) ---------------------------------------------------------
ZPI_cfg_tourTarget    = 1018;    // images to generate in one run (only used when ZPI_cfg_tourPlan is [])
ZPI_cfg_tourTime      = 1;       // index into the time presets: 1 = noon
ZPI_cfg_tourWeather   = 0;       // index into the weather presets: 0 = clear
// scenes per location visit (keys: 1-9, 10 = -, 11 = [, 12 = ], 13-22 = Shift+1 ... Shift+0, 23 = Shift+-).
// A key listed twice is visited twice per round (new site, new layout): more tank columns (11, 17, 19),
// patrols (5, 20, 21), lone-building entries (22) and kneeling / prone groups (23).
ZPI_cfg_tourScenes    = [6, 1, 2, 3, 7, 8, 9, 5, 4, 10, 11, 12, 13, 14, 15, 16, 17, 18,
                         19, 20, 21, 22, 23,  11, 17, 19, 5, 20, 21, 22, 23];
// images per scene visit (scene key -> count); others: 10. Building entries get the most.
ZPI_cfg_tourShots     = createHashMapFromArray [[6, 10], [1, 10], [2, 10], [3, 10], [7, 10], [8, 10], [9, 6],
                                                [5, 15], [4, 15], [10, 20], [11, 20], [12, 15],
                                                [13, 15], [14, 15], [15, 15], [16, 15], [17, 20], [18, 15],
                                                [19, 20], [20, 15], [21, 15], [22, 25], [23, 15]];
ZPI_cfg_tourExplosions = 1;      // explosion close-ups per scene visit
// ONE scale for every generator picture that can contain soldiers (close-ups, groups, building
// scenes, static vehicle scenes, tank firing, explosion close-ups): a soldier always has about
// the same pixel size, so the detector does not have to learn many sizes of the same class.
ZPI_cfg_tourSoldierGSD = [0.009, 0.0115]; // m/px (picture 17-22 m wide; soldier ~90-170 px)
ZPI_cfg_tourExplosionGSD = [0.03, 0.045];  // explosion pictures: zoomed out (58-86 m wide), the smoke column is a
                                           // part of the picture, not all of it, so the measured box fits the smoke
ZPI_cfg_tourGroupRadius = 8;             // m: soldiers within this distance are aimed at together
// driving columns only (no soldiers in view):
ZPI_cfg_tourVehicleGSD = [0.025, 0.05];  // m/px for one vehicle of a driving column
ZPI_cfg_tourColumnGSD  = [0.05, 0.09];   // m/px for a whole driving column
// camera distance (m) and elevation above the horizon (deg). Closer = less haze, more
// ground detail (grass), so the background keeps its real colour.
ZPI_cfg_tourDist       = [120, 300];     // soldier / vehicle close-ups (closer = sharp ground textures, less haze)
ZPI_cfg_tourDistWide   = [220, 450];     // driving columns
ZPI_cfg_tourSettle     = 3.5;            // s at a new camera position before the first picture (textures load in)
ZPI_cfg_tourElev       = [40, 75];
ZPI_cfg_tourElevSoldier = [35, 60];      // soldier shots: lower, so more of the soldier's height shows (straight down = only head and shoulders)
ZPI_cfg_tourElevPatrol = [30, 45];       // walking patrols and kneeling / prone groups: flatter, more from the side
ZPI_cfg_tourElevColumn = [30, 60];       // driving columns: from the side as well as from above

// soldiers from far away (the "far" stage below): ~20-60 px. A soldier's longest box side is
// about K / GSD px with K ~0.95 m kneeling, 1.2-1.7 m standing, 1.6-2.1 m prone.
ZPI_cfg_tourFarGSD     = [0.025, 0.06];   // picture 48-115 m wide
ZPI_cfg_tourFiringExtra = 1;             // pictures after each tank shot (smoke); the shot itself is always taken
ZPI_cfg_tourExplosionFrames = 1;         // pictures per explosion: 1 = at 0.35 s; 2 = also at ~1.3 s (same reference)
ZPI_cfg_downKinds      = ["prone_line", "kneel_line", "circle", "wedge", "cluster"];   // groups-down layouts (Shift+-)

// ---- generator plan: stages run one after another with one Home press -------------------------
// Each stage = [profile, pictures]. A profile changes some ZPI_cfg_* settings for that stage only
// (scenes, zoom, camera distance, ...); everything not listed keeps its normal value.
// Empty plan ([]) = the normal generator: ZPI_cfg_tourScenes, ZPI_cfg_tourTarget pictures.
// To continue a plan after a stop, remove the finished stages / lower the numbers.
ZPI_cfg_tourPlan = [
    ["far",        700],   // soldiers from far away (20-60 px), every pose, higher camera
    ["tank_fire",  200],   // tanks firing (tank_fire)
    ["prone",      200],   // soldiers lying (soldier_prone)
    ["vehicles",   200],   // wheeled vehicles (military_vehicle)
    ["explosions", 200],   // explosions
    ["negatives",  350]    // no targets at all: logs, rocks, rubble, wrecks, civilian cars, bushes
];
ZPI_tourProfiles = createHashMapFromArray [
    ["far", createHashMapFromArray [
        // scenes with soldiers: patrols, groups down, infantry spread out, checkpoint, dug-in, ...
        ["ZPI_cfg_tourScenes", [25, 25, 25, 20, 21, 23, 23, 5, 12, 3, 1, 8, 6, 22]],
        ["ZPI_cfg_tourShots", createHashMapFromArray [[25, 20], [20, 15], [21, 15], [23, 15], [5, 15], [12, 15], [3, 12],
                                                      [1, 12], [8, 10], [6, 10], [22, 15]]],
        ["ZPI_cfg_tourSoldierGSD", ZPI_cfg_tourFarGSD],
        ["ZPI_cfg_tourVehicleGSD", ZPI_cfg_tourFarGSD],
        ["ZPI_cfg_tourDist", [300, 700]],            // higher camera: 200-650 m above the ground
        ["ZPI_cfg_tourElevSoldier", [40, 70]],
        ["ZPI_cfg_tourElevPatrol", [35, 60]],
        ["ZPI_cfg_tourGroupRadius", 25],             // a wider picture holds more soldiers
        ["ZPI_cfg_tourExplosions", 0],
        ["ZPI_cfg_tourFiringPerScene", 0]
    ]],
    ["tank_fire", createHashMapFromArray [
        ["ZPI_cfg_tourScenes", [18]],
        ["ZPI_cfg_tourShots", createHashMapFromArray [[18, 24]]],
        ["ZPI_cfg_tourFireGSD", [0.009, 0.016]],
        ["ZPI_cfg_tourExplosions", 0]
    ]],
    ["prone", createHashMapFromArray [
        ["ZPI_cfg_tourScenes", [23, 23, 3, 25]],
        ["ZPI_cfg_tourShots", createHashMapFromArray [[23, 18], [3, 12], [25, 12]]],
        ["ZPI_cfg_downKinds", ["prone_line", "prone_wedge", "prone_scatter", "prone_pairs"]],
        ["ZPI_cfg_tourExplosions", 0],
        ["ZPI_cfg_tourFiringPerScene", 0]
    ]],
    ["vehicles", createHashMapFromArray [
        ["ZPI_cfg_tourScenes", [26, 27, 26, 27, 1, 4]],
        ["ZPI_cfg_tourShots", createHashMapFromArray [[26, 20], [27, 15], [1, 10], [4, 15]]],
        ["ZPI_cfg_tourExplosions", 0],
        ["ZPI_cfg_tourFiringPerScene", 0]
    ]],
    ["explosions", createHashMapFromArray [
        // a few normal pictures per scene, then shells: 2 pictures per explosion
        ["ZPI_cfg_tourScenes", [6, 2, 23, 20, 25, 27, 3]],
        ["ZPI_cfg_tourShots", createHashMapFromArray [[6, 3], [2, 3], [23, 3], [20, 3], [25, 3], [27, 3], [3, 3]]],
        ["ZPI_cfg_tourExplosions", 6],
        ["ZPI_cfg_tourExplosionFrames", 2],
        ["ZPI_cfg_tourExplosionGSD", [0.025, 0.05]],
        ["ZPI_cfg_tourFiringPerScene", 0]
    ]],
    ["negatives", createHashMapFromArray [
        ["ZPI_cfg_tourScenes", [28, 28, 28, 9]],
        ["ZPI_cfg_tourShots", createHashMapFromArray [[28, 15], [9, 9]]],
        ["ZPI_cfg_maxBuildings", 0],                 // no building in the picture: nothing gets a label
        ["ZPI_cfg_tourExplosions", 0],
        ["ZPI_cfg_tourFiringPerScene", 0]
    ]]
];

// ---- bursts: the camera stays put and shoots every N seconds ------------------------------
// Movement shows up between the pictures of one burst; then the camera moves on.
// Burst pictures are named <scene>_b<burst>_<n>_<frame>.png and the JSON has "burst".
ZPI_cfg_burstInterval  = 2;      // s between pictures of one burst
ZPI_cfg_burstShots     = 5;      // pictures per burst (moving scenes)
ZPI_cfg_burstShotsStatic = 3;    // pictures per burst (static layouts: only a few soldiers walk)
ZPI_cfg_tourAnimate    = 0.4;    // static layouts: share of soldiers that walk around (0 = none)

// ---- clean, green pictures ---------------------------------------------------------------
// At most this many buildings may be in a generator picture; the camera tries other angles
// (ZPI_cfg_viewTries) and skips the view when it cannot get below the limit.
ZPI_cfg_maxBuildings   = 3;
ZPI_cfg_viewTries      = 4;
// Scene sites are searched within this radius of each ZPI_center marker: green ground,
// no village. Region (train/val/test split) stays the marker index.
ZPI_cfg_siteRadius     = 3000;   // m
ZPI_cfg_siteMaxBuildings = 1;    // open-ground and road scenes: buildings within 150 m
ZPI_cfg_minGreen       = 0.45;   // preferred green score of a site (0..1); greener sites always win
// Green score of the ground type (surfaceType). First matching word wins; unknown = 0.
ZPI_cfg_surfaceGreen   = [
    ["grassdry", 0.1], ["drygrass", 0.1], ["dry", 0.05],
    ["grassgreen", 1], ["greengrass", 1], ["green", 1], ["lush", 1], ["moss", 0.9],
    ["marsh", 0.8], ["meadow", 0.8], ["wildfield", 0.6], ["grasstall", 0.7], ["tallgrass", 0.7],
    ["forest", 0.6], ["field", 0.5], ["grass", 0.5], ["thorn", 0.3]
];

// ---- building scenes (-, Shift+1 ... Shift+4) ----------------------------------------------
ZPI_cfg_buildingSquad   = 8;     // soldiers in the squad (- key); every building scene has at most 8
ZPI_cfg_buildingEnter   = 4;     // how many of them go inside
ZPI_cfg_entryStagger    = [1.2, 2.5];   // s between soldiers going through the door
// lone-building entries (Shift+0): no other labelled building within this radius, and pictures
// with more than ZPI_cfg_loneMaxBuildings buildings in view are not taken (1 = only that house)
ZPI_cfg_loneRadius      = 120;   // m
ZPI_cfg_loneMaxBuildings = 1;

// ---- driving columns -------------------------------------------------------------------------
ZPI_cfg_convoySpeed     = 20;    // km/h, slow enough that a burst shows the column moving

// ---- logging -------------------------------------------------------------
ZPI_cfg_telemetryEvery = 1;      // telemetry every N frames (0 = off)
ZPI_cfg_gtEvery        = 10;     // ground-truth positions every N frames (0 = off)
ZPI_cfg_gtMaxPerLine   = 12;     // objects per log line (keeps RPT lines short)

// ---- telemetry extension ------------------------------------------------------
ZPI_cfg_udp       = true;                // use the extension when it is loaded
ZPI_cfg_extension = "zpi_telemetry";     // loads zpi_telemetry_x64.dll from the game folder
ZPI_cfg_udpTarget = "127.0.0.1:5005";    // where the extension sends the records

// ---- factions (base game only; missing classes are dropped at start) --------
ZPI_factions = createHashMapFromArray [
    ["CSAT", createHashMapFromArray [
        ["side", east],
        ["soldiers", ["O_Soldier_F","O_Soldier_AR_F","O_Soldier_GL_F","O_Soldier_LAT_F","O_soldier_M_F","O_Soldier_TL_F","O_medic_F"]],
        ["tracked",  ["O_MBT_02_cannon_F","O_APC_Tracked_02_cannon_F","O_APC_Tracked_02_AA_F","O_MBT_02_arty_F"]],
        ["wheeled",  ["O_MRAP_02_F","O_MRAP_02_hmg_F","O_Truck_02_covered_F","O_Truck_02_transport_F","O_APC_Wheeled_02_rcws_v2_F"]],
        ["camonet",  "CamoNet_OPFOR_big_F"]
    ]],
    ["NATO", createHashMapFromArray [
        ["side", west],
        ["soldiers", ["B_Soldier_F","B_soldier_AR_F","B_Soldier_GL_F","B_soldier_LAT_F","B_soldier_M_F","B_Soldier_TL_F","B_medic_F"]],
        ["tracked",  ["B_MBT_01_cannon_F","B_MBT_01_TUSK_F","B_APC_Tracked_01_rcws_F","B_APC_Tracked_01_AA_F"]],
        ["wheeled",  ["B_MRAP_01_F","B_MRAP_01_hmg_F","B_Truck_01_covered_F","B_Truck_01_transport_F","B_APC_Wheeled_01_cannon_F"]],
        ["camonet",  "CamoNet_BLUFOR_big_F"]
    ]],
    ["AAF", createHashMapFromArray [
        ["side", independent],
        ["soldiers", ["I_soldier_F","I_Soldier_AR_F","I_Soldier_GL_F","I_Soldier_LAT_F","I_Soldier_M_F","I_Soldier_TL_F","I_medic_F"]],
        ["tracked",  ["I_MBT_03_cannon_F","I_APC_tracked_03_cannon_F"]],
        ["wheeled",  ["I_MRAP_03_F","I_MRAP_03_hmg_F","I_Truck_02_covered_F","I_APC_Wheeled_03_cannon_F"]],
        ["camonet",  "CamoNet_INDP_big_F"]
    ]]
];

// Hard negatives: things a detector confuses with targets.
ZPI_negatives = createHashMapFromArray [
    ["people",  ["C_man_1","C_man_polo_1_F","C_man_polo_2_F","C_man_polo_4_F"]],
    ["cars",    ["C_Offroad_01_F","C_Hatchback_01_F","C_SUV_01_F","C_Van_01_transport_F","C_Truck_02_covered_F"]],
    ["wrecks",  ["Land_Wreck_T72_hull_F","Land_Wreck_BMP2_F","Land_Wreck_BRDM2_F","Land_Wreck_Truck_F","Land_Wreck_Car2_F","Land_Wreck_HMMWV_F"]]
];

// Clutter for the background pictures (Shift+', "negatives" stage): [kind, classes]; missing classes are skipped.
ZPI_clutterProps = [
    ["log",    ["Land_WoodenLog_F", "Land_TimberPile_01_F", "Land_WoodPile_F", "Land_WoodPile_large_F", "Land_Timbers_F"]],
    ["rock",   ["Land_BluntStone_01", "Land_BluntStone_02", "Land_SharpStone_01", "Land_SharpStone_02", "Land_W_sharpStone_01",
                "Land_W_sharpStone_02", "Land_BluntRock_apart", "Land_SharpRock_apart"]],
    ["rubble", ["Land_GarbageHeap_01_F", "Land_GarbageHeap_02_F", "Land_GarbageHeap_03_F", "Land_GarbageHeap_04_F", "Land_JunkPile_F",
                "Land_Tyres_F", "Land_Pallets_F", "Land_Bricks_V1_F", "Land_Bricks_V2_F", "Land_Cinderblocks_F", "Land_ConcretePipe_F",
                "Land_GarbageBags_F", "Land_Garbage_square5_F"]],
    ["wreck",  ["Land_Wreck_Car_F", "Land_Wreck_Car2_F", "Land_Wreck_Car3_F", "Land_Wreck_CarDismantled_F", "Land_Wreck_Truck_F",
                "Land_Wreck_Truck_dropside_F", "Land_Wreck_Van_F", "Land_Wreck_Offroad_F", "Land_Wreck_Offroad2_F", "Land_Wreck_Skodovka_F",
                "Land_Wreck_Ural_F", "Land_Wreck_UAZ_F", "Land_Wreck_BMP2_F", "Land_Wreck_BRDM2_F", "Land_Wreck_T72_hull_F"]],
    ["car",    ["C_Offroad_01_F", "C_Hatchback_01_F", "C_SUV_01_F", "C_Van_01_transport_F", "C_Truck_02_covered_F", "C_Quadbike_01_F"]]
];

// Explosion ammo for the barrage key (first existing class wins).
ZPI_cfg_barrageAmmo  = ["Sh_155mm_AMOS","Sh_82mm_AMOS"];
ZPI_cfg_barrageCount = 6;
ZPI_cfg_barrageMinClear = 60;    // m, minimum distance from any scene object
