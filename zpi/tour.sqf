// =====================================================================
//  ZPI scene pack - automatic dataset generator
//
//  Home key: generate ZPI_cfg_tourTarget labelled screenshots
//            on its own; Home again stops after the current picture.
//
//  Clear weather, noon. For every location marker it goes through a
//  shuffled list of scenes. Each scene is put on a green site near the
//  marker with few buildings (sites.sqf), then shot in BURSTS: the camera
//  stays at one position and takes a picture every ZPI_cfg_burstInterval s
//  (movement of soldiers and tanks shows between the pictures), then moves
//  to the next position. A view with more than ZPI_cfg_maxBuildings
//  buildings in the picture is never shot: the camera tries other angles,
//  then skips it.
//    static scenes      a few soldiers walk around, close-ups of soldiers
//                       (constant pixel size) and vehicles (a bit wider)
//    driving columns    the column driving through a fixed view, wide + single
//    patrols / squads   groups walking through a fixed view
//    building entries   the squad together, stacking at the door, part of it
//                       going in, the rest visible outside (camera on that side)
//  plus one explosion close-up per scene (with a reference picture, so the
//  box is measured). Buildings in every picture are labelled too.
// =====================================================================

ZPI_tourRunning = false;
ZPI_tourStop    = false;

// ---- camera placement ---------------------------------------------------------------
ZPI_fnc_tourAim = {             // [targetASL, azimuth (camera side), elevation deg, distance m]
    params ["_tp", "_az", "_el", "_dist"];
    private _h = _dist * (cos _el);
    private _p = _tp vectorAdd [_h * (sin _az), _h * (cos _az), _dist * (sin _el)];
    private _gz = (getTerrainHeightASL _p) max 0;
    if ((_p select 2) < _gz + 40) then { _p set [2, _gz + 40] };
    ZPI_camPosASL = _p;
    private _d = vectorNormalized (_tp vectorDiff _p);
    ZPI_yaw   = (_d select 0) atan2 (_d select 1);
    ZPI_pitch = asin (((_d select 2) max -1) min 1);
    ZPI_camDir = _d;
    ZPI_camUp  = [ZPI_yaw, ZPI_pitch] call ZPI_fnc_upFromYawPitch;
    ZPI_camVel = [0, 0, 0];
    ZPI_mouseDX = 0;
    ZPI_mouseDY = 0;
    call ZPI_fnc_applyCamPose;
};

ZPI_fnc_tourWaitIdle = {
    private _t0 = time;
    waitUntil { (ZPI_capState == 0 && {!ZPI_camLock} && {ZPI_pendingCapture < 0}) || {time > _t0 + 8} };
};

ZPI_fnc_tourDone = { ZPI_tourStop || {(ZPI_shotCount - ZPI_tourStart) >= ZPI_tourTarget} };

// [object | objects | posASL, seconds ahead] -> point to aim at (ASL), [] when nothing is left.
// Moving targets: where their middle will be _ahead seconds from now.
ZPI_fnc_tourLead = {
    params ["_t", "_ahead"];
    if (_t isEqualType objNull) then { _t = [_t] };
    if (_t isEqualTo []) exitWith { [] };
    if !((_t select 0) isEqualType objNull) exitWith { _t };        // already a position
    private _objs = _t select { !isNull _x && {alive _x} };
    if (_objs isEqualTo []) exitWith { [] };
    private _c = [0, 0, 0];
    private _v = [0, 0, 0];
    {
        _c = _c vectorAdd (getPosASL _x);
        _v = _v vectorAdd (velocity _x);
    } forEach _objs;
    _c = _c vectorMultiply (1 / (count _objs));
    _v = _v vectorMultiply (1 / (count _objs));
    _v set [2, 0];
    (_c vectorAdd (_v vectorMultiply _ahead)) vectorAdd [0, 0, 1]
};

