// =====================================================================
//  ZPI scene pack - where a scene goes: green ground, few buildings
//
//  Green score: the ground type under a point (surfaceType, e.g.
//  "#GdtGrassGreen") scored with ZPI_cfg_surfaceGreen, averaged over
//  13 points around the site. Building count: the same buildings that
//  would get a "building" box in a picture.
// =====================================================================

// [posATL] -> 0..1, how green the ground type is at that point
ZPI_fnc_surfaceGreen = {
    params ["_p"];
    if (surfaceIsWater _p) exitWith { 0 };
    private _s = toLower (surfaceType _p);
    private _v = 0;
    {
        if ((_s find (_x select 0)) >= 0) exitWith { _v = _x select 1 };
    } forEach ZPI_cfg_surfaceGreen;
    _v
};

// [center, radius] -> mean green score of the center + two rings of 6 points
ZPI_fnc_greenScore = {
    params ["_c", ["_r", 120]];
    private _sum = [_c] call ZPI_fnc_surfaceGreen;
    private _n = 1;
    {
        private _rr = _x select 0;
        for "_a" from (_x select 1) to 359 step 60 do {
            _sum = _sum + ([[(_c select 0) + _rr * (sin _a), (_c select 1) + _rr * (cos _a), 0]] call ZPI_fnc_surfaceGreen);
            _n = _n + 1;
        };
    } forEach [[_r * 0.5, 0], [_r, 30]];
    _sum / _n
};

// Would this object get a "building" box? (same test as the labels)
ZPI_fnc_isLabelBuilding = {
    params ["_b"];
    if (isNull _b || {damage _b >= 0.9} || {isObjectHidden _b}) exitWith { false };
    private _cn = toLower ((typeOf _b) + " " + ((getModelInfo _b) select 0));
    if (({ (_cn find _x) >= 0 } count ZPI_bldSkip) > 0) exitWith { false };
    ([_b] call ZPI_fnc_modelBox) params ["_mn", "_mx"];
    private _e = _mx vectorDiff _mn;
    (_e select 0) >= 3 && {(_e select 1) >= 3} && {(_e select 2) >= 2.5}
};

// [posATL, radius] -> buildings around that would be labelled
ZPI_fnc_buildingsNear = {
    params ["_p", "_r"];
    (nearestTerrainObjects [[_p select 0, _p select 1], ZPI_bldTypes, _r, false, true]) select { [_x] call ZPI_fnc_isLabelBuilding }
};

// ---- buildings a squad can enter ----------------------------------------------------------
// [center, min. positions inside, pair?, radius, max. buildings around, "around" radius]
//   -> [building] or [b1, b2] or [] (nothing found)
// Only buildings with at most _maxNear labelled buildings within _nearR m (itself included),
// greenest surroundings first, nearer to the center preferred. Lone building: _maxNear 1.
ZPI_fnc_findEntryBuildings = {
    params ["_c", ["_need", 2], ["_pair", false], ["_radius", 600], ["_maxNear", ZPI_cfg_maxBuildings], ["_nearR", 70]];
    private _all = (nearestObjects [[_c select 0, _c select 1], ["House", "Building"], _radius]) select {
        damage _x < 0.5 && {(count (_x buildingPos -1)) >= _need} && {[_x] call ZPI_fnc_isLabelBuilding}
    };
    if (count _all > 200) then { _all = (_all select [0, 60]) + (((_all select [60, 100000]) call BIS_fnc_arrayShuffle) select [0, 140]) };
    private _scored = [];
    {
        private _b = _x;
        private _p = getPosATL _b;
        _p set [2, 0];
        if (!_pair) then {
            private _near = count ([_p, _nearR] call ZPI_fnc_buildingsNear);
            if (_near <= _maxNear) then {
                _scored pushBack [([_p, 60] call ZPI_fnc_greenScore) - 0.12 * _near - (_c distance2D _p) / (_radius * 4), _forEachIndex, [_b]];
            };
        } else {
            private _i = _forEachIndex;
            {
                private _m = _x;
                private _mid = ((getPosATL _b) vectorAdd (getPosATL _m)) vectorMultiply 0.5;
                _mid set [2, 0];
                private _cl = count ([_mid, _nearR] call ZPI_fnc_buildingsNear);
                if (_cl <= _maxNear) exitWith {
                    _scored pushBack [([_mid, 60] call ZPI_fnc_greenScore) - 0.12 * _cl - (_c distance2D _mid) / (_radius * 4), _i, [_b, _m]];
                };
            } forEach (_all select { _x != _b && {(_x distance2D _b) > 10} && {(_x distance2D _b) < 45} });
        };
    } forEach _all;
    if (_scored isEqualTo []) exitWith { [] };
    _scored sort false;
    ([_scored select [0, 3]] call ZPI_fnc_pick) select 2
};

