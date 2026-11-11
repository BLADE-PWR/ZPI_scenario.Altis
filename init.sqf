// =====================================================================
//  ZPI scene pack - entry point
//  Drone ISR test scenes for detecting soldiers and armoured vehicles.
//  Local singleplayer only (a dedicated server renders no image).
// =====================================================================
if (!hasInterface) exitWith {};

ZPI_sceneName    = "none";
ZPI_currentScene = -1;
ZPI_regionId     = 0;
ZPI_center       = [0, 0, 0];

{ call compile preprocessFileLineNumbers _x } forEach [
    "zpi\config.sqf",
    "zpi\core.sqf",
    "zpi\spawn.sqf",
    "zpi\sites.sqf",
    "zpi\drone.sqf",
    "zpi\env.sqf",
    "zpi\scenes.sqf",
    "zpi\capture.sqf",
    "zpi\ortho.sqf",
    "zpi\tour.sqf",
    "zpi\keys.sqf"
];

[] spawn {
    waitUntil { !isNull player && {!isNull (findDisplay 46)} && {time > 0} };

    // ---- validate classes for the chosen faction ----
    private _src = ZPI_factions getOrDefault [ZPI_cfg_faction, ZPI_factions get "CSAT"];
    ZPI_fac = createHashMapFromArray [
        ["side",     _src get "side"],
        ["soldiers", [_src get "soldiers"] call ZPI_fnc_validClasses],
        ["tracked",  [_src get "tracked"]  call ZPI_fnc_validClasses],
        ["wheeled",  [_src get "wheeled"]  call ZPI_fnc_validClasses],
        ["camonet",  _src get "camonet"]
    ];
    ZPI_side = ZPI_fac get "side";
    { ZPI_negatives set [_x, [ZPI_negatives get _x] call ZPI_fnc_validClasses] } forEach ["people", "cars", "wrecks"];

    // ---- world ----
    enableEnvironment [false, true];
    enableSaving [false, false];
    enableSentences false;
    enableRadio false;
    setTimeMultiplier 0;

    // ---- park the player out of the picture ----
    player allowDamage false;
    player setCaptive true;
    player hideObject true;
    player enableSimulation false;

    // session tag = UTC start time, used as the screenshot sub-folder
    private _t = systemTimeUTC;
    ZPI_sessionTag = format ["%1%2%3_%4%5%6", _t select 0, [_t select 1, 2] call ZPI_fnc_pad, [_t select 2, 2] call ZPI_fnc_pad,
        [_t select 3, 2] call ZPI_fnc_pad, [_t select 4, 2] call ZPI_fnc_pad, [_t select 5, 2] call ZPI_fnc_pad];

    call ZPI_fnc_initExtension;
    call ZPI_fnc_initLocations;

    ["session_start", format ['{"world":"%1","faction":"%2","locations":%3,"product":"%4","version":"%5","resolution":%6,"session":"%7"}',
        worldName, ZPI_cfg_faction, count ZPI_locations, productVersion select 0, productVersion select 2,
        str ((getResolution) select [0, 2]), ZPI_sessionTag]] call ZPI_fnc_event;

    call ZPI_fnc_applyTime;
    call ZPI_fnc_applyWeather;
    call ZPI_fnc_createCamera;
    call ZPI_fnc_initKeys;

    addMissionEventHandler ["EachFrame", { call ZPI_fnc_onFrame }];

    if (ZPI_cfg_startScene >= 0) then { [ZPI_cfg_startScene] call ZPI_fnc_runScene };
    call ZPI_fnc_showHelp;
};
