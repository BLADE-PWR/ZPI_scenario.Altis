// =====================================================================
//  ZPI scene pack
//  Every builder takes [centerATL] and only uses the seeded RNG, so a
//  given seed + location always produces the same static layout.
// =====================================================================

ZPI_fnc_addWaypoints = {
    params ["_g", "_points", ["_cycle", true]];
    {
        private _wp = _g addWaypoint [_x, 0];
        _wp setWaypointType "MOVE";
        _wp setWaypointCompletionRadius 15;
    } forEach _points;
    if (_cycle) then {
        private _wp = _g addWaypoint [_points select 0, 0];
        _wp setWaypointType "CYCLE";
    };
};

ZPI_fnc_pickStance = { [["UP", "UP", "MIDDLE"]] call ZPI_fnc_pick };

// ---------------------------------------------------------------------
// 1 - checkpoint: soldiers at a road block, sandbags, bunker, 2 vehicles
// ---------------------------------------------------------------------
ZPI_fnc_scene_checkpoint = {
    params ["_c"];
    private _road = [_c, 400] call ZPI_fnc_findRoad;
    private _p = _c;
    private _h = [360] call ZPI_fnc_rand;
    if (!isNull _road) then {
        private _i = getRoadInfo _road;
        _p = getPosATL _road;
        _p set [2, 0];
        _h = (_i select 6) getDir (_i select 7);
    };
    private _g = [ZPI_side] call ZPI_fnc_newGroup;
    [_p, _h, [
        ["P",  2.5,   0,  90, "Land_CncBarrier_stripes_F"],
        ["P", -2.5,   8,  90, "Land_CncBarrier_stripes_F"],
        ["P",    8,   3,   0, "Land_BagFence_Round_F"],
        ["P",   -8,  -3, 180, "Land_BagFence_Round_F"],
        ["P",   14, -10, 270, "Land_BagBunker_Small_F"],
        ["P",  -10,  18,   0, "Land_HBarrier_5_F"]
    ], _g, 0] call ZPI_fnc_layout;
    [_p, _h, [
        ["S",    1,   4, 180], ["S", -1.5,   2,   0],
        ["S",    8,   2,   0, "MIDDLE"], ["S", -8, -2, 180, "MIDDLE"],
        ["S",   11,  -6,  90], ["S",   13, -16,  45], ["S", 10, -17, 200],
        ["S",   26,  12,   0, "DOWN"],
        ["W",   12, -22,  30],
        ["W",  -13,  24, 200]
    ], _g, 1] call ZPI_fnc_layout;
};

// ---------------------------------------------------------------------
// 2 - vehicle column parked on the road shoulder, crews standing around
// ---------------------------------------------------------------------
ZPI_fnc_scene_column = {
    params ["_c"];
    private _road = [_c, 500] call ZPI_fnc_findRoad;
    private _path = if (isNull _road) then {
        [_c, [360] call ZPI_fnc_rand, 6, 24] call ZPI_fnc_linePath
    } else {
        [_road, 6, 24] call ZPI_fnc_roadPath
    };
    private _g = [ZPI_side] call ZPI_fnc_newGroup;
    private _kinds = ["T", "T", "W", "T", "T", "W"];
    {
        _x params ["_pt", "_h"];
        private _key = ["wheeled", "tracked"] select ((_kinds select _forEachIndex) == "T");
        [[ZPI_fac get _key] call ZPI_fnc_pick, [_pt, _h, 4.5, 0] call ZPI_fnc_rel, _h + ([-5, 5] call ZPI_fnc_randRange)] call ZPI_fnc_spawnVehicle;
        if (([1] call ZPI_fnc_rand) < 0.6) then {
            for "_j" from 1 to (1 + ([3] call ZPI_fnc_randInt)) do {
                [_g, [_pt, _h, [9, 13] call ZPI_fnc_randRange, [-6, 6] call ZPI_fnc_randRange] call ZPI_fnc_rel,
                    [360] call ZPI_fnc_rand, call ZPI_fnc_pickStance] call ZPI_fnc_spawnSoldier;
            };
        };
    } forEach _path;
};

// ---------------------------------------------------------------------
// 3 - infantry dug in behind a sandbag line (prone / kneeling = hard, small)
// ---------------------------------------------------------------------
ZPI_fnc_scene_dugIn = {
    params ["_c"];
    private _p = [_c, 400] call ZPI_fnc_findOpen;
    private _h = [360] call ZPI_fnc_rand;
    private _g = [ZPI_side] call ZPI_fnc_newGroup;
    private _props = [
        ["P", -19, 0, 0, "Land_BagBunker_Small_F"],
        ["P",  19, 0, 0, "Land_BagBunker_Small_F"],
        ["P",  10, -45, 0, "CAMONET"]
    ];
    private _units = [];
    for "_i" from -5 to 5 do {
        _props pushBack ["P", _i * 3.2, 0, 0, "Land_BagFence_Long_F"];
        if ((_i % 2 == 0) || {([1] call ZPI_fnc_rand) < 0.5}) then {
            _units pushBack ["S", _i * 3.2, -1.3, 0, [["DOWN", "MIDDLE"]] call ZPI_fnc_pick];
        };
    };
    _units append [["S", 0, -15, 0], ["S", 3, -16, 20], ["S", -19, -2.5, 0, "MIDDLE"], ["S", 19, -2.5, 0, "MIDDLE"], ["W", 10, -45, 0]];
    [_p, _h, _props, _g, 0] call ZPI_fnc_layout;
    [_p, _h, _units, _g, 0.3] call ZPI_fnc_layout;
};

// ---------------------------------------------------------------------
// 4 - moving convoy on a road (loops between two points)
// ---------------------------------------------------------------------
// Driving column on a road: [center, kinds ("T" tracked / "W" wheeled), spacing m]
ZPI_fnc_convoyOf = {
    params ["_c", "_kinds", ["_spacing", 30]];
    private _road = [_c, 500] call ZPI_fnc_findRoad;
    if (isNull _road) exitWith { ["No road near this location; a column needs one (L or C)"] call ZPI_fnc_msg };
    private _back = [_road, count _kinds, _spacing, true] call ZPI_fnc_roadPath;
    private _fwd  = [_road, 40, 40, false] call ZPI_fnc_roadPath;
    // turn back before the road reaches a village (pictures with few buildings only)
    private _cut = _fwd findIf { (count ([_x select 0, 60] call ZPI_fnc_buildingsNear)) > 1 };
    if (_cut >= 0) then { _fwd = _fwd select [0, _cut max 6] };
    private _veh = [];
    {
        _x params ["_pt", "_h"];
        private _key = ["wheeled", "tracked"] select ((_kinds select _forEachIndex) == "T");
        _veh pushBack ([[ZPI_fac get _key] call ZPI_fnc_pick, _pt, (_h + 180) mod 360, true] call ZPI_fnc_spawnVehicle);
    } forEach _back;
    private _lead = effectiveCommander (_veh select 0);
    private _g = group _lead;
    { if (_forEachIndex > 0) then { (crew _x) joinSilent _g } } forEach _veh;
    _g selectLeader _lead;
    _g setFormation "COLUMN";
    _g setSpeedMode "LIMITED";
    _g setBehaviour "SAFE";
    _g setCombatMode "BLUE";
    {
        _x forceFollowRoad true;
        _x setConvoySeparation _spacing;
        _x limitSpeed ZPI_cfg_convoySpeed
    } forEach _veh;
    [_g, [(_fwd select (count _fwd - 1)) select 0, (_back select 0) select 0], true] call ZPI_fnc_addWaypoints;
};

ZPI_fnc_scene_convoy = {
    params ["_c"];
    [_c, ["W", "T", "T", "W", "T", "W"], 30] call ZPI_fnc_convoyOf;
};

// ---------------------------------------------------------------------
// [ - column of 5 tanks / tracked APCs driving along a road
// ---------------------------------------------------------------------
ZPI_fnc_scene_tankColumn = {
    params ["_c"];
    [_c, ["T", "T", "T", "T", "T"], 35] call ZPI_fnc_convoyOf;
};