// ---- dataset generator: one site per scene visit, within ZPI_cfg_siteRadius of a marker ------
// open ground -> [[score, posATL], ...] best first
ZPI_fnc_siteOpen = {
    params ["_anchor", "_R"];
    private _pts = (selectBestPlaces [[_anchor select 0, _anchor select 1], _R, "meadow - (2 * houses) - (2 * forest) - (10 * sea) - hills", 80, 40]) apply { _x select 0 };
    for "_i" from 1 to 160 do { _pts pushBack (_anchor getPos [(sqrt (random 1)) * _R, random 360]) };
    private _eval = {
        params ["_minQuick"];
        private _sc = [];
        {
            private _p = [_x select 0, _x select 1, 0];
            if (!surfaceIsWater _p && {([_p] call ZPI_fnc_surfaceGreen) >= _minQuick} && {((surfaceNormal _p) select 2) > 0.96}
                && {(count (nearestTerrainObjects [[_p select 0, _p select 1], ["TREE", "BUSH"], 30, false, true])) <= 4}) then {
                _sc pushBack [[_p, 150] call ZPI_fnc_greenScore, _forEachIndex, _p];
            };
        } forEach _pts;
        _sc
    };
    private _sc = [0.3] call _eval;
    if (_sc isEqualTo []) then { _sc = [0] call _eval };
    _sc sort false;
    private _out = [];
    {
        if ((count ([_x select 2, 200] call ZPI_fnc_buildingsNear)) <= ZPI_cfg_siteMaxBuildings) then { _out pushBack [_x select 0, _x select 2] };
        if (count _out >= 5) exitWith {};
    } forEach _sc;
    _out
};

// road out in the country -> [[score, posATL], ...]; _needPath = road pieces of 35 m behind it
ZPI_fnc_siteRoad = {
    params ["_anchor", "_R", ["_needPath", 0]];
    private _roads = ([_anchor select 0, _anchor select 1] nearRoads _R) select {
        private _i = getRoadInfo _x;
        !(_i select 8) && {(_i select 0) in ["ROAD", "MAIN ROAD", "TRACK"]}
    };
    _roads = (_roads call BIS_fnc_arrayShuffle) select [0, 250];
    private _sc = _roads apply {
        private _p = getPosATL _x;
        _p set [2, 0];
        [[_p, 100] call ZPI_fnc_greenScore, 0, _x]
    };
    { _x set [1, _forEachIndex] } forEach _sc;
    _sc sort false;
    private _out = [];
    {
        private _r = _x select 2;
        private _p = getPosATL _r;
        _p set [2, 0];
        if ((count ([_p, 200] call ZPI_fnc_buildingsNear)) <= ZPI_cfg_siteMaxBuildings
            && {_needPath <= 0 || {(count ([_r, _needPath, 35, true] call ZPI_fnc_roadPath)) >= _needPath}}) then {
            _out pushBack [_x select 0, _p];
        };
        if (count _out >= 5) exitWith {};
    } forEach (_sc select [0, 80]);
    _out
};

// [marker position, scene key] -> site posATL, or [] when nothing suitable is near the marker
ZPI_fnc_tourSite = {
    params ["_anchor", "_scene"];
    private _R = ZPI_cfg_siteRadius;
    private _site = [];
    private _green = -1;
    private _what = "";
    switch (true) do {
        case (_scene in [7, 10, 13, 14, 15, 16, 22]): {
            private _need = switch (_scene) do {
                case 7: { 0 };
                case 10: { 4 };
                case 15: { 2 };
                default { 3 };
            };
            private _b = if (_scene == 22) then {
                [_anchor, _need, false, _R, 1, ZPI_cfg_loneRadius] call ZPI_fnc_findEntryBuildings
            } else {
                [_anchor, _need, _scene == 15, _R] call ZPI_fnc_findEntryBuildings
            };
            if (_b isNotEqualTo []) then {
                _site = [0, 0, 0];
                { _site = _site vectorAdd (getPosATL _x) } forEach _b;
                _site = _site vectorMultiply (1 / (count _b));
                _site set [2, 0];
                _what = (_b apply { typeOf _x }) joinString "+";
            };
        };
        case (_scene in [1, 2, 4, 9, 11, 19, 21, 26]): {
            private _r = [_anchor, _R, switch (true) do {
                case (_scene == 19): { 8 };
                case (_scene in [4, 11, 21, 26]): { 6 };
                default { 0 };
            }] call ZPI_fnc_siteRoad;
            if (_r isNotEqualTo []) then {
                (selectRandom _r) params ["_g", "_p"];
                _site = _p;
                _what = "road";
            };
        };
        default {
            private _o = [_anchor, _R] call ZPI_fnc_siteOpen;
            if (_o isNotEqualTo []) then {
                (selectRandom _o) params ["_g", "_p"];
                _site = _p;
                _what = "open";
            };
        };
    };
    if (_site isEqualTo []) exitWith {
        ["site", format ['{"scene_key":%1,"found":false}', _scene]] call ZPI_fnc_event;
        []
    };
    _green = [_site, 120] call ZPI_fnc_greenScore;
    private _nb = count ([_site, 150] call ZPI_fnc_buildingsNear);
    ["site", format ['{"scene_key":%1,"found":true,"kind":"%2","pos":%3,"green":%4,"buildings_150m":%5,"surface":"%6"}',
        _scene, _what, [_site, 1] call ZPI_fnc_v3, _green toFixed 2, _nb, surfaceType _site]] call ZPI_fnc_event;
    if (_green < ZPI_cfg_minGreen) then {
        [format ["Site for scene %1: ground not very green (%2, %3) - best found near this marker", _scene, _green toFixed 2, surfaceType _site]] call ZPI_fnc_msg;
    };
    _site
};