// ---- one burst: fixed camera, a picture every ZPI_cfg_burstInterval s ------------------------
// [target, gsd range [min, max], pictures, view, max. buildings in view] -> pictures taken (0 = view skipped)
// view = [distance range, elevation range, camera azimuth center (-1 = any), azimuth spread, jitter m]
ZPI_fnc_tourBurst = {
    params ["_target", "_gsd", ["_shots", ZPI_cfg_burstShots], ["_view", []], ["_maxB", ZPI_cfg_maxBuildings]];
    _view params [["_dist", ZPI_cfg_tourDist], ["_elev", ZPI_cfg_tourElev], ["_azC", -1], ["_azS", 180], ["_jit", 3]];
    call ZPI_fnc_tourWaitIdle;
    if (call ZPI_fnc_tourDone) exitWith { 0 };
    _shots = _shots max 1;
    private _settle = ZPI_cfg_tourSettle;
    // aim where the targets will be in the middle of the burst
    private _ahead = _settle + ZPI_cfg_burstInterval * (_shots - 1) / 2;
    private _ok = false;
    for "_try" from 1 to ZPI_cfg_viewTries do {
        private _tp = [_target, _ahead] call ZPI_fnc_tourLead;
        if (_tp isEqualTo []) exitWith {};
        ZPI_scaleLock = true;
        ZPI_targetGSD = (_gsd select 0) + random ((_gsd select 1) - (_gsd select 0));
        private _az = if (_azC < 0) then { random 360 } else { _azC - _azS + random (2 * _azS) };
        [_tp vectorAdd [random (2 * _jit) - _jit, random (2 * _jit) - _jit, 0], _az,
            (_elev select 0) + random ((_elev select 1) - (_elev select 0)),
            (_dist select 0) + random ((_dist select 1) - (_dist select 0))] call ZPI_fnc_tourAim;
        sleep _settle;              // zoom follows the new range, terrain and objects load in
        if (ZPI_tourStop) exitWith {};
        private _nb = call ZPI_fnc_buildingsInView;
        if (_nb <= _maxB) exitWith { _ok = true };
        ["view_rejected", format ['{"buildings":%1,"try":%2}', _nb, _try]] call ZPI_fnc_event;
        // next try: another side, same zoom (soldiers keep the same pixel size in every picture)
    };
    if (!_ok) exitWith { 0 };

    // hold the zoom: every picture of the burst has exactly the same view
    ZPI_fovLock = true;
    ZPI_burstId = ZPI_burstId + 1;
    ZPI_burstLen = _shots;
    private _t0 = time;
    private _taken = 0;
    for "_k" from 0 to (_shots - 1) do {
        if (call ZPI_fnc_tourDone) exitWith {};
        ZPI_burstIdx = _k;
        private _before = ZPI_shotCount;
        call ZPI_fnc_startCapture;
        private _tw = time;
        waitUntil { (ZPI_capState == 0 && {ZPI_shotCount > _before}) || {time > _tw + 3} };
        _taken = _taken + (ZPI_shotCount - _before);
        ZPI_burstIdx = -1;
        if (_k < _shots - 1) then { waitUntil { time >= _t0 + (_k + 1) * ZPI_cfg_burstInterval } };
    };
    ZPI_burstIdx = -1;
    ZPI_fovLock = false;
    _taken
};