// ---------------------------------------------------------------------
// Shift+5 - column of 4-5 tanks driving across open fields (no road, no village)
// ---------------------------------------------------------------------
ZPI_fnc_scene_fieldColumn = {
    params ["_c"];
    private _p = [_c, 300] call ZPI_fnc_findOpen;
    // a straight 600 m drive over flat, dry, open ground: try 8 headings
    private _h0 = [360] call ZPI_fnc_rand;
    private _route = [];
    for "_k" from 0 to 7 do {
        private _hh = _h0 + _k * 45;
        private _ok = true;
        for "_s" from 1 to 6 do {
            private _q = _p getPos [_s * 100, _hh];
            if (surfaceIsWater _q || {((surfaceNormal _q) select 2) < 0.94}
                || {(count ([_q, 70] call ZPI_fnc_buildingsNear)) > 0}
                || {(count (nearestTerrainObjects [[_q select 0, _q select 1], ["TREE"], 25, false, true])) > 3}) exitWith { _ok = false };
        };
        if (_ok) exitWith { _route = [_hh, _p getPos [600, _hh]] };
    };
    if (_route isEqualTo []) then { _route = [_h0, _p getPos [450, _h0]] };
    _route params ["_hh", "_end"];
    private _veh = [];
    for "_k" from 0 to (3 + ([2] call ZPI_fnc_randInt)) do {
        _veh pushBack ([[ZPI_fac get "tracked"] call ZPI_fnc_pick, [_p, _hh, 0, -32 * _k] call ZPI_fnc_rel, _hh, true] call ZPI_fnc_spawnVehicle);
    };
    private _lead = effectiveCommander (_veh select 0);
    private _g = group _lead;
    { if (_forEachIndex > 0) then { (crew _x) joinSilent _g } } forEach _veh;
    _g selectLeader _lead;
    _g setFormation "COLUMN";
    _g setSpeedMode "LIMITED";
    _g setBehaviour "SAFE";
    _g setCombatMode "BLUE";
    {
        _x setConvoySeparation 30;
        _x limitSpeed ZPI_cfg_convoySpeed;
    } forEach _veh;
    [_g, [[_end select 0, _end select 1, 0], [_p select 0, _p select 1, 0]], true] call ZPI_fnc_addWaypoints;
    ["field_column", format ['{"vehicles":%1,"heading":%2,"start":%3,"end":%4}', count _veh, _hh toFixed 0, [_p, 1] call ZPI_fnc_v3, [_end, 1] call ZPI_fnc_v3]] call ZPI_fnc_event;
};

// ---------------------------------------------------------------------
// ] - two squads walk out together, then each splits:
//     half goes into the nearest forest, half walks on across the fields
// ---------------------------------------------------------------------
ZPI_fnc_scene_squadsSplit = {
    params ["_c"];
    private _p = [_c, 450] call ZPI_fnc_findOpen;
    private _forest = (selectBestPlaces [_p, 700, "forest + trees - houses - (10 * sea)", 25, 6]) apply {
        private _q = _x select 0;
        [_q select 0, _q select 1, 0]
    };
    if (_forest isEqualTo []) then { _forest = [[_p, [360] call ZPI_fnc_rand, 0, 300] call ZPI_fnc_rel] };
    // walk roughly towards the forest
    private _h = _p getDir (_forest select 0);
    private _teams = [];
    {
        private _start = [_p, _h, _x, 0] call ZPI_fnc_rel;
        private _g = [ZPI_side] call ZPI_fnc_newGroup;
        for "_j" from 0 to 7 do {
            [_g, [_start, _h, ((_j mod 2) * 3) - 1.5, -4 * floor (_j / 2)] call ZPI_fnc_rel, _h, "UP", false] call ZPI_fnc_spawnSoldier;
        };
        _g setFormation "STAG COLUMN";
        _g setSpeedMode "LIMITED";
        [_g, [[_start, _h, 0, 60] call ZPI_fnc_rel], false] call ZPI_fnc_addWaypoints;
        _teams pushBack _g;
    } forEach [-18, 18];
    ["squads", format ['{"forest_points":%1,"start":%2}', count _forest, [_p, 1] call ZPI_fnc_v3]] call ZPI_fnc_event;
    [_teams, _forest, _p, _h] spawn {
        params ["_teams", "_forest", "_p", "_h"];
        sleep 10;
        {
            private _i = _forEachIndex;
            private _g = _x;
            private _g2 = [side _g] call ZPI_fnc_newGroup;
            ((units _g) select [4, 4]) joinSilent _g2;
            for "_w" from (count waypoints _g) - 1 to 0 step -1 do { deleteWaypoint [_g, _w] };
            _g setSpeedMode "NORMAL";
            _g setFormation "FILE";
            [_g, [_forest select (_i mod (count _forest))], false] call ZPI_fnc_addWaypoints;
            _g setCurrentWaypoint [_g, (count waypoints _g) - 1];
            _g2 setSpeedMode "LIMITED";
            _g2 setFormation "LINE";
            private _dir = _h + ([-75, 75] select _i);
            [_g2, [_p getPos [150, _dir], _p getPos [320, _dir + ([-25, 25] select _i)]], false] call ZPI_fnc_addWaypoints;
        } forEach _teams;
        ["split", "{}"] call ZPI_fnc_event;
        ["Squads split: half into the forest, half across the fields"] call ZPI_fnc_msg;
    };
};

// ---------------------------------------------------------------------
// 5 - two foot patrols walking square loops
// ---------------------------------------------------------------------
ZPI_fnc_scene_patrol = {
    params ["_c"];
    {
        _x params ["_size", "_side"];
        private _p = [_c, 400] call ZPI_fnc_findOpen;
        private _h = [360] call ZPI_fnc_rand;
        private _g = [ZPI_side] call ZPI_fnc_newGroup;
        for "_j" from 0 to (_size - 1) do {
            [_g, [_p, _h, ([-2, 2] call ZPI_fnc_randRange), -5 * _j] call ZPI_fnc_rel, _h, "AUTO", false] call ZPI_fnc_spawnSoldier;
        };
        _g setFormation "STAG COLUMN";
        _g setSpeedMode "LIMITED";
        [_g, [
            [_p, _h, 0, _side] call ZPI_fnc_rel,
            [_p, _h, _side, _side] call ZPI_fnc_rel,
            [_p, _h, _side, 0] call ZPI_fnc_rel,
            _p
        ], true] call ZPI_fnc_addWaypoints;
    } forEach [[8, 160], [6, 120]];
};

// ---------------------------------------------------------------------
// 6 - tank platoon in a wedge on open ground, dismounts beside the tanks
// ---------------------------------------------------------------------
ZPI_fnc_scene_platoon = {
    params ["_c"];
    private _p = [_c, 500] call ZPI_fnc_findOpen;
    private _h = [360] call ZPI_fnc_rand;
    private _g = [ZPI_side] call ZPI_fnc_newGroup;
    private _list = [];
    {
        _x params ["_r", "_f"];
        _list pushBack ["T", _r, _f, 0];
        for "_j" from 1 to (2 + ([2] call ZPI_fnc_randInt)) do {
            _list pushBack ["S", _r + ([[-7, 7]] call ZPI_fnc_pick) + ([-2, 2] call ZPI_fnc_randRange), _f - ([3, 10] call ZPI_fnc_randRange),
                [360] call ZPI_fnc_rand, call ZPI_fnc_pickStance];
        };
    } forEach [[0, 0], [-55, -45], [55, -45], [110, -90]];
    _list pushBack ["W", 0, -130, 0];
    [_p, _h, _list, _g, 2] call ZPI_fnc_layout;
};

