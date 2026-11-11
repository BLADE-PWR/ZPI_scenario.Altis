// =====================================================================
//  ZPI scene pack - spawning helpers and the ground-truth registry
// =====================================================================

ZPI_entities     = [];   // [id, object, cls] - everything that gets ground truth
ZPI_sceneStatics = [];   // props (sandbags, nets) - logged once as events, no per-frame GT
ZPI_sceneGroups  = [];
ZPI_nextId       = 0;

// Detection class from the engine config, not from the classname.
ZPI_fnc_clsOf = {
    params ["_class"];
    if (_class isKindOf "Man") exitWith { "soldier" };
    private _sim = toLower getText (configFile >> "CfgVehicles" >> _class >> "simulation");
    if (_sim == "tankx") exitWith { "tracked_vehicle" };
    if (_sim == "carx") exitWith { "wheeled_vehicle" };
    "other"
};

ZPI_fnc_register = {
    params ["_obj", "_cls"];
    ZPI_nextId = ZPI_nextId + 1;
    private _id = ZPI_nextId;
    _obj setVariable ["ZPI_id", _id];
    ZPI_entities pushBack [_id, _obj, _cls];
    private _bb = boundingBoxReal _obj;
    ["spawn", format ['{"id":%1,"cls":"%2","classname":"%3","scene":"%4","seed":%5,"region":%6,"frame":%7,"pos_asl":%8,"dir_deg":%9,"bbox_min":%10,"bbox_max":%11}',
        _id, _cls, typeOf _obj, ZPI_sceneName, ZPI_cfg_seed, ZPI_regionId, diag_frameNo toFixed 0,
        [getPosASL _obj, 2] call ZPI_fnc_v3, (getDir _obj) toFixed 1,
        [_bb select 0, 2] call ZPI_fnc_v3, [_bb select 1, 2] call ZPI_fnc_v3]] call ZPI_fnc_emit;
    _id
};

ZPI_fnc_newGroup = {
    params ["_side"];
    private _g = createGroup [_side, true];
    _g setBehaviour "SAFE";
    _g setCombatMode "BLUE";          // never open fire
    ZPI_sceneGroups pushBack _g;
    _g
};

// [group, posATL, dir, stance "UP"|"MIDDLE"|"DOWN"|"AUTO", static?, class?, cls?]
ZPI_fnc_spawnSoldier = {
    params ["_grp", "_pos", "_dir", ["_stance", "UP"], ["_static", true], ["_class", ""], ["_cls", ""]];
    if (_class == "") then { _class = [ZPI_fac get "soldiers"] call ZPI_fnc_pick };
    private _u = _grp createUnit [_class, [_pos select 0, _pos select 1, 0], [], 0, "CAN_COLLIDE"];
    _u setDir _dir;
    _u setPosATL [_pos select 0, _pos select 1, 0];
    _u allowDamage false;
    _u setUnitPos _stance;
    if (_static) then { _u disableAI "PATH" };
    _u addEventHandler ["Fired", { _this call ZPI_fnc_onFired }];
    if (_cls == "") then { _cls = "soldier" };
    [_u, _cls] call ZPI_fnc_register;
    _u
};

// [class, posATL, dir, crewed?, cls?]
ZPI_fnc_spawnVehicle = {
    params ["_class", "_pos", "_dir", ["_crewed", false], ["_cls", ""]];
    private _v = createVehicle [_class, [_pos select 0, _pos select 1, 0], [], 0, "CAN_COLLIDE"];
    _v setDir _dir;
    _v setPosATL [_pos select 0, _pos select 1, 0.05];
    _v setVectorUp (surfaceNormal _pos);
    _v allowDamage false;
    if (_crewed) then {
        createVehicleCrew _v;
        private _g = group (effectiveCommander _v);
        _g setBehaviour "SAFE";
        _g setCombatMode "BLUE";
        ZPI_sceneGroups pushBackUnique _g;
        { _x allowDamage false } forEach (crew _v);
    } else {
        _v engineOn false;
        _v lock 2;
    };
    _v addEventHandler ["Fired", { _this call ZPI_fnc_onFired }];
    if (_cls == "") then { _cls = [_class] call ZPI_fnc_clsOf };
    [_v, _cls] call ZPI_fnc_register;
    _v
};