// One shell on clear ground next to _near; the camera looks at the impact point first.
// Zoomed out (ZPI_cfg_tourExplosionGSD) and aimed at the middle of the smoke column, so the
// column is a part of the picture and the measured box fits the smoke.
ZPI_fnc_tourExplosion = {
    params ["_near"];
    call ZPI_fnc_tourWaitIdle;
    if (ZPI_tourStop || {isNull _near}) exitWith {};
    private _p = [_near, 60, 160] call ZPI_fnc_fireTarget;
    private _ok = false;
    for "_try" from 1 to ZPI_cfg_viewTries do {
        ZPI_scaleLock = true;
        ZPI_targetGSD = (ZPI_cfg_tourExplosionGSD select 0) + random ((ZPI_cfg_tourExplosionGSD select 1) - (ZPI_cfg_tourExplosionGSD select 0));
        [_p vectorAdd [0, 0, 8], random 360, (ZPI_cfg_tourElev select 0) + random ((ZPI_cfg_tourElev select 1) - (ZPI_cfg_tourElev select 0)),
            (ZPI_cfg_tourDist select 0) + random ((ZPI_cfg_tourDist select 1) - (ZPI_cfg_tourDist select 0))] call ZPI_fnc_tourAim;
        sleep ZPI_cfg_tourSettle;
        if ((call ZPI_fnc_buildingsInView) <= ZPI_cfg_maxBuildings) exitWith { _ok = true };
    };
    if (!_ok || {ZPI_tourStop}) exitWith {};
    private _ammo = ([ZPI_cfg_barrageAmmo, "CfgAmmo"] call ZPI_fnc_validClasses) param [0, "Sh_82mm_AMOS"];
    private _ref = "";
    if ([_p] call ZPI_fnc_takeRef) then {
        _ref = ZPI_refImage;
        sleep 0.15;
    };
    private _before = ZPI_shotCount;
    ZPI_expId = ZPI_expId + 1;
    private _sh = createVehicle [_ammo, [_p select 0, _p select 1, 60], [], 0, "CAN_COLLIDE"];
    _sh setVariable ["ZPI_id", ZPI_expId];
    _sh setPosASL (_p vectorAdd [0, 0, 60]);
    _sh setVectorDirAndUp [[0, 0, -1], [0, 1, 0]];
    _sh setVariable ["ZPI_expSize", [_ammo] call ZPI_fnc_explosionSize];
    _sh addEventHandler ["Explode", {
        params ["_projectile", "_pos"];
        [_pos, _projectile getVariable ["ZPI_expSize", ZPI_cfg_expMedium], _projectile getVariable ["ZPI_id", -1]] call ZPI_fnc_addExplosion;
    }];
    _sh setVelocity [0, 0, -150];
    // the explosion triggers the first picture by itself (0.35 s after it); more pictures of the same
    // explosion (ZPI_cfg_tourExplosionFrames) from the unchanged view, with the same reference picture
    private _t0 = time;
    waitUntil {
        sleep 0.05;
        ZPI_shotCount > _before || {time > _t0 + 4}
    };
    if (ZPI_cfg_tourExplosionFrames > 1 && {ZPI_shotCount > _before} && {_ref != ""}) then {
        private _t1 = time;
        for "_k" from 2 to ZPI_cfg_tourExplosionFrames do {
            if (ZPI_tourStop) exitWith {};
            waitUntil { ZPI_capState == 0 };
            waitUntil { time >= _t1 + 0.95 * (_k - 1) };
            ZPI_refImage = _ref;
            ZPI_camLock = true;
            ZPI_fovLock = true;
            ZPI_refUntil = time + 3;
            private _b2 = ZPI_shotCount;
            call ZPI_fnc_startCapture;
            waitUntil {
                sleep 0.05;
                (ZPI_capState == 0 && {ZPI_shotCount > _b2}) || {time > _t1 + 6}
            };
        };
    };
    sleep 1;
    call ZPI_fnc_tourWaitIdle;
};

// ---- helpers ------------------------------------------------------------------------
ZPI_fnc_tourObjs = {            // [cls list] -> alive scene objects of those classes
    params ["_cls"];
    (ZPI_entities select { (_x select 2) in _cls && {!isNull (_x select 1)} && {alive (_x select 1)} }) apply { _x select 1 }
};

// Static layouts: a share of the standing soldiers walk around their spot, so the
// pictures of a burst are not all identical. Stops when the scene is cleared.
ZPI_fnc_tourAnimate = {
    params ["_share"];
    if (_share <= 0) exitWith {};
    private _men = (["soldier"] call ZPI_fnc_tourObjs) select { isNull objectParent _x && {!((unitPos _x) in ["Down", "Middle"])} };   // kneeling / prone stay
    private _walkers = (_men call BIS_fnc_arrayShuffle) select [0, ceil ((count _men) * _share)];
    {
        _x enableAI "PATH";
        _x setUnitPos "UP";
        _x forceWalk true;
        _x setVariable ["ZPI_home", getPosATL _x];
    } forEach _walkers;
    [_walkers, ZPI_sceneToken] spawn {
        params ["_w", "_token"];
        while { ZPI_sceneToken == _token } do {
            {
                if (!isNull _x && {alive _x} && {unitReady _x || {random 1 < 0.15}}) then {
                    _x doMove ((_x getVariable ["ZPI_home", getPosATL _x]) getPos [5 + random 20, random 360]);
                };
            } forEach _w;
            sleep (4 + random 4);
        };
    };
};