// ---------------------------------------------------------------------
// 7 - village and tree line: partial occlusion, vehicle under camo net
// ---------------------------------------------------------------------
ZPI_fnc_scene_village = {
    params ["_c"];
    private _g = [ZPI_side] call ZPI_fnc_newGroup;
    // a farm / small cluster: at most ZPI_cfg_maxBuildings buildings, not a whole village
    private _pick = [_c, 0, false, 600] call ZPI_fnc_findEntryBuildings;
    private _bld = [];
    if (_pick isNotEqualTo []) then {
        _c = getPosATL (_pick select 0);
        _c set [2, 0];
        _bld = ([_c, 70] call ZPI_fnc_buildingsNear) select {
            private _bb = boundingBoxReal _x;
            (((_bb select 1) select 0) - ((_bb select 0) select 0)) > 5
            && {(((_bb select 1) select 1) - ((_bb select 0) select 1)) > 5}
        };
    };
    if (_bld isEqualTo []) then { ["No small building cluster near this location; only tree line + camo net placed"] call ZPI_fnc_msg };

    for "_i" from 1 to ((count _bld) min 3) do {
        private _b = [_bld] call ZPI_fnc_pick;
        _bld = _bld - [_b];
        private _bb = boundingBoxReal _b;
        private _mn = _bb select 0;
        private _mx = _bb select 1;
        private _cx = ((_mx select 0) + (_mn select 0)) / 2;
        private _cy = ((_mx select 1) + (_mn select 1)) / 2;
        private _hx = ((_mx select 0) - (_mn select 0)) / 2;
        private _hy = ((_mx select 1) - (_mn select 1)) / 2;
        private _wall = [4] call ZPI_fnc_randInt;
        private _local = switch (_wall) do {
            case 0: { [_cx + _hx + 1.5, _cy + ([-0.7, 0.7] call ZPI_fnc_randRange) * _hy, 0] };
            case 1: { [_cx - _hx - 1.5, _cy + ([-0.7, 0.7] call ZPI_fnc_randRange) * _hy, 0] };
            case 2: { [_cx + ([-0.7, 0.7] call ZPI_fnc_randRange) * _hx, _cy + _hy + 1.5, 0] };
            default { [_cx + ([-0.7, 0.7] call ZPI_fnc_randRange) * _hx, _cy - _hy - 1.5, 0] };
        };
        private _w = _b modelToWorld _local;
        private _pos = [_w select 0, _w select 1, 0];
        if (!surfaceIsWater _pos) then {
            private _dir = (getDir _b) + _wall * 90 + ([-30, 30] call ZPI_fnc_randRange);
            [_g, _pos, _dir, call ZPI_fnc_pickStance] call ZPI_fnc_spawnSoldier;
            [_g, [_pos, _dir, 1.5, -0.5] call ZPI_fnc_rel, _dir + 20, call ZPI_fnc_pickStance] call ZPI_fnc_spawnSoldier;
            if (_i <= 2) then {
                private _vw = _b modelToWorld [_cx + _hx + 5, _cy, 0];
                private _key = ["wheeled", "tracked"] select (_i == 1);
                [[ZPI_fac get _key] call ZPI_fnc_pick, [_vw select 0, _vw select 1, 0], getDir _b] call ZPI_fnc_spawnVehicle;
            };
        };
    };

    // tanks pushed into a tree line
    private _trees = nearestTerrainObjects [_c, ["TREE"], 250, false];
    if (_trees isNotEqualTo []) then {
        for "_i" from 1 to 2 do {
            // a tree away from the buildings (at most one building close by)
            private _t = getPosATL ([_trees] call ZPI_fnc_pick);
            for "_try" from 1 to 8 do {
                if ((count ([_t, 60] call ZPI_fnc_buildingsNear)) <= 1) exitWith {};
                _t = getPosATL ([_trees] call ZPI_fnc_pick);
            };
            private _d = [360] call ZPI_fnc_rand;
            private _pos = [_t, _d, 0, 3] call ZPI_fnc_rel;
            [[ZPI_fac get "tracked"] call ZPI_fnc_pick, _pos, _d] call ZPI_fnc_spawnVehicle;
            [_g, [_pos, _d, 5, -4] call ZPI_fnc_rel, _d, "MIDDLE"] call ZPI_fnc_spawnSoldier;
        };
    };

    // tank under a camouflage net
    private _o = [_c, 250] call ZPI_fnc_findOpen;
    private _d = [360] call ZPI_fnc_rand;
    ["CAMONET", _o, _d] call ZPI_fnc_spawnStatic;
    [[ZPI_fac get "tracked"] call ZPI_fnc_pick, _o, _d] call ZPI_fnc_spawnVehicle;
};

// ---------------------------------------------------------------------
// 8 - size ladder: identical targets in rows (detection vs. pixel size)
// ---------------------------------------------------------------------
ZPI_fnc_scene_ladder = {
    params ["_c"];
    private _p = [_c, 500] call ZPI_fnc_findOpen;
    private _h = [360] call ZPI_fnc_rand;
    private _g = [ZPI_side] call ZPI_fnc_newGroup;
    private _list = [];
    {
        _x params ["_f", "_stance"];
        for "_i" from 0 to 7 do { _list pushBack ["S", (_i - 3.5) * 12, _f, [360] call ZPI_fnc_rand, _stance] };
    } forEach [[0, "UP"], [40, "MIDDLE"], [80, "DOWN"]];
    for "_i" from 0 to 2 do {
        _list pushBack ["T", (_i - 1) * 30, 130, 0];
        _list pushBack ["W", (_i - 1) * 30, 180, 0];
    };
    [_p, _h, _list, _g, 0] call ZPI_fnc_layout;
};

// ---------------------------------------------------------------------
// 9 - hard negatives: civilian cars and people, tank/vehicle wrecks
// ---------------------------------------------------------------------
ZPI_fnc_scene_negatives = {
    params ["_c"];
    private _road = [_c, 500] call ZPI_fnc_findRoad;
    private _path = if (isNull _road) then {
        [_c, [360] call ZPI_fnc_rand, 6, 30] call ZPI_fnc_linePath
    } else {
        [_road, 6, 30] call ZPI_fnc_roadPath
    };
    {
        _x params ["_pt", "_h"];
        [[ZPI_negatives get "cars"] call ZPI_fnc_pick, [_pt, _h, [[3.5, -3.5]] call ZPI_fnc_pick, 0] call ZPI_fnc_rel,
            _h + ([[0, 180]] call ZPI_fnc_pick), false, "neg_vehicle"] call ZPI_fnc_spawnVehicle;
    } forEach _path;

    private _gc = [civilian] call ZPI_fnc_newGroup;
    _gc setBehaviour "CARELESS";
    private _start = (_path select 0) select 0;
    for "_j" from 0 to 5 do {
        [_gc, [_start, 0, 8 + _j * 2, 8] call ZPI_fnc_rel, 0, "AUTO", false,
            [ZPI_negatives get "people"] call ZPI_fnc_pick, "neg_person"] call ZPI_fnc_spawnSoldier;
    };
    _gc setSpeedMode "LIMITED";
    [_gc, [[_start, 0, 60, 60] call ZPI_fnc_rel, [_start, 0, -60, 60] call ZPI_fnc_rel, [_start, 0, 0, -40] call ZPI_fnc_rel], true] call ZPI_fnc_addWaypoints;

    private _o = [_c, 400] call ZPI_fnc_findOpen;
    for "_i" from 1 to 4 do {
        private _pos = [_o, 0, [-40, 40] call ZPI_fnc_randRange, [-40, 40] call ZPI_fnc_randRange] call ZPI_fnc_rel;
        private _w = createVehicle [[ZPI_negatives get "wrecks"] call ZPI_fnc_pick, _pos, [], 0, "CAN_COLLIDE"];
        _w setDir ([360] call ZPI_fnc_rand);
        _w setPosATL _pos;
        _w setVectorUp (surfaceNormal _pos);
        [_w, "neg_wreck"] call ZPI_fnc_register;
    };
};

// ---------------------------------------------------------------------
// 0 - mixed: three other scenes around the center, 300 m apart
// ---------------------------------------------------------------------
ZPI_fnc_scene_mixed = {
    params ["_c"];
    private _pool = [1, 2, 3, 5, 6, 7, 9];
    private _rot = [360] call ZPI_fnc_rand;
    for "_k" from 0 to 2 do {
        private _n = [_pool] call ZPI_fnc_pick;
        _pool = _pool - [_n];
        [[_c, _rot + _k * 120, 0, 300] call ZPI_fnc_rel] call ((ZPI_scenes select _n) select 1);
    };
};

// ---------------------------------------------------------------------
// Building entries (-, Shift+1 ... Shift+4)
// The squad forms up close together, walks to a waiting point just outside the
// door, then the entry team goes in one by one while the rest waits outside,
// bunched up and visible. The script counts how many are inside (ground truth).
// ---------------------------------------------------------------------
ZPI_buildingWatch = [];          // [[building, units, lastInsideCount]]

// Door of a building: its exit point (buildingExit) or, when it has none, the middle of
// the wall facing _from. -> [doorATL, outward unit vector]
ZPI_fnc_doorOf = {
    params ["_b", "_from"];
    private _c = getPosATL _b;
    _c set [2, 0];
    private _d = _b buildingExit 0;
    if (_d isEqualTo [0, 0, 0] || {(_d distance2D _c) > 40}) then {
        private _bb = boundingBoxReal _b;
        private _mn = _bb select 0;
        private _mx = _bb select 1;
        private _mc = (_mn vectorAdd _mx) vectorMultiply 0.5;
        private _f = _b worldToModel [_from select 0, _from select 1, 0];
        private _dx = (_f select 0) - (_mc select 0);
        private _dy = (_f select 1) - (_mc select 1);
        private _l = (sqrt (_dx * _dx + _dy * _dy)) max 0.01;
        _dx = _dx / _l;
        _dy = _dy / _l;
        private _t = ((((_mx select 0) - (_mn select 0)) / 2) / ((abs _dx) max 0.001)) min ((((_mx select 1) - (_mn select 1)) / 2) / ((abs _dy) max 0.001));
        private _w = _b modelToWorld [(_mc select 0) + _dx * _t, (_mc select 1) + _dy * _t, 0];
        _d = [_w select 0, _w select 1, 0];
    };
    _d = [_d select 0, _d select 1, 0];
    private _out = _d vectorDiff _c;
    _out set [2, 0];
    if ((vectorMagnitude _out) < 0.5) then { _out = [sin (_c getDir _from), cos (_c getDir _from), 0] };
    [_d, vectorNormalized _out]
};

