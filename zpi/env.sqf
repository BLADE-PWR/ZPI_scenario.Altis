// =====================================================================
//  ZPI scene pack - environment: locations, time of day, weather, barrage
// =====================================================================

// ---- locations (train/val/test split by region) ---------------------------
// Place empty markers named ZPI_center_0, ZPI_center_1, ... in Eden.
// Without markers the player's start position is the only location.
ZPI_fnc_initLocations = {
    private _m = allMapMarkers select { (_x find "ZPI_center") == 0 };
    _m sort true;
    ZPI_locations = _m apply {
        private _p = markerPos _x;
        [_p select 0, _p select 1, 0]
    };
    if (ZPI_locations isEqualTo []) then {
        private _p = getPosATL player;
        ZPI_locations = [[_p select 0, _p select 1, 0]];
    };
    ZPI_regionId = 0;
    ZPI_center = ZPI_locations select 0;
};

ZPI_fnc_setCenter = {
    params ["_pos", "_region", ["_moveCam", true]];
    ZPI_center = [_pos select 0, _pos select 1, 0];
    ZPI_regionId = _region;
    ["center", format ['{"center":%1}', [ZPI_center, 1] call ZPI_fnc_v3]] call ZPI_fnc_event;
    [format ["Location %1 (grid %2)", _region, mapGridPosition ZPI_center]] call ZPI_fnc_msg;
    if (ZPI_currentScene >= 0) then {
        [ZPI_currentScene, _moveCam] call ZPI_fnc_runScene;
    } else { if (_moveCam) then { [true] call ZPI_fnc_viewScene } };
};

// Set the next location from the ZPI_locations list
ZPI_fnc_nextLocation = {
    private _i = (ZPI_regionId max -1) + 1;
    if (_i >= count ZPI_locations) then { _i = 0 };
    [ZPI_locations select _i, _i] call ZPI_fnc_setCenter;
};

// ---- time of day -------------------------------------------------------------
ZPI_timePresets = [[6, 0, "dawn", 60], [12, 0, "noon", 180], [17, 30, "afternoon", 180], [23, 0, "night", -1]];
ZPI_timeIndex = 1;
ZPI_fnc_applyTime = {
    (ZPI_timePresets select ZPI_timeIndex) params ["_hh", "_mm", "_label", "_aperture"];
    setDate [2035, 6, 15, _hh, _mm];
    ["time", format ['{"label":"%1","hour":%2,"minute":%3}', _label, _hh, _mm]] call ZPI_fnc_event;
    setAperture _aperture;
    [format ["Time: %1 (%2:%3%4)", _label, _hh, ["", "0"] select (_mm < 10), _mm]] call ZPI_fnc_msg;
};

ZPI_fnc_nextTime = {
    ZPI_timeIndex = (ZPI_timeIndex + 1) mod (count ZPI_timePresets);
    call ZPI_fnc_applyTime;
};

// ---- weather -------------------------------------------------------------------
// [label, overcast, fog, rain]
ZPI_weatherPresets = [["clear", 0, 0, 0], ["overcast", 0.8, 0, 0], ["fog", 0.4, 0.35, 0], ["rain", 1, 0.08, 1]];
ZPI_weatherIndex = 0;
ZPI_fnc_applyWeather = {
    (ZPI_weatherPresets select ZPI_weatherIndex) params ["_label", "_oc", "_fog", "_rain"];
    0 setOvercast _oc;
    0 setFog _fog;
    0 setRain _rain;
    0 setLightnings 0;
    forceWeatherChange;
    999999 setOvercast _oc;     // hold it there
    999999 setFog _fog;
    999999 setRain _rain;
    ["weather", format ['{"label":"%1","overcast":%2,"fog":%3,"rain":%4}', _label, _oc, _fog, _rain]] call ZPI_fnc_event;
    [format ["Weather: %1", _label]] call ZPI_fnc_msg;
};

ZPI_fnc_nextWeather = {
    ZPI_weatherIndex = (ZPI_weatherIndex + 1) mod (count ZPI_weatherPresets);
    call ZPI_fnc_applyWeather;
};

// ---- artillery barrage ---------------------------------------------------------
// Every shell lands on a random spot of the picture as it is just before that shell,
// at least ZPI_cfg_barrageMinClear m from every scene object.
// Each detonation is logged with its exact position (projectile "Explode" handler).
ZPI_barrageRunning = false;
ZPI_expId = 100000;            // explosion ids live in their own range

// Random open ground in the camera picture (middle 80 %, so the fireball fits), ASL; [] when none.
ZPI_fnc_impactInView = {
    private _out = [];
    for "_t" from 1 to 40 do {
        private _s = screenToWorld [safeZoneX + safeZoneW * ([0.1, 0.9] call ZPI_fnc_randRange), safeZoneY + safeZoneH * ([0.1, 0.9] call ZPI_fnc_randRange)];
        private _p = [_s select 0, _s select 1, getTerrainHeightASL _s];
        if (!surfaceIsWater _p && {[_p] call ZPI_fnc_onScreen}
            && {(ZPI_entities findIf { !isNull (_x select 1) && {((_x select 1) distance2D _p) < ZPI_cfg_barrageMinClear} }) == -1}) exitWith { _out = _p };
    };
    _out
};

ZPI_fnc_barrage = {
    if (ZPI_barrageRunning) exitWith { ["Barrage already running"] call ZPI_fnc_msg };
    ZPI_barrageRunning = true;
    private _ammo = ([ZPI_cfg_barrageAmmo, "CfgAmmo"] call ZPI_fnc_validClasses) param [0, "Sh_82mm_AMOS"];
    ["barrage", format ['{"ammo":"%1","count":%2}', _ammo, ZPI_cfg_barrageCount]] call ZPI_fnc_event;
    ["Barrage incoming"] call ZPI_fnc_msg;
    [_ammo] spawn {
        params ["_ammo"];
        for "_i" from 1 to ZPI_cfg_barrageCount do {
            // wait for the previous explosion picture, then pick the spot in the current view
            private _t0 = time;
            waitUntil { (!ZPI_frozen && {!ZPI_camLock} && {ZPI_pendingCapture < 0}) || {time > _t0 + 6} };
            private _p = call ZPI_fnc_impactInView;
            if (_p isEqualTo []) then {
                ["Barrage: no open ground in view"] call ZPI_fnc_msg;
                sleep 0.5;
                continue;
            };
            _p params ["_x0", "_y0", "_z"];
            // hold the camera and take the reference picture
            if ([_p] call ZPI_fnc_takeRef) then { sleep 0.15 };
            ZPI_expId = ZPI_expId + 1;
            private _sh = createVehicle [_ammo, [_x0, _y0, 60], [], 0, "CAN_COLLIDE"];
            _sh setVariable ["ZPI_id", ZPI_expId];
            _sh setPosASL [_x0, _y0, _z + 60];
            _sh setVectorDirAndUp [[0, 0, -1], [0, 1, 0]];
            _sh setVariable ["ZPI_expSize", [_ammo] call ZPI_fnc_explosionSize];
            _sh addEventHandler ["Explode", {
                params ["_projectile", "_pos"];
                [_pos, _projectile getVariable ["ZPI_expSize", ZPI_cfg_expMedium], _projectile getVariable ["ZPI_id", -1]] call ZPI_fnc_addExplosion;
            }];
            _sh setVelocity [0, 0, -150];
            sleep (0.8 + random 0.6);
        };
        ZPI_barrageRunning = false;
    };
};