// Props: no per-frame ground truth, but every prop is logged once (occluder info).
ZPI_fnc_spawnStatic = {
    params ["_class", "_pos", "_dir"];
    if (_class == "CAMONET") then { _class = ZPI_fac get "camonet" };
    if (!isClass (configFile >> "CfgVehicles" >> _class)) exitWith {
        diag_log format ["ZPI|warn|prop class missing: %1", _class];
        objNull
    };
    private _o = createVehicle [_class, [_pos select 0, _pos select 1, 0], [], 0, "CAN_COLLIDE"];
    _o setDir _dir;
    _o setPosATL [_pos select 0, _pos select 1, 0];
    _o setVectorUp (surfaceNormal _pos);
    _o allowDamage false;
    ZPI_sceneStatics pushBack _o;
    ["prop", format ['{"classname":"%1","pos_asl":%2,"dir_deg":%3}', _class, [getPosASL _o, 2] call ZPI_fnc_v3, _dir toFixed 1]] call ZPI_fnc_event;
    _o
};

// Layout list entries: [kind, right, fwd, dirOffset, extra]
//   "S" soldier (extra = stance), "T" tracked, "W" wheeled, "P" prop (extra = classname or "CAMONET")
ZPI_fnc_layout = {
    params ["_p", "_h", "_list", "_grp", ["_jit", 1]];
    {
        _x params ["_k", "_r", "_f", "_dOff", ["_extra", ""]];
        if (_k == "P") then {
            [_extra, [_p, _h, _r, _f] call ZPI_fnc_rel, _h + _dOff] call ZPI_fnc_spawnStatic;
        } else {
            private _pos = [_p, _h, _r + ([-_jit, _jit] call ZPI_fnc_randRange), _f + ([-_jit, _jit] call ZPI_fnc_randRange)] call ZPI_fnc_rel;
            private _dir = _h + _dOff + ([-15, 15] call ZPI_fnc_randRange);
            switch (_k) do {
                case "S": { [_grp, _pos, _dir, [_extra, "UP"] select (_extra == "")] call ZPI_fnc_spawnSoldier };
                case "T": { [[ZPI_fac get "tracked"] call ZPI_fnc_pick, _pos, _dir] call ZPI_fnc_spawnVehicle };
                case "W": { [[ZPI_fac get "wheeled"] call ZPI_fnc_pick, _pos, _dir] call ZPI_fnc_spawnVehicle };
            };
        };
    } forEach _list;
};

ZPI_fnc_clearScene = {
    {
        private _o = _x select 1;
        if (!isNull _o) then {
            if (!(_o isKindOf "Man")) then { { _o deleteVehicleCrew _x } forEach (crew _o) };
            deleteVehicle _o;
        };
    } forEach ZPI_entities;
    { deleteVehicle _x } forEach ZPI_sceneStatics;
    {
        { deleteVehicle _x } forEach (units _x);
        deleteGroup _x;
    } forEach ZPI_sceneGroups;
    ZPI_entities = [];
    ZPI_sceneStatics = [];
    ZPI_sceneGroups = [];
    ZPI_buildingWatch = [];
    ZPI_entrySites = [];
    ZPI_downGroups = [];
    ZPI_clutterPoints = [];
    ZPI_hudExtra = "";
    ZPI_sceneToken = ZPI_sceneToken + 1;     // ends the helper loops of the old scene
};
ZPI_sceneToken = 0;
ZPI_entrySites = [];             // building scenes: [[building, doorATL, waitingPointATL], ...]