// [plan [[building, how many go in], ...], squad size, options hashmap]
//   "approach"  m from the waiting point where the squad starts
//   "formation" "tight" (2 abreast, 2 m apart) | "file" (single file, 3 m apart)
//   "vehicle"   "" | "wheeled" | "tracked": parked behind the squad (they just got out)
//   "speed"     "LIMITED" (walk) | "NORMAL"
ZPI_fnc_entryScene = {
    params ["_plan", "_size", "_opt"];
    private _approach = _opt getOrDefault ["approach", 35];
    private _form     = _opt getOrDefault ["formation", "tight"];
    private _vehKey   = _opt getOrDefault ["vehicle", ""];
    private _speed    = _opt getOrDefault ["speed", "NORMAL"];
    private _bs = _plan apply { _x select 0 };
    private _ctr = [0, 0, 0];
    { _ctr = _ctr vectorAdd (getPosATL _x) } forEach _bs;
    _ctr = _ctr vectorMultiply (1 / (count _bs));
    _ctr set [2, 0];

    // side the squad comes from: the greenest of 6 directions with open ground
    private _bestDir = [360] call ZPI_fnc_rand;
    private _bestScore = -1;
    for "_k" from 0 to 5 do {
        private _d = _bestDir + _k * 60;
        private _q = _ctr getPos [_approach max 20, _d];
        private _sc = ([_q, 25] call ZPI_fnc_greenScore) - 0.5 * (count ([_q, 25] call ZPI_fnc_buildingsNear));
        if (!surfaceIsWater _q && {_sc > _bestScore}) then {
            _bestScore = _sc;
            _bestDir = _d;
        };
    };
    private _from = _ctr getPos [60, _bestDir];
    private _doors = _bs apply { [_x, _from] call ZPI_fnc_doorOf };

    // waiting point outside: 6 m out from the door (two buildings: between the two doors)
    private _stage = if (count _bs == 1) then {
        ((_doors select 0) select 0) vectorAdd (((_doors select 0) select 1) vectorMultiply 6)
    } else {
        private _m = (((_doors select 0) select 0) vectorAdd ((_doors select 1) select 0)) vectorMultiply 0.5;
        private _o = vectorNormalized ((((_doors select 0) select 1) vectorAdd ((_doors select 1) select 1)) vectorAdd [0.001, 0, 0]);
        _m vectorAdd (_o vectorMultiply 4)
    };
    _stage set [2, 0];
    private _soldierClass = (ZPI_fac get "soldiers") select 0;
    private _free = _stage findEmptyPosition [0, 12, _soldierClass];
    if (_free isNotEqualTo []) then { _stage = [_free select 0, _free select 1, 0] };
    private _outDir = _ctr getDir _stage;
    private _start = if (_approach > 0) then { _stage getPos [_approach, _outDir + ([-25, 25] call ZPI_fnc_randRange)] } else { _stage };
    _free = _start findEmptyPosition [0, 20, _soldierClass];
    if (_free isNotEqualTo []) then { _start = _free };
    _start = [_start select 0, _start select 1, 0];
    private _face = _start getDir _stage;

    // the squad: entry teams first (they are at the front), then the ones who stay outside
    private _teams = [];
    private _units = [];
    private _idx = 0;
    private _place = {
        params ["_k"];
        if (_form == "file") then {
            [_start, _face, [-0.4, 0.4] call ZPI_fnc_randRange, -3 * _k] call ZPI_fnc_rel
        } else {
            [_start, _face, ((_k mod 2) - 0.5) * 2, -2 * (floor (_k / 2))] call ZPI_fnc_rel
        };
    };
    {
        _x params ["_b", "_nIn"];
        private _g = [ZPI_side] call ZPI_fnc_newGroup;
        private _team = [];
        for "_j" from 1 to _nIn do {
            _team pushBack ([_g, [_idx] call _place, _face, "UP", false] call ZPI_fnc_spawnSoldier);
            _idx = _idx + 1;
        };
        _teams pushBack [_b, _team];
        _units append _team;
    } forEach _plan;
    private _gOut = [ZPI_side] call ZPI_fnc_newGroup;
    private _outside = [];
    while { _idx < _size } do {
        _outside pushBack ([_gOut, [_idx] call _place, _face, "UP", false] call ZPI_fnc_spawnSoldier);
        _idx = _idx + 1;
    };
    _units append _outside;
    {
        _x setBehaviour "AWARE";
        _x setSpeedMode _speed;
        _x setCombatMode "BLUE";
    } forEach ((_teams apply { group ((_x select 1) select 0) }) + [_gOut]);

    if (_vehKey != "") then {
        private _vp = [_start, _face, 1, -10] call ZPI_fnc_rel;
        [[ZPI_fac get _vehKey] call ZPI_fnc_pick, _vp, _face] call ZPI_fnc_spawnVehicle;
    };

    {
        ZPI_buildingWatch pushBack [_x, _units, -1];
        ZPI_entrySites pushBack [_x, (_doors select _forEachIndex) select 0, _stage];
        ["building", format ['{"building":"%1","pos_asl":%2,"positions":%3,"squad":%4,"entering":%5,"door":%6,"waiting_point":%7}',
            typeOf _x, [getPosASL _x, 1] call ZPI_fnc_v3, count (_x buildingPos -1), count _units,
            (_plan select _forEachIndex) select 1, [(_doors select _forEachIndex) select 0, 1] call ZPI_fnc_v3, [_stage, 1] call ZPI_fnc_v3]] call ZPI_fnc_event;
    } forEach _bs;

    // the squad moves: together to the waiting point, then the entry teams go in one by one
    [_teams, _outside, _units, _stage, _face, ZPI_sceneToken] spawn {
        params ["_teams", "_outside", "_units", "_stage", "_face", "_token"];
        sleep 3;
        if (ZPI_sceneToken != _token) exitWith {};
        // phase 1: everybody to a spot in a tight block at the waiting point (4 abreast, 1.8 m apart)
        private _slots = [];
        {
            private _k = _forEachIndex;
            private _s = [_stage, _face, ((_k mod 4) - 1.5) * 1.8, -1.8 * (floor (_k / 4))] call ZPI_fnc_rel;
            _slots pushBack _s;
            _x doMove _s;
        } forEach _units;
        private _t0 = time;
        waitUntil {
            sleep 0.5;
            ZPI_sceneToken != _token || {time > _t0 + 45}
            || {({ (_x distance2D (_slots select (_units find _x))) < 4 } count _units) >= 0.7 * (count _units)}
        };
        if (ZPI_sceneToken != _token) exitWith {};
        // the ones who stay: stop, half kneel, watch outwards
        {
            doStop _x;
            if (_forEachIndex % 2 == 0) then { _x setUnitPos "MIDDLE" };
            _x doWatch (_stage getPos [50, _face + 180 + (random 120) - 60]);
        } forEach _outside;
        sleep 2;
        // phase 2: the entry teams go through the door one after another
        private _queue = [];
        {
            _x params ["_b", "_team"];
            private _pos = (_b buildingPos -1) call BIS_fnc_arrayShuffle;
            { _queue pushBack [_x, _pos select (_forEachIndex mod ((count _pos) max 1))] } forEach _team;
        } forEach _teams;
        // two buildings: alternate between the teams
        if (count _teams > 1) then {
            private _first = (_teams select 0) select 1;
            private _a  = _queue select { (_first find (_x select 0)) >= 0 };
            private _b2 = _queue select { (_first find (_x select 0)) < 0 };
            _queue = [];
            for "_k" from 0 to (((count _a) max (count _b2)) - 1) do {
                if (_k < count _a) then { _queue pushBack (_a select _k) };
                if (_k < count _b2) then { _queue pushBack (_b2 select _k) };
            };
        };
        {
            if (ZPI_sceneToken != _token) exitWith {};
            _x params ["_u", "_p"];
            if (alive _u && {_p isNotEqualTo []}) then { _u doMove _p };
            sleep ((ZPI_cfg_entryStagger select 0) + random ((ZPI_cfg_entryStagger select 1) - (ZPI_cfg_entryStagger select 0)));
        } forEach _queue;
    };
};

// - : squad of 8 walks up, 4 go in, 4 wait outside
ZPI_fnc_scene_building = {
    params ["_c"];
    private _b = [_c, 4, false, 600] call ZPI_fnc_findEntryBuildings;
    if (_b isEqualTo []) exitWith { ["No enterable building with few others around within 600 m: move the scene (L or C)"] call ZPI_fnc_msg };
    [[[_b select 0, ZPI_cfg_buildingEnter]], ZPI_cfg_buildingSquad,
        createHashMapFromArray [["approach", [30, 45] call ZPI_fnc_randRange], ["formation", "tight"], ["speed", "NORMAL"]]] call ZPI_fnc_entryScene;
};