// One firing episode: the camera goes beside a tank, zoomed so tank and muzzle blast fill the
// picture; the tank turns its turret, the camera holds still for the reference picture, the shot
// triggers the picture automatically ("tank_fire" label), and _extra more pictures follow (smoke).
// [vehicles, extra pictures] -> pictures taken, -1 when no vehicle can fire
ZPI_fnc_tourFiring = {
    params ["_cands", ["_extra", 1]];
    private _v = _cands select { alive _x && {!(_x getVariable ["ZPI_busy", false])} && {(_x getVariable ["ZPI_firePlan", []]) isNotEqualTo ["none"]} };
    if (_v isEqualTo []) exitWith { -1 };
    private _t = selectRandom _v;
    call ZPI_fnc_tourWaitIdle;
    if (call ZPI_fnc_tourDone) exitWith { 0 };
    private _ok = false;
    for "_try" from 1 to ZPI_cfg_viewTries do {
        ZPI_scaleLock = true;
        ZPI_targetGSD = (ZPI_cfg_tourFireGSD select 0) + random ((ZPI_cfg_tourFireGSD select 1) - (ZPI_cfg_tourFireGSD select 0));
        // from the side of the tank (+-70 deg from the hull), looking at a point a bit in front of it
        private _az = (getDir _t) + ([70, -70] select (random 1 < 0.5)) + random 40 - 20;
        [(getPosASL _t) vectorAdd ((vectorDir _t) vectorMultiply 4) vectorAdd [0, 0, 2], _az, 30 + random 25,
            (ZPI_cfg_tourDist select 0) + random 100] call ZPI_fnc_tourAim;
        sleep ZPI_cfg_tourSettle;
        if ((call ZPI_fnc_buildingsInView) <= ZPI_cfg_maxBuildings) exitWith { _ok = true };
    };
    if (!_ok) exitWith { 0 };
    ZPI_fovLock = true;
    private _before = ZPI_shotCount;
    private _t0 = time;
    [_t, 1] spawn ZPI_fnc_vehFire;
    waitUntil {
        sleep 0.1;
        ZPI_shotCount > _before || {time > _t0 + 25}
    };
    if (ZPI_shotCount > _before) then {
        for "_k" from 1 to _extra do {
            sleep 0.6;
            waitUntil { ZPI_capState == 0 };
            call ZPI_fnc_startCapture;
            sleep 0.2;
            waitUntil { ZPI_capState == 0 };
        };
    };
    waitUntil {
        sleep 0.2;
        !(_t getVariable ["ZPI_busy", false]) || {time > _t0 + 30}
    };
    ZPI_fovLock = false;
    ZPI_shotCount - _before
};

// soldiers of a building scene who are not inside any of the watched buildings
ZPI_fnc_tourOutside = {
    private _bs = ZPI_buildingWatch apply { _x select 0 };
    private _units = [];
    { { _units pushBackUnique _x } forEach (_x select 1) } forEach ZPI_buildingWatch;
    _units select {
        private _u = _x;
        alive _u && {isNull objectParent _u} && {({ [_u, _x] call ZPI_fnc_insideOf } count _bs) == 0}
    }
};