// ---- terrain queries ----------------------------------------------------------
// Open flat-ish ground away from forest and houses; the greenest spots with no
// buildings around win (sites.sqf), one of the best 4 is picked.
ZPI_fnc_findOpen = {
    params ["_c", ["_radius", 500]];
    private _cands = selectBestPlaces [[_c select 0, _c select 1], _radius, "meadow - (2 * houses) - (2 * forest) - trees - (10 * sea) - hills", 30, 16];
    _cands = _cands select { !(surfaceIsWater (_x select 0)) };
    if (_cands isEqualTo []) exitWith { [_c select 0, _c select 1, 0] };
    private _scored = _cands apply {
        private _q = _x select 0;
        private _p = [_q select 0, _q select 1, 0];
        [([_p, 60] call ZPI_fnc_greenScore) - 0.3 * (count ([_p, 120] call ZPI_fnc_buildingsNear)), _p]
    };
    _scored sort false;
    ([_scored select [0, 4]] call ZPI_fnc_pick) select 1
};

// A road piece out in the country (few buildings within 150 m, green verges), near _c.
ZPI_fnc_findRoad = {
    params ["_c", ["_radius", 400]];
    private _roads = ([_c select 0, _c select 1] nearRoads _radius) select {
        private _i = getRoadInfo _x;
        !(_i select 8) && {(_i select 0) in ["ROAD", "MAIN ROAD", "TRACK"]}
    };
    if (_roads isEqualTo []) exitWith { objNull };
    private _sorted = (_roads apply { [_x distance2D _c, _x] });
    _sorted sort true;
    private _good = [];
    {
        private _p = getPosATL (_x select 1);
        _p set [2, 0];
        if ((count ([_p, 150] call ZPI_fnc_buildingsNear)) <= ZPI_cfg_siteMaxBuildings) then {
            _good pushBack [([_p, 60] call ZPI_fnc_greenScore) - (_x select 0) / (_radius * 4), _forEachIndex, _x select 1];
        };
        if (count _good >= 12) exitWith {};
    } forEach (_sorted select [0, 60]);
    if (_good isEqualTo []) exitWith { ([_sorted select [0, 20]] call ZPI_fnc_pick) select 1 };
    _good sort false;
    ([_good select [0, 4]] call ZPI_fnc_pick) select 2
};

// Walk along a road from _road: returns [[posATL, heading], ...] spaced ~_spacing m.
// _reverse walks against the segment's begin->end direction.
ZPI_fnc_roadPath = {
    params ["_road", "_count", "_spacing", ["_reverse", false]];
    private _i = getRoadInfo _road;
    private _p = getPosATL _road;
    _p set [2, 0];
    private _h = (_i select 6) getDir (_i select 7);
    if (_reverse) then { _h = (_h + 180) mod 360 };
    private _out = [[_p, _h]];
    for "_k" from 1 to (_count - 1) do {
        private _q = _p getPos [_spacing, _h];
        private _near = _q nearRoads 25;
        if (_near isEqualTo []) exitWith {};
        private _s = _near apply { [_q distance2D _x, _x] };
        _s sort true;
        private _r  = (_s select 0) select 1;
        private _ri = getRoadInfo _r;
        private _rh = (_ri select 6) getDir (_ri select 7);
        if (abs ([_h, _rh] call ZPI_fnc_angDiff) > 90) then { _rh = (_rh + 180) mod 360 };
        if (!isOnRoad _q) then { _q = getPosATL _r };
        _q set [2, 0];
        if (_q distance2D _p < _spacing * 0.4) exitWith {};   // stuck (dead end / junction)
        _p = _q;
        _h = _rh;
        _out pushBack [_p, _h];
    };
    _out
};

// Straight-line fallback with the same output format.
ZPI_fnc_linePath = {
    params ["_p", "_h", "_count", "_spacing"];
    private _out = [];
    for "_k" from 0 to (_count - 1) do { _out pushBack [[_p, _h, 0, _k * _spacing] call ZPI_fnc_rel, _h] };
    _out
};