// Shift+1 : fireteam of 6, 3 go in, 3 cover the door
ZPI_fnc_scene_fireteam = {
    params ["_c"];
    private _b = [_c, 3, false, 600] call ZPI_fnc_findEntryBuildings;
    if (_b isEqualTo []) exitWith { ["No enterable building with few others around within 600 m: move the scene (L or C)"] call ZPI_fnc_msg };
    [[[_b select 0, 3]], 6,
        createHashMapFromArray [["approach", [20, 30] call ZPI_fnc_randRange], ["formation", "tight"], ["speed", "NORMAL"]]] call ZPI_fnc_entryScene;
};

// Shift+2 : an APC / MRAP has just dropped a squad of 8 next to the building, 4 go in
ZPI_fnc_scene_dismount = {
    params ["_c"];
    private _b = [_c, 3, false, 600] call ZPI_fnc_findEntryBuildings;
    if (_b isEqualTo []) exitWith { ["No enterable building with few others around within 600 m: move the scene (L or C)"] call ZPI_fnc_msg };
    [[[_b select 0, 4]], 8,
        createHashMapFromArray [["approach", [12, 16] call ZPI_fnc_randRange], ["formation", "tight"], ["speed", "NORMAL"],
            ["vehicle", [["wheeled", "wheeled", "tracked"]] call ZPI_fnc_pick]]] call ZPI_fnc_entryScene;
};

// Shift+3 : two buildings next to each other, squad of 8: 2 into each, 4 wait between them
ZPI_fnc_scene_pair = {
    params ["_c"];
    private _b = [_c, 2, true, 600] call ZPI_fnc_findEntryBuildings;
    if (_b isEqualTo []) exitWith { ["No pair of enterable buildings (10-45 m apart, few others around) within 600 m: move the scene"] call ZPI_fnc_msg };
    [[[_b select 0, 2], [_b select 1, 2]], 8,
        createHashMapFromArray [["approach", [30, 40] call ZPI_fnc_randRange], ["formation", "tight"], ["speed", "NORMAL"]]] call ZPI_fnc_entryScene;
};

// Shift+4 : squad of 8 walks up in a single file from ~60 m, 4 go in one by one, 4 stay
ZPI_fnc_scene_file = {
    params ["_c"];
    private _b = [_c, 4, false, 600] call ZPI_fnc_findEntryBuildings;
    if (_b isEqualTo []) exitWith { ["No enterable building with few others around within 600 m: move the scene (L or C)"] call ZPI_fnc_msg };
    [[[_b select 0, 4]], 8,
        createHashMapFromArray [["approach", [55, 70] call ZPI_fnc_randRange], ["formation", "file"], ["speed", "LIMITED"]]] call ZPI_fnc_entryScene;
};

// Every 15 frames: how many squad members are inside their building.
ZPI_fnc_buildingTick = {
    if (ZPI_buildingWatch isEqualTo [] || {diag_frameNo % 15 != 0}) exitWith {};
    private _lines = [];
    {
        _x params ["_b", "_units", "_last"];
        private _alive = _units select { alive _x };
        private _n = { [_x, _b] call ZPI_fnc_insideOf } count _alive;
        if (_n != _last) then {
            _x set [2, _n];
            ["occupancy", format ['{"building_index":%1,"inside":%2,"squad":%3}', _forEachIndex, _n, count _alive]] call ZPI_fnc_event;
            [format ["Building: %1 of %2 soldiers inside", _n, count _alive]] call ZPI_fnc_msg;
        };
        _lines pushBack format ["BUILDING %1: %2 / %3 soldiers inside", _forEachIndex, _n, count _alive];
    } forEach ZPI_buildingWatch;
    ZPI_hudExtra = _lines joinString "   ";
};

ZPI_fnc_occupancyJson = {
    "[" + ((ZPI_buildingWatch apply {
        format ['{"building":"%1","pos_asl":%2,"inside":%3,"squad":%4}', typeOf (_x select 0),
            [getPosASL (_x select 0), 1] call ZPI_fnc_v3, (_x select 2) max 0, count ((_x select 1) select { alive _x })]
    }) joinString ",") + "]"
};

// ---------------------------------------------------------------------
// Shift+6 - tanks firing: 3 crewed tanks in a loose line on open ground, a few
//           soldiers behind them. K / Shift+K (or the generator) make them fire;
//           every main-gun shot gets an automatic picture with a "tank_fire" label.
// ---------------------------------------------------------------------
ZPI_fnc_scene_tankFiring = {
    params ["_c"];
    private _p = [_c, 300] call ZPI_fnc_findOpen;
    private _h = [360] call ZPI_fnc_rand;
    for "_k" from 0 to 2 do {
        private _pos = [_p, _h, (_k - 1) * 45 + ([-6, 6] call ZPI_fnc_randRange), [-10, 10] call ZPI_fnc_randRange] call ZPI_fnc_rel;
        [[ZPI_fac get "tracked"] call ZPI_fnc_pick, _pos, _h + ([-15, 15] call ZPI_fnc_randRange), true] call ZPI_fnc_spawnVehicle;
    };
    private _g = [ZPI_side] call ZPI_fnc_newGroup;
    for "_k" from 1 to 3 do {
        [_g, [_p, _h, [-50, 50] call ZPI_fnc_randRange, -([15, 30] call ZPI_fnc_randRange)] call ZPI_fnc_rel, _h, "MIDDLE"] call ZPI_fnc_spawnSoldier;
    };
};

// ---------------------------------------------------------------------
// Shift+7 - long armour column: 7 tanks / tracked APCs close together on a country road
// ---------------------------------------------------------------------
ZPI_fnc_scene_longColumn = {
    params ["_c"];
    [_c, ["T", "T", "T", "T", "T", "T", "T"], 26] call ZPI_fnc_convoyOf;
};

// ---------------------------------------------------------------------
// Shift+8 - patrol across the fields: a squad of 8 in a line, wedge or staggered column,
//           walking a long loop over open ground (weapons up)
// ---------------------------------------------------------------------
ZPI_fnc_scene_patrolField = {
    params ["_c"];
    private _p = [_c, 350] call ZPI_fnc_findOpen;
    private _h = [360] call ZPI_fnc_rand;
    private _form = [["LINE", "WEDGE", "STAG COLUMN", "ECH LEFT"]] call ZPI_fnc_pick;
    private _n = 6 + ([3] call ZPI_fnc_randInt);
    private _g = [ZPI_side] call ZPI_fnc_newGroup;
    for "_j" from 0 to (_n - 1) do {
        [_g, [_p, _h, (_j - _n / 2) * 4, -2 * (_j mod 2)] call ZPI_fnc_rel, _h, "UP", false] call ZPI_fnc_spawnSoldier;
    };
    _g setFormation _form;
    _g setBehaviour "AWARE";
    _g setSpeedMode "LIMITED";
    _g setCombatMode "BLUE";
    [_g, [[_p, _h, 0, 350] call ZPI_fnc_rel, [_p, _h, 120, 350] call ZPI_fnc_rel, [_p, _h, 120, 0] call ZPI_fnc_rel, _p], true] call ZPI_fnc_addWaypoints;
    ["patrol", format ['{"kind":"field","formation":"%1","soldiers":%2,"heading":%3}', _form, _n, _h toFixed 0]] call ZPI_fnc_event;
};

// ---------------------------------------------------------------------
// Shift+9 - patrol along a country road: a squad of 8 in a file / staggered column
// ---------------------------------------------------------------------
ZPI_fnc_scene_patrolRoad = {
    params ["_c"];
    private _road = [_c, 500] call ZPI_fnc_findRoad;
    if (isNull _road) exitWith { [_c] call ZPI_fnc_scene_patrolField };
    private _path = [_road, 12, 35, false] call ZPI_fnc_roadPath;
    // turn back before a village
    private _cut = _path findIf { (count ([_x select 0, 60] call ZPI_fnc_buildingsNear)) > 1 };
    if (_cut >= 0) then { _path = _path select [0, _cut max 4] };
    (_path select 0) params ["_p", "_h"];
    private _form = [["FILE", "STAG COLUMN", "STAG COLUMN"]] call ZPI_fnc_pick;
    private _g = [ZPI_side] call ZPI_fnc_newGroup;
    for "_j" from 0 to 7 do {
        [_g, [_p, _h, [-1.5, 1.5] select (_j mod 2), -4 * _j] call ZPI_fnc_rel, _h, "UP", false] call ZPI_fnc_spawnSoldier;
    };
    _g setFormation _form;
    _g setBehaviour "AWARE";
    _g setSpeedMode "LIMITED";
    _g setCombatMode "BLUE";
    [_g, [(_path select (count _path - 1)) select 0, _p], true] call ZPI_fnc_addWaypoints;
    ["patrol", format ['{"kind":"road","formation":"%1","soldiers":8,"road_points":%2}', _form, count _path]] call ZPI_fnc_event;
};