// ---- one scene, shot in bursts in the style that suits it --------------------------------
ZPI_fnc_tourScene = {
    params ["_scene"];
    private _soldierGSD = ZPI_cfg_tourSoldierGSD;
    private _sView = [ZPI_cfg_tourDist, ZPI_cfg_tourElevSoldier];          // soldier shots: a lower camera angle
    private _vehicleGSD = ZPI_cfg_tourVehicleGSD;           // tanks: the scale rule is relaxed
    private _men  = { (["soldier"] call ZPI_fnc_tourObjs) select { isNull objectParent _x } };
    private _vehs = { ["tracked_vehicle", "wheeled_vehicle"] call ZPI_fnc_tourObjs };
    private _all  = { (ZPI_entities select { !isNull (_x select 1) && {alive (_x select 1)} }) apply { _x select 1 } };
    private _n = ZPI_cfg_tourShots getOrDefault [_scene, 10];
    private _start = ZPI_shotCount;
    private _fails = 0;              // views that could not be shot (too many buildings, nothing left)
    private _more = { ((_n - (ZPI_shotCount - _start)) > 0) && {!(call ZPI_fnc_tourDone)} && {_fails < 6} };
    private _len  = {
        params ["_max"];
        (_max min (_n - (ZPI_shotCount - _start))) max 1
    };
    private _shoot = {               // [target, gsd, pictures, view]
        private _k = _this call ZPI_fnc_tourBurst;
        if (_k == 0) then { _fails = _fails + 1 };
        _k
    };
    private _i = 0;

    switch (true) do {
        // ---- driving columns (road convoy, tank column, tank column across fields)
        case (_scene in [4, 11, 17, 19, 26]): {
            sleep 10;                                           // let the column get going
            while { call _more } do {
                private _v = call _vehs;
                if (_v isEqualTo []) exitWith {};
                private _moving = _v select { (speed _x) > 3 };
                if (_i % 3 == 2) then {
                    [selectRandom ([_v, _moving] select (_moving isNotEqualTo [])), _vehicleGSD,
                        [ZPI_cfg_burstShots] call _len, [ZPI_cfg_tourDist, ZPI_cfg_tourElevColumn]] call _shoot;          // one vehicle
                } else {
                    [_v, ZPI_cfg_tourColumnGSD, [ZPI_cfg_burstShots] call _len, [ZPI_cfg_tourDistWide, ZPI_cfg_tourElevColumn]] call _shoot;   // the column
                };
                _i = _i + 1;
            };
        };
        // ---- walking soldiers: a group walking through a fixed view
        //      Two of three bursts from a flatter angle (ZPI_cfg_tourElevPatrol, ~30-45 deg), more from the side.
        case (_scene in [5, 12, 20, 21]): {
            sleep 5;
            while { call _more } do {
                private _m = call _men;
                if (_m isEqualTo []) exitWith {};
                private _u = selectRandom _m;
                private _view = [_sView, [ZPI_cfg_tourDist, ZPI_cfg_tourElevPatrol]] select (_i % 3 != 2);
                if (_i % 2 == 0) then {
                    [_m select { (_x distance2D _u) < ZPI_cfg_tourGroupRadius }, _soldierGSD, [ZPI_cfg_burstShots] call _len, _view] call _shoot;
                } else {
                    [_m select { (_x distance2D _u) < 5 }, _soldierGSD, [ZPI_cfg_burstShots] call _len, _view] call _shoot;
                };
                _i = _i + 1;
            };
        };
        // ---- building entries: squad together, stacking, going in, the rest outside.
        //      The camera stays on the side where the squad waits, so nobody is hidden.
        case (_scene in [10, 13, 14, 15, 16, 22]): {
            private _maxB = [ZPI_cfg_maxBuildings, ZPI_cfg_loneMaxBuildings] select (_scene == 22);   // lone building: only that house
            // Aim at the squad outside (those still walking in and those who stay), plus the door
            // once they are near it. Same zoom as all soldier pictures: soldiers keep their size.
            sleep 2;
            while { call _more } do {
                if (ZPI_entrySites isEqualTo []) exitWith {};
                (selectRandom ZPI_entrySites) params ["_b", "_door", "_stage"];
                private _az = (getPosATL _b) getDir _stage;
                private _ahead = ZPI_cfg_tourSettle + ZPI_cfg_burstInterval * (ZPI_cfg_burstShots - 1) / 2;
                private _pts = (call ZPI_fnc_tourOutside) apply {
                    private _v = velocity _x;
                    _v set [2, 0];
                    (getPosASL _x) vectorAdd (_v vectorMultiply _ahead)
                };
                private _doorASL = (AGLToASL _door) vectorAdd [0, 0, 1];
                if (_pts isEqualTo [] || {({ (_x distance2D _doorASL) < 14 } count _pts) > 0}) then { _pts pushBack _doorASL };
                private _c = [0, 0, 0];
                { _c = _c vectorAdd _x } forEach _pts;
                _c = _c vectorMultiply (1 / (count _pts));
                // same zoom as every other soldier picture (constant soldier size); the picture is
                // centred on the soldiers outside, plus the door once they are close to it
                private _el = 55;
                [_c vectorAdd [0, 0, 1], ZPI_cfg_tourSoldierGSD, [ZPI_cfg_burstShots] call _len,
                    [ZPI_cfg_tourDist, [_el - 8, _el + 8], _az, 50, 0], _maxB] call _shoot;
                _i = _i + 1;
            };
        };
        // ---- tanks firing: camera beside a tank, zoomed so tank and muzzle blast fill the picture.
        //      The tank turns its turret, the camera holds still for the reference picture, the
        //      shot triggers the picture automatically (label "tank_fire"); two more follow (smoke).
        case (_scene == 18): {
            sleep 3;
            while { call _more } do {
                private _k = [call _vehs, ZPI_cfg_tourFiringExtra] call ZPI_fnc_tourFiring;
                if (_k < 0) exitWith {};
                if (_k == 0) then { _fails = _fails + 1 };
            };
        };
        // ---- groups down (kneeling / prone): the whole group, then parts of it; nobody walks.
        //      Half the bursts from the flatter patrol angle, half from the usual soldier angle.
        case (_scene == 23): {
            sleep 4;                                            // everybody gets down
            while { call _more } do {
                private _gs = ZPI_downGroups apply { _x select { alive _x } };
                _gs = _gs select { _x isNotEqualTo [] };
                if (_gs isEqualTo []) exitWith {};
                private _grp = selectRandom _gs;
                private _view = [_sView, [ZPI_cfg_tourDist, ZPI_cfg_tourElevPatrol]] select (_i % 2 == 0);
                private _tgt = if (_i % 3 == 2) then {
                    private _u = selectRandom _grp;
                    _grp select { (_x distance2D _u) < 5 }
                } else { _grp };
                [_tgt, _soldierGSD, [ZPI_cfg_burstShotsStatic] call _len, _view] call _shoot;
                _i = _i + 1;
            };
        };
        // ---- clutter, no targets (background pictures): the props, bushes and small trees in turn,
        //      half at the soldier zoom, half at the far zoom; no building in the picture
        case (_scene == 28): {
            sleep 2;
            while { call _more } do {
                if (ZPI_clutterPoints isEqualTo []) exitWith {};
                private _far = _i % 2 == 1;
                [selectRandom ZPI_clutterPoints, [ZPI_cfg_tourSoldierGSD, ZPI_cfg_tourFarGSD] select _far, [ZPI_cfg_burstShotsStatic] call _len,
                    [[ZPI_cfg_tourDist, [300, 700]] select _far, [ZPI_cfg_tourElevSoldier, ZPI_cfg_tourElev] select _far], 0] call _shoot;
                _i = _i + 1;
            };
        };
        // ---- static layouts: some soldiers walk; every target in turn, vehicles a bit wider
        default {
            [ZPI_cfg_tourAnimate] call ZPI_fnc_tourAnimate;
            sleep 4;
            private _t = (call _all) call BIS_fnc_arrayShuffle;
            while { call _more } do {
                if (_t isEqualTo []) exitWith {};
                private _o = _t select (_i mod (count _t));
                if (!isNull _o && {alive _o}) then {
                    if (_o isKindOf "Man") then {
                        [_o, _soldierGSD, [ZPI_cfg_burstShotsStatic] call _len, _sView] call _shoot;
                    } else {
                        [_o, _soldierGSD, [ZPI_cfg_burstShotsStatic] call _len] call _shoot;   // same scale: soldiers next to it stay the same size
                    };
                };
                _i = _i + 1;
                if (_i > 3 * (count _t)) exitWith {};
            };
        };
    };

    // tanks in a static scene also fire (labelled "tank_fire"), not in driving columns
    if (ZPI_cfg_tourFiringPerScene > 0 && {!(_scene in [4, 11, 17, 18, 19, 26, 28, 9, 10, 13, 14, 15, 16, 22])} && {!(call ZPI_fnc_tourDone)}) then {
        private _tanks = ["tracked_vehicle"] call ZPI_fnc_tourObjs;
        if (_tanks isNotEqualTo []) then {
            for "_e" from 1 to ZPI_cfg_tourFiringPerScene do {
                if (call ZPI_fnc_tourDone) exitWith {};
                if (([_tanks, ZPI_cfg_tourFiringExtra] call ZPI_fnc_tourFiring) < 0) exitWith {};
            };
        };
    };

    // one explosion picture (not in the negatives, building scenes or tank firing)
    if (ZPI_cfg_tourExplosions > 0 && {!(_scene in [9, 10, 13, 14, 15, 16, 18, 22, 28])} && {!(call ZPI_fnc_tourDone)}) then {
        private _a = call _all;
        if (_a isNotEqualTo []) then {
            for "_e" from 1 to ZPI_cfg_tourExplosions do {
                if (call ZPI_fnc_tourDone) exitWith {};
                [selectRandom _a] call ZPI_fnc_tourExplosion;
            };
        };
    };
    ZPI_shotCount - _start
};

