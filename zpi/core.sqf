// =====================================================================
//  ZPI scene pack - core helpers: seeded RNG, geometry, JSON, logging
// =====================================================================

ZPI_rngCounter = 0;

// ---- seeded RNG ------------------------------------------------------
// Uses the engine's "seed random x" (integer seed). SQF numbers are float32,
// so the seed is kept below 2^24 to stay exact.
ZPI_fnc_rand = {                 // [max] -> [0, max)
    params [["_max", 1]];
    ZPI_rngCounter = ZPI_rngCounter + 1;
    private _s = floor (((ZPI_cfg_seed * 997) + (ZPI_rngCounter * 131)) mod 16777000);
    ((_s random 1) min 0.999999) * _max
};

ZPI_fnc_randRange = {            // [a, b] -> [a, b)
    params ["_a", "_b"];
    _a + ([_b - _a] call ZPI_fnc_rand)
};

ZPI_fnc_randInt = {              // [n] -> 0 .. n-1
    params ["_n"];
    floor ([_n] call ZPI_fnc_rand)
};

ZPI_fnc_pick = {                 // [array] -> element
    params ["_arr"];
    _arr select ([count _arr] call ZPI_fnc_randInt)
};

// ---- geometry --------------------------------------------------------
// Point at (right, forward) metres from _p in a frame rotated to compass heading _h.
// Returns ATL [x, y, 0].
ZPI_fnc_rel = {
    params ["_p", "_h", "_right", "_fwd"];
    [
        (_p select 0) + _right * (cos _h) + _fwd * (sin _h),
        (_p select 1) - _right * (sin _h) + _fwd * (cos _h),
        0
    ]
};

ZPI_fnc_angDiff = {              // signed difference b - a in (-180, 180]
    params ["_a", "_b"];
    ((((_b - _a) mod 360) + 540) mod 360) - 180
};

// ---- JSON formatting ---------------------------------------------------
// str() keeps only ~6 significant digits, so numbers go through toFixed.
ZPI_fnc_v3 = {
    params ["_v", ["_d", 2]];
    format ["[%1,%2,%3]", (_v select 0) toFixed _d, (_v select 1) toFixed _d, (_v select 2) toFixed _d]
};

ZPI_fnc_pad = {                  // [number, width] -> zero-padded string
    params ["_n", "_w"];
    private _s = (floor _n) toFixed 0;   // str() would switch to 1.2e+006 notation
    while { count _s < _w } do { _s = "0" + _s };
    _s
};

ZPI_udp_enabled = false;
ZPI_fnc_initExtension = {
    ZPI_udp_enabled = false;
    if (!ZPI_cfg_udp) exitWith {};
    private _version = ZPI_cfg_extension callExtension "version";
    if (_version isEqualTo "") exitWith {
        diag_log text "ZPI|warn|telemetry extension not loaded: live records go to the RPT only";
    };
    private _reply = ZPI_cfg_extension callExtension ("udp:" + ZPI_cfg_udpTarget);
    ZPI_udp_enabled = (_reply find "ok") isEqualTo 0;
    diag_log text format ["ZPI|info|extension %1, target %2, reply %3", _version, ZPI_cfg_udpTarget, _reply];
};

ZPI_fnc_emit = {
    params ["_type", "_json"];
    private _line = format ["ZPI|%1|%2", _type, _json];
    diag_log text _line;
    if (ZPI_udp_enabled) then { ZPI_cfg_extension callExtension _line };
};

ZPI_fnc_event = {
    params ["_kind", ["_data", "{}"]];
    ["evt", format ['{"frame":%1,"t_game":%2,"kind":"%3","scene":"%4","seed":%5,"region":%6,"data":%7}',
        diag_frameNo toFixed 0, time toFixed 3, _kind, ZPI_sceneName, ZPI_cfg_seed, ZPI_regionId, _data]] call ZPI_fnc_emit;
};

// ZPI_quietMode: 0 -> everything visible, 1 -> hide everything except frame code, 2 -> hide everything including frame code.
ZPI_quietMode = 0;
ZPI_fnc_msg = {
    params ["_text"];
    if (ZPI_quietMode == 0) then {
        systemChat ("[ZPI] " + _text);
    };
};

// Drop classes that do not exist in this game install (missing DLC, typos).
ZPI_fnc_validClasses = {
    params ["_list", ["_root", "CfgVehicles"]];
    private _ok = _list select { isClass (configFile >> _root >> _x) };
    private _bad = _list - _ok;
    if (_bad isNotEqualTo []) then {
        diag_log format ["ZPI|warn|missing classes dropped: %1", _bad];
    };
    _ok
};