// ---------------------------------------------------------------------
// Shift+0 - squad of 8 enters a LONE building (no other building within ZPI_cfg_loneRadius);
//           4 go in, 4 wait outside. Pictures show at most ZPI_cfg_loneMaxBuildings building.
// ---------------------------------------------------------------------
ZPI_fnc_scene_lone = {
    params ["_c"];
    private _b = [_c, 3, false, 400, 1, ZPI_cfg_loneRadius] call ZPI_fnc_findEntryBuildings;
    if (_b isEqualTo []) exitWith { ["No lone enterable building (nothing else within " + str ZPI_cfg_loneRadius + " m) near here: move the scene (L or C)"] call ZPI_fnc_msg };
    private _file = ([1] call ZPI_fnc_rand) < 0.35;
    [[[_b select 0, ZPI_cfg_buildingEnter]], ZPI_cfg_buildingSquad,
        createHashMapFromArray [["approach", ([[25, 50], [50, 65]] select _file) call ZPI_fnc_randRange],
            ["formation", ["tight", "file"] select _file], ["speed", ["NORMAL", "LIMITED"] select _file]]] call ZPI_fnc_entryScene;
};

// ---------------------------------------------------------------------
// Shift+- - groups down: soldiers kneeling or lying in a group on open ground
//           (a halted patrol in all-round defence, a firing line, a wedge going to ground).
//           Two groups 35-55 m apart, each one of the layouts below; nobody walks.
// ---------------------------------------------------------------------
ZPI_fnc_downGroup = {               // [posATL, heading, layout] -> soldiers
    params ["_p", "_h", "_kind"];
    private _g = [ZPI_side] call ZPI_fnc_newGroup;
    private _out = [];
    private _spawn = {
        params ["_right", "_fwd", "_dir", "_st"];
        private _u = [_g, [_p, _h, _right + ([-0.3, 0.3] call ZPI_fnc_randRange), _fwd + ([-0.3, 0.3] call ZPI_fnc_randRange)] call ZPI_fnc_rel,
            _dir + ([-12, 12] call ZPI_fnc_randRange), _st, true] call ZPI_fnc_spawnSoldier;
        _out pushBack _u;
    };
    switch (_kind) do {
        case "prone_line": {            // firing line, everybody prone
            private _n = 6 + ([3] call ZPI_fnc_randInt);
            for "_j" from 0 to (_n - 1) do { [(_j - (_n - 1) / 2) * 2.2, 0, _h, "DOWN"] call _spawn };
        };
        case "prone_wedge": {           // wedge gone to ground, everybody prone
            private _n = 6 + ([3] call ZPI_fnc_randInt);
            [0, 0, _h, "DOWN"] call _spawn;
            for "_j" from 1 to (_n - 1) do {
                private _row = ceil (_j / 2);
                [([-1, 1] select (_j mod 2)) * _row * 2.6, -_row * 2.6, _h, "DOWN"] call _spawn;
            };
        };
        case "prone_scatter": {         // taking cover where they stood: prone, scattered, facing all ways
            private _n = 5 + ([4] call ZPI_fnc_randInt);
            for "_j" from 1 to _n do {
                private _a = [360] call ZPI_fnc_rand;
                private _d = [1, 9] call ZPI_fnc_randRange;
                [_d * (sin _a), _d * (cos _a), _h + ([-90, 90] call ZPI_fnc_randRange), "DOWN"] call _spawn;
            };
        };
        case "prone_pairs": {           // 2-man teams (sniper / observer, MG pairs) a few metres apart
            private _n = 2 + ([2] call ZPI_fnc_randInt);
            for "_j" from 0 to (_n - 1) do {
                private _x0 = (_j - (_n - 1) / 2) * ([6, 12] call ZPI_fnc_randRange);
                [_x0, 0, _h, "DOWN"] call _spawn;
                [_x0 + 1.3, -0.4, _h + ([-15, 15] call ZPI_fnc_randRange), "DOWN"] call _spawn;
            };
        };
        case "kneel_line": {            // kneeling line, a few prone
            private _n = 5 + ([3] call ZPI_fnc_randInt);
            for "_j" from 0 to (_n - 1) do { [(_j - (_n - 1) / 2) * 2.5, 0, _h, [["MIDDLE", "MIDDLE", "MIDDLE", "DOWN"]] call ZPI_fnc_pick] call _spawn };
        };
        case "circle": {                // halted patrol, all-round defence, kneeling facing out
            private _n = 6 + ([3] call ZPI_fnc_randInt);
            private _r = [3, 4.5] call ZPI_fnc_randRange;
            for "_j" from 0 to (_n - 1) do {
                private _a = _j * 360 / _n;
                [_r * (sin _a), _r * (cos _a), _h + _a, [["MIDDLE", "MIDDLE", "DOWN"]] call ZPI_fnc_pick] call _spawn;
            };
        };
        case "wedge": {                 // wedge gone to ground: front prone, rear kneeling
            private _n = 6 + ([3] call ZPI_fnc_randInt);
            [0, 0, _h, "DOWN"] call _spawn;
            for "_j" from 1 to (_n - 1) do {
                private _row = ceil (_j / 2);
                [([-1, 1] select (_j mod 2)) * _row * 2.4, -_row * 2.4, _h, ["DOWN", "MIDDLE"] select (_row > 1)] call _spawn;
            };
        };
        default {                       // "cluster": tight group kneeling around a leader, a few prone
            private _n = 5 + ([4] call ZPI_fnc_randInt);
            [0, 0, _h, "MIDDLE"] call _spawn;
            for "_j" from 1 to (_n - 1) do {
                private _a = [360] call ZPI_fnc_rand;
                private _d = [1.5, 4] call ZPI_fnc_randRange;
                [_d * (sin _a), _d * (cos _a), _h + ([-60, 60] call ZPI_fnc_randRange), [["MIDDLE", "MIDDLE", "DOWN"]] call ZPI_fnc_pick] call _spawn;
            };
        };
    };
    _out
};

ZPI_fnc_scene_groupsDown = {
    params ["_c"];
    private _p = [_c, 350] call ZPI_fnc_findOpen;
    private _h = [360] call ZPI_fnc_rand;
    private _kinds = ZPI_cfg_downKinds;                 // the "prone" generator stage uses prone layouts only
    private _k1 = [_kinds] call ZPI_fnc_pick;
    private _k2 = [[_kinds - [_k1], _kinds] select (count _kinds < 2)] call ZPI_fnc_pick;
    private _a = [_p, _h, _k1] call ZPI_fnc_downGroup;
    private _p2 = [_p, _h, ([-1, 1] select (([1] call ZPI_fnc_rand) < 0.5)) * ([35, 55] call ZPI_fnc_randRange), [-15, 15] call ZPI_fnc_randRange] call ZPI_fnc_rel;
    private _b = [_p2, _h + ([-40, 40] call ZPI_fnc_randRange), _k2] call ZPI_fnc_downGroup;
    ZPI_downGroups = [_a, _b];
    ["groups_down", format ['{"layouts":["%1","%2"],"soldiers":[%3,%4]}', _k1, _k2, count _a, count _b]] call ZPI_fnc_event;
};
ZPI_downGroups = [];