// ---- the generator ---------------------------------------------------------------------
// Rounds over all location markers, shuffled scene list each time, until ZPI_tourTarget pictures
// (counted from ZPI_tourStart) are taken or Home is pressed.
ZPI_fnc_tourRounds = {
    private _locs = [];
    for "_l" from 0 to ((count ZPI_locations) - 1) do { _locs pushBack _l };
    private _firstRound = true;
    while { !(call ZPI_fnc_tourDone) } do {
        private _cycleStart = ZPI_shotCount;
        {
            if (call ZPI_fnc_tourDone) exitWith {};
            private _loc = _x;
            private _anchor = ZPI_locations select _loc;
            ZPI_regionId = _loc;
            // shuffled scenes; the very first scene of a normal run is the tank-firing one, so even a short test has it
            private _order = ZPI_cfg_tourScenes call BIS_fnc_arrayShuffle;
            if (_firstRound && {ZPI_tourStage == ""} && {18 in _order}) then { _order = [18] + (_order - [18]) };
            _firstRound = false;
            {
                if (call ZPI_fnc_tourDone) exitWith {};
                ZPI_timeIndex = ZPI_cfg_tourTime;
                call ZPI_fnc_applyTime;
                ZPI_weatherIndex = ZPI_cfg_tourWeather;
                call ZPI_fnc_applyWeather;
                ZPI_cfg_seed = ZPI_cfg_seed + 1;
                profileNamespace setVariable ["ZPI_nextTourSeed", ZPI_cfg_seed + 1];
                saveProfileNamespace;
                // a green, uncluttered site near this marker for this kind of scene
                private _site = [_anchor, _x] call ZPI_fnc_tourSite;
                if (_site isEqualTo []) then {
                    [format ["No suitable site for scene %1 near location %2, skipped", _x, _loc]] call ZPI_fnc_msg;
                } else {
                    ZPI_center = _site;
                    ["center", format ['{"center":%1,"anchor":%2}', [ZPI_center, 1] call ZPI_fnc_v3, [_anchor, 1] call ZPI_fnc_v3]] call ZPI_fnc_event;
                    [_x] call ZPI_fnc_runScene;
                    if (ZPI_entities isNotEqualTo []) then { [_x] call ZPI_fnc_tourScene };
                };
                [format ["Dataset%1: %2 / %3 images (run total %4)", ["", " stage '" + ZPI_tourStage + "'"] select (ZPI_tourStage != ""),
                    ZPI_shotCount - ZPI_tourStart, ZPI_tourTarget, ZPI_shotCount - ZPI_tourRunStart]] call ZPI_fnc_msg;
            } forEach _order;
        } forEach _locs;
        if (ZPI_shotCount == _cycleStart && {!ZPI_tourStop}) exitWith {
            ["Generator: a whole round gave no images (no green, uncluttered sites?). Raise ZPI_cfg_maxBuildings or ZPI_cfg_siteRadius in config.sqf"] call ZPI_fnc_msg;
        };
    };
};