// ---------------------------------------------------------------------
// Shift+[ - tank escort: 6 soldiers run forward beside a tank, then split into
//           two groups of 3 that walk on either side of the tank as it drives on.
//           The tank keeps level with the soldiers so everything fits in one frame.
// ---------------------------------------------------------------------
ZPI_fnc_scene_tankEscort = {
    params ["_c"];
    private _p = [_c, 350] call ZPI_fnc_findOpen;
    private _h = [360] call ZPI_fnc_rand;
    private _side = [-1, 1] select (([1] call ZPI_fnc_rand) < 0.5);        // tank on the left or right
    private _tank = [[ZPI_fac get "tracked"] call ZPI_fnc_pick, [_p, _h, _side * 9, -2] call ZPI_fnc_rel, _h, true] call ZPI_fnc_spawnVehicle;
    private _tg = group (effectiveCommander _tank);
    _tg setSpeedMode "NORMAL";
    _tank limitSpeed 12;
    [_tg, [[_p, _h, _side * 9, 100] call ZPI_fnc_rel], false] call ZPI_fnc_addWaypoints;
    private _g = [ZPI_side] call ZPI_fnc_newGroup;
    for "_j" from 0 to 5 do {
        [_g, [_p, _h, ((_j mod 3) - 1) * 3 + ([-0.5, 0.5] call ZPI_fnc_randRange), -3 * floor (_j / 3)] call ZPI_fnc_rel, _h, "UP", false] call ZPI_fnc_spawnSoldier;
    };
    _g setFormation "WEDGE";
    _g setBehaviour "AWARE";                // AWARE + FULL = they run
    _g setSpeedMode "FULL";
    _g setCombatMode "BLUE";
    private _rally = [_p, _h, 0, 100] call ZPI_fnc_rel;
    [_g, [_rally], false] call ZPI_fnc_addWaypoints;
    ["tank_escort", format ['{"soldiers":6,"tank_side":%1,"heading":%2,"start":%3}', _side, _h toFixed 0, [_p, 1] call ZPI_fnc_v3]] call ZPI_fnc_event;
    // pacing: every 0.5 s match the tank's speed to the soldiers' and pull it back level with them
    [_tank, units _g, _p, _h, ZPI_sceneToken] spawn {
        params ["_tank", "_men", "_p", "_h", "_tok"];
        private _fwd = {
            params ["_q"];
            ((_q select 0) - (_p select 0)) * (sin _h) + ((_q select 1) - (_p select 1)) * (cos _h);
        };
        private _last = -1;
        while { ZPI_sceneToken == _tok && {alive _tank} } do {
            private _alive = _men select { alive _x };
            if (_alive isEqualTo []) exitWith {};
            private _m = 0;
            { _m = _m + ([getPosATL _x] call _fwd) } forEach _alive;
            _m = _m / (count _alive);
            private _v = if (_last < 0) then { 12 } else { ((_m - _last) / 0.5) * 3.6 };   // soldiers' km/h
            _last = _m;
            private _lead = ([getPosATL _tank] call _fwd) - _m;                        // m ahead of them
            _tank limitSpeed ((_v - 0.8 * _lead) max 2 min 25);
            sleep 0.5;
        };
    };
    [_g, _tank, _tg, _p, _h, _rally, ZPI_sceneToken] spawn {
        params ["_g", "_tank", "_tg", "_p", "_h", "_rally", "_tok"];
        private _t = time + 20;
        waitUntil {
            sleep 0.5;
            ZPI_sceneToken != _tok || {time > _t} || {((leader _g) distance2D _rally) < 15}
        };
        if (ZPI_sceneToken != _tok) exitWith {};        // scene was cleared / replaced
        private _g2 = [side _g] call ZPI_fnc_newGroup;
        ((units _g) select [3, 3]) joinSilent _g2;
        {
            private _grp = _x;
            private _off = [-12, 12] select _forEachIndex;
            for "_w" from (count waypoints _grp) - 1 to 0 step -1 do { deleteWaypoint [_grp, _w] };
            _grp setFormation "WEDGE";
            _grp setBehaviour "AWARE";
            _grp setSpeedMode "NORMAL";
            _grp setCombatMode "BLUE";
            [_grp, [[_p, _h, _off, 130] call ZPI_fnc_rel, [_p, _h, _off, 350] call ZPI_fnc_rel], false] call ZPI_fnc_addWaypoints;
            _grp setCurrentWaypoint [_grp, 1];
        } forEach [_g, _g2];
        for "_w" from (count waypoints _tg) - 1 to 0 step -1 do { deleteWaypoint [_tg, _w] };
        [_tg, [[_p, _h, 0, 130] call ZPI_fnc_rel, [_p, _h, 0, 350] call ZPI_fnc_rel], false] call ZPI_fnc_addWaypoints;
        _tg setCurrentWaypoint [_tg, 1];
        ["split", '{"groups":2,"size":3}'] call ZPI_fnc_event;
        ["Squad split into two groups of 3, tank drives between them"] call ZPI_fnc_msg;
    };
};

// ---------------------------------------------------------------------
// Shift+] - infantry spread out: a platoon of 3-4 groups over ~80 m in every pose:
//           standing (talking, sentries), a fireteam walking, a kneeling line, a prone line.
//           Made for pictures from far away (soldiers 20-60 px), many soldiers per picture.
// ---------------------------------------------------------------------
ZPI_fnc_scene_infantrySpread = {
    params ["_c"];
    private _p = [_c, 350] call ZPI_fnc_findOpen;
    private _h = [360] call ZPI_fnc_rand;
    // standing group, talking, facing each other
    private _gs = [ZPI_side] call ZPI_fnc_newGroup;
    private _sc = [_p, _h, [-30, -15] call ZPI_fnc_randRange, [-10, 10] call ZPI_fnc_randRange] call ZPI_fnc_rel;
    private _ns = 3 + ([3] call ZPI_fnc_randInt);
    for "_j" from 0 to (_ns - 1) do {
        private _a = _j * 360 / _ns;
        [_gs, _sc getPos [1.5, _a], _a + 180, "UP"] call ZPI_fnc_spawnSoldier;
    };
    // kneeling and prone groups
    private _k = [["kneel_line", "circle", "cluster"]] call ZPI_fnc_pick;
    [[_p, _h, [10, 30] call ZPI_fnc_randRange, [10, 25] call ZPI_fnc_randRange] call ZPI_fnc_rel, _h + ([-30, 30] call ZPI_fnc_randRange), _k] call ZPI_fnc_downGroup;
    private _kp = [["prone_line", "prone_wedge", "prone_scatter", "prone_pairs"]] call ZPI_fnc_pick;
    [[_p, _h, [0, 25] call ZPI_fnc_randRange, -([15, 30] call ZPI_fnc_randRange)] call ZPI_fnc_rel, _h + ([-30, 30] call ZPI_fnc_randRange), _kp] call ZPI_fnc_downGroup;
    // sentries
    private _gx = [ZPI_side] call ZPI_fnc_newGroup;
    for "_j" from 1 to (1 + ([3] call ZPI_fnc_randInt)) do {
        [_gx, [_p, _h, [-40, 40] call ZPI_fnc_randRange, [-35, 35] call ZPI_fnc_randRange] call ZPI_fnc_rel, [360] call ZPI_fnc_rand,
            [["UP", "UP", "MIDDLE"]] call ZPI_fnc_pick] call ZPI_fnc_spawnSoldier;
    };
    // a fireteam walking a loop through the position
    private _gw = [ZPI_side] call ZPI_fnc_newGroup;
    private _wp = [_p, _h, -([20, 35] call ZPI_fnc_randRange), -30] call ZPI_fnc_rel;
    for "_j" from 0 to 3 do { [_gw, [_wp, _h, (_j - 1.5) * 2, -2 * _j] call ZPI_fnc_rel, _h, "UP", false] call ZPI_fnc_spawnSoldier };
    _gw setFormation ([["STAG COLUMN", "WEDGE", "FILE"]] call ZPI_fnc_pick);
    _gw setBehaviour "AWARE";
    _gw setSpeedMode "LIMITED";
    _gw setCombatMode "BLUE";
    [_gw, [[_p, _h, 35, -30] call ZPI_fnc_rel, [_p, _h, 35, 35] call ZPI_fnc_rel, [_p, _h, -35, 35] call ZPI_fnc_rel, _wp], true] call ZPI_fnc_addWaypoints;
    ["infantry_spread", format ['{"down":["%1","%2"],"heading":%3}', _k, _kp, _h toFixed 0]] call ZPI_fnc_event;
};

// ---------------------------------------------------------------------
// Shift+\ - wheeled convoy: 5 MRAPs / trucks / wheeled APCs on a country road
// ---------------------------------------------------------------------
ZPI_fnc_scene_wheeledConvoy = {
    params ["_c"];
    [_c, ["W", "W", "W", "W", "W"], 30] call ZPI_fnc_convoyOf;
};

// ---------------------------------------------------------------------
// Shift+; - motor pool: 4-6 wheeled vehicles parked in the open (rows, herringbone or
//           spread under a tree line), a few crew members standing around
// ---------------------------------------------------------------------
ZPI_fnc_scene_motorPool = {
    params ["_c"];
    private _p = [_c, 350] call ZPI_fnc_findOpen;
    private _h = [360] call ZPI_fnc_rand;
    private _n = 4 + ([3] call ZPI_fnc_randInt);
    private _style = [["rows", "herringbone", "spread"]] call ZPI_fnc_pick;
    private _list = [];
    for "_j" from 0 to (_n - 1) do {
        switch (_style) do {
            case "rows":        { _list pushBack ["W", ((_j mod 3) - 1) * 6, -12 * floor (_j / 3), 0] };
            case "herringbone": { _list pushBack ["W", [-4, 4] select (_j mod 2), -9 * _j, [-35, 35] select (_j mod 2)] };
            default             { _list pushBack ["W", [-30, 30] call ZPI_fnc_randRange, [-25, 25] call ZPI_fnc_randRange, [-180, 180] call ZPI_fnc_randRange] };
        };
    };
    for "_j" from 1 to (2 + ([4] call ZPI_fnc_randInt)) do {
        _list pushBack ["S", [-15, 15] call ZPI_fnc_randRange, [-20, 8] call ZPI_fnc_randRange, [-180, 180] call ZPI_fnc_randRange, [["UP", "UP", "MIDDLE"]] call ZPI_fnc_pick];
    };
    private _g = [ZPI_side] call ZPI_fnc_newGroup;
    [_p, _h, _list, _g, 1] call ZPI_fnc_layout;
    ["motor_pool", format ['{"vehicles":%1,"style":"%2"}', _n, _style]] call ZPI_fnc_event;
};