// Home. With a plan (ZPI_cfg_tourPlan) the stages run one after another, each with its profile's
// settings (ZPI_tourProfiles) and its own number of pictures; without a plan: ZPI_cfg_tourTarget
// pictures of the normal scene list.
ZPI_tourStage = "";
ZPI_fnc_tourDataset = {
    params [["_target", -1]];
    if (ZPI_tourRunning) exitWith { ["Generator already running"] call ZPI_fnc_msg };
    ZPI_tourRunning = true;
    ZPI_tourStop = false;
    ZPI_autoCapture = false;
    ZPI_firefight = false;
    ZPI_tourRunStart = ZPI_shotCount;
    private _plan = if (_target > 0 || {ZPI_cfg_tourPlan isEqualTo []}) then {
        [["", [ZPI_cfg_tourTarget, _target] select (_target > 0)]]
    } else { ZPI_cfg_tourPlan };
    private _total = 0;
    { _total = _total + (_x select 1) } forEach _plan;
    // Layout seeds never repeat between runs: every run continues where the last run on this PC
    // stopped (kept in the Arma profile, saved after every scene, so also after a crash).
    // Runs before this version used seeds below 1000.
    ZPI_cfg_seed = (profileNamespace getVariable ["ZPI_nextTourSeed", 1000]) max 1000;
    if (ZPI_cfg_seed > 16000) then { ZPI_cfg_seed = 1000 };          // seeds stay exact in 32-bit floats
    ["tour_start", format ['{"target":%1,"burst":%2,"interval":%3,"max_buildings":%4,"first_seed":%5,"plan":%6}',
        _total, ZPI_cfg_burstShots, ZPI_cfg_burstInterval, ZPI_cfg_maxBuildings, ZPI_cfg_seed,
        str (_plan apply { [_x select 0, _x select 1] })]] call ZPI_fnc_event;
    [format [
        "Dataset generator: %1 images in %5 stage(s), weather: %2, time: %3, aperture %4 (Home stops)", _total,
        (ZPI_weatherPresets select ZPI_cfg_tourWeather) select 0, (ZPI_timePresets select ZPI_cfg_tourTime) select 3, apertureParams select 0, count _plan
    ]] call ZPI_fnc_msg;

    // every setting a profile can change, saved so each stage starts from the normal values
    private _saved = createHashMap;
    {
        _x params ["_prof"];
        { if !(_x in _saved) then { _saved set [_x, missionNamespace getVariable _x] } } forEach (keys (ZPI_tourProfiles getOrDefault [_prof, createHashMap]));
    } forEach _plan;
    {
        _x params ["_prof", "_frames"];
        if (ZPI_tourStop) exitWith {};
        { missionNamespace setVariable [_x, _y] } forEach _saved;
        if (_prof != "" && {!(_prof in ZPI_tourProfiles)}) then {
            [format ["Generator: no profile '%1' in ZPI_tourProfiles (config.sqf), stage uses the normal settings", _prof]] call ZPI_fnc_msg;
        };
        { missionNamespace setVariable [_x, _y] } forEach (ZPI_tourProfiles getOrDefault [_prof, createHashMap]);
        ZPI_tourStage = _prof;
        ZPI_tourTarget = _frames;
        ZPI_tourStart = ZPI_shotCount;
        ["tour_stage", format ['{"stage":"%1","index":%2,"target":%3}', _prof, _forEachIndex, _frames]] call ZPI_fnc_event;
        if (_prof != "") then { [format ["Stage %1 / %2: '%3', %4 images", _forEachIndex + 1, count _plan, _prof, _frames]] call ZPI_fnc_msg };
        call ZPI_fnc_tourRounds;
        ["tour_stage_end", format ['{"stage":"%1","shots":%2}', _prof, ZPI_shotCount - ZPI_tourStart]] call ZPI_fnc_event;
    } forEach _plan;
    { missionNamespace setVariable [_x, _y] } forEach _saved;
    ZPI_tourStage = "";
    ZPI_targetGSD = ZPI_startGSD;
    ZPI_fovLock = false;
    ZPI_burstIdx = -1;
    ZPI_tourRunning = false;
    ["tour_end", format ['{"shots":%1,"stopped":%2}', ZPI_shotCount - ZPI_tourRunStart, ZPI_tourStop]] call ZPI_fnc_event;
    [format ["Dataset generator finished: %1 images. Run tools/make_yolo_dataset.py", ZPI_shotCount - ZPI_tourRunStart]] call ZPI_fnc_msg;
};