// ---------------------------------------------------------------------
// Shift+' - clutter, NO targets (background pictures): logs, rocks, rubble, wrecks, civilian
//           cars, sometimes a smoking wreck, often among bushes. Things a detector could take
//           for a soldier, a vehicle or an explosion; nothing in these pictures gets a label.
// ---------------------------------------------------------------------
ZPI_clutterPoints = [];
ZPI_fnc_scene_clutter = {
    params ["_c"];
    // half of the visits among bushes / small trees, half on open ground
    private _p = [];
    if (([1] call ZPI_fnc_rand) < 0.5) then {
        private _cands = selectBestPlaces [[_c select 0, _c select 1], 400, "meadow + trees - forest - (3 * houses) - (10 * sea)", 25, 12];
        {
            private _q = [(_x select 0) select 0, (_x select 0) select 1, 0];
            private _nb = count (nearestTerrainObjects [_q, ["BUSH", "TREE", "SMALL TREE"], 35, false, true]);
            if (!surfaceIsWater _q && {_nb >= 5} && {_nb <= 30} && {(count ([_q, 150] call ZPI_fnc_buildingsNear)) == 0}) exitWith { _p = _q };
        } forEach _cands;
    };
    if (_p isEqualTo []) then { _p = [_c, 350] call ZPI_fnc_findOpen };
    ZPI_clutterPoints = [];
    private _kinds = ZPI_clutterProps apply { [_x select 0, [_x select 1] call ZPI_fnc_validClasses] };
    _kinds = _kinds select { (_x select 1) isNotEqualTo [] };
    private _n = 8 + ([9] call ZPI_fnc_randInt);
    for "_j" from 1 to _n do {
        if (_kinds isEqualTo []) exitWith {};
        (([_kinds] call ZPI_fnc_pick)) params ["_kind", "_classes"];
        private _pos = _p getPos [[2, 40] call ZPI_fnc_randRange, [360] call ZPI_fnc_rand];
        _pos = [_pos select 0, _pos select 1, 0];
        if (!surfaceIsWater _pos) then {
            private _cl = [_classes] call ZPI_fnc_pick;
            private _o = if (_kind == "car") then {
                [_cl, _pos, [360] call ZPI_fnc_rand, false, "neg_vehicle"] call ZPI_fnc_spawnVehicle
            } else {
                private _s = [_cl, _pos, [360] call ZPI_fnc_rand] call ZPI_fnc_spawnStatic;
                if (!isNull _s) then { [_s, "neg_" + _kind] call ZPI_fnc_register };
                _s
            };
            if (!isNull _o) then {
                ZPI_clutterPoints pushBack ((getPosASL _o) vectorAdd [0, 0, 0.5]);
                // sometimes a wreck smokes: looks a bit like an explosion's smoke column
                if (_kind == "wreck" && {([1] call ZPI_fnc_rand) < 0.25}) then {
                    private _fx = [["test_EmptyObjectForSmoke", "test_EmptyObjectForFireBig"]] call ZPI_fnc_validClasses;
                    if (_fx isNotEqualTo []) then {
                        private _sm = createVehicle [[_fx] call ZPI_fnc_pick, getPosATL _o, [], 0, "CAN_COLLIDE"];
                        ZPI_sceneStatics pushBack _sm;
                    };
                };
            };
        };
    };
    // a few civilians walking past (sometimes)
    if (([1] call ZPI_fnc_rand) < 0.35) then {
        private _gc = [civilian] call ZPI_fnc_newGroup;
        _gc setBehaviour "CARELESS";
        _gc setSpeedMode "LIMITED";
        for "_j" from 0 to ([3] call ZPI_fnc_randInt) do {
            [_gc, _p getPos [[10, 30] call ZPI_fnc_randRange, [360] call ZPI_fnc_rand], 0, "AUTO", false,
                [ZPI_negatives get "people"] call ZPI_fnc_pick, "neg_person"] call ZPI_fnc_spawnSoldier;
        };
        [_gc, [_p getPos [40, 0], _p getPos [40, 120], _p getPos [40, 240]], true] call ZPI_fnc_addWaypoints;
    };
    // bushes and small trees around are targets for the camera too
    {
        ZPI_clutterPoints pushBack ((getPosASL _x) vectorAdd [0, 0, 0.5]);
    } forEach ((nearestTerrainObjects [_p, ["BUSH", "SMALL TREE"], 40, false, true]) select [0, 10]);
    ["clutter", format ['{"objects":%1,"points":%2,"pos":%3}', count ZPI_entities, count ZPI_clutterPoints, [_p, 1] call ZPI_fnc_v3]] call ZPI_fnc_event;
};

// index = number key (10 = minus, 11 = [, 12 = ], 13-22 = Shift+1 ... Shift+0, 23 = Shift+minus,
// 24 = Shift+[, 25 = Shift+], 26 = Shift+backslash, 27 = Shift+;, 28 = Shift+')
ZPI_scenes = [
    ["mixed",             ZPI_fnc_scene_mixed],
    ["checkpoint",        ZPI_fnc_scene_checkpoint],
    ["parked_column",     ZPI_fnc_scene_column],
    ["dug_in_infantry",   ZPI_fnc_scene_dugIn],
    ["convoy",            ZPI_fnc_scene_convoy],
    ["foot_patrols",      ZPI_fnc_scene_patrol],
    ["tank_platoon",      ZPI_fnc_scene_platoon],
    ["village_occlusion", ZPI_fnc_scene_village],
    ["size_ladder",       ZPI_fnc_scene_ladder],
    ["hard_negatives",    ZPI_fnc_scene_negatives],
    ["building_entry",    ZPI_fnc_scene_building],
    ["tank_column",       ZPI_fnc_scene_tankColumn],
    ["squads_split",      ZPI_fnc_scene_squadsSplit],
    ["building_fireteam", ZPI_fnc_scene_fireteam],
    ["building_dismount", ZPI_fnc_scene_dismount],
    ["building_pair",     ZPI_fnc_scene_pair],
    ["building_file",     ZPI_fnc_scene_file],
    ["tank_column_field", ZPI_fnc_scene_fieldColumn],
    ["tank_firing",       ZPI_fnc_scene_tankFiring],
    ["tank_column_long",  ZPI_fnc_scene_longColumn],
    ["patrol_field",      ZPI_fnc_scene_patrolField],
    ["patrol_road",       ZPI_fnc_scene_patrolRoad],
    ["building_lone",     ZPI_fnc_scene_lone],
    ["groups_down",       ZPI_fnc_scene_groupsDown],
    ["tank_escort",       ZPI_fnc_scene_tankEscort],
    ["infantry_spread",   ZPI_fnc_scene_infantrySpread],
    ["wheeled_convoy",    ZPI_fnc_scene_wheeledConvoy],
    ["motor_pool",        ZPI_fnc_scene_motorPool],
    ["clutter",           ZPI_fnc_scene_clutter]
];

ZPI_fnc_runScene = {
    params ["_n"];
    if (_n < 0 || {_n >= count ZPI_scenes}) exitWith {};
    call ZPI_fnc_clearScene;
    ZPI_rngCounter = 0;
    ZPI_currentScene = _n;
    ZPI_sceneName = (ZPI_scenes select _n) select 0;
    ["scene_start", format ['{"key":%1,"center":%2}', _n, [ZPI_center, 1] call ZPI_fnc_v3]] call ZPI_fnc_event;
    [ZPI_center] call ((ZPI_scenes select _n) select 1);
    ["scene_ready", format ['{"objects":%1,"props":%2}', count ZPI_entities, count ZPI_sceneStatics]] call ZPI_fnc_event;
    [false] call ZPI_fnc_viewScene;      // jump to the scene if it is out of view
    [format ["Scene %1 '%2', seed %3, region %4: %5 objects", _n, ZPI_sceneName, ZPI_cfg_seed, ZPI_regionId, count ZPI_entities]] call ZPI_fnc_msg;
};
