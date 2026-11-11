// =====================================================================
//  ZPI scene pack - dataset capture: screenshot + automatic labels
//
//  P        one capture              Shift+P  auto-capture every N s
//  K        firefight on/off         Shift+K  one volley
//  I        automatic shot when an explosion happens on screen (on/off)
//
//  How a capture works (all automatic):
//    frame 0  freeze: camera stops, moving units are frozen
//    frame 1  boxes from the game's own 3D geometry + screenshot
//    frame 2  unfreeze (the screenshot is saved when frame 1 is rendered)
//  Log records per screenshot (one line each, kept short for the RPT):
//    ZPI|shot|   image, camera pose + FOV + attitude + altitude
//    ZPI|shotx|  laser rangefinder, scene, time, weather, explosion reference image, building occupancy
//    ZPI|dem|    terrain heights on a grid under the view;  ZPI|ray|  what 9 x 5 image points hit
//    ZPI|label|  boxes, in parts: [kind, cx, cy, w, h, id, visible, cut, stance, dist, inside, grid,
//                gx, gy, gz, gu, gv, method]  (g = ground point ASL and its normalized image position)
//                kind: "s" soldier, "t" tank (tracked), "v" military vehicle (wheeled), "e" explosion,
//                      "f" gun firing (muzzle blast of a tank / IFV main gun), "b" building
//  tools/make_yolo_dataset.py turns them into YOLO labels + one JSON per screenshot.
// =====================================================================

ZPI_clsToKind = createHashMapFromArray [["soldier", "s"], ["tracked_vehicle", "t"], ["wheeled_vehicle", "v"]];

ZPI_capFrozenEntities = [];
ZPI_capTaken     = false; // screenshot taken this capture; it is saved when its frame is rendered
ZPI_autoCapture  = false;
ZPI_autoInterval = 2;     // s between automatic captures
ZPI_nextAuto     = 0;
ZPI_shotCount    = 0;
ZPI_explosions   = [];    // [posASL, tStart, radius, height, duration]
ZPI_firings      = [];    // [muzzlePosASL, direction, tStart, vehicleId, radius, duration]

// ---- pinhole projection with the camera of the rendered frame ---------------------
// Returns normalized image coordinates [u, v] (0..1 = image edges) or [] for points behind the camera.
ZPI_fnc_projectN = {
    params ["_pASL", "_basis", "_th", "_tv"];
    _basis params ["_o", "_r", "_u", "_f"];
    private _d = _pASL vectorDiff _o;
    private _zc = _d vectorDotProduct _f;
    if (_zc < 0.5) exitWith { [] };
    [0.5 + (_d vectorDotProduct _r) / (_zc * 2 * _th), 0.5 - (_d vectorDotProduct _u) / (_zc * 2 * _tv)]
};

// [points ASL] -> [x0, y0, x1, y1] normalized, unclipped; [] if any point is behind
ZPI_fnc_boxOfPoints = {
    params ["_pts", "_basis", "_th", "_tv"];
    private _x0 = 1e9;
    private _y0 = 1e9;
    private _x1 = -1e9;
    private _y1 = -1e9;
    private _ok = true;
    {
        private _s = [_x, _basis, _th, _tv] call ZPI_fnc_projectN;
        if (_s isEqualTo []) exitWith { _ok = false };
        _x0 = _x0 min (_s select 0);
        _x1 = _x1 max (_s select 0);
        _y0 = _y0 min (_s select 1);
        _y1 = _y1 max (_s select 1);
    } forEach _pts;
    if (!_ok) exitWith { [] };
    [_x0, _y0, _x1, _y1]
};

ZPI_fnc_corners = {             // 8 corners of a model-space box -> world ASL
    params ["_obj", "_mn", "_mx"];
    private _out = [];
    {
        private _cx = _x;
        {
            private _cy = _x;
            {
                _out pushBack (_obj modelToWorldVisualWorld [_cx, _cy, _x]);
            } forEach [_mn select 2, _mx select 2];
        } forEach [_mn select 1, _mx select 1];
    } forEach [_mn select 0, _mx select 0];
    _out
};

ZPI_fnc_worldBoxCorners = {     // axis-aligned world box around a point
    params ["_p", "_rx", "_z0", "_z1"];
    private _out = [];
    {
        private _dx = _x;
        {
            private _dy = _x;
            {
                _out pushBack (_p vectorAdd [_dx, _dy, _x])
            } forEach [_z0, _z1]
        } forEach [-_rx, _rx]
    } forEach [-_rx, _rx];
    _out
};

// Soldier: model-space box from the HitPoints LOD, which follows the animation
// (standing, kneeling and prone all get a tight box). Fallback: boundingBoxReal.
ZPI_fnc_soldierBox = {
    params ["_u"];
    private _mn = [1e9, 1e9, 1e9];
    private _mx = [-1e9, -1e9, -1e9];
    private _n = 0;
    {
        private _bb = _u selectionPosition [_x, "HitPoints", "BoundingBox"];
        if (_bb isEqualType [] && {count _bb == 2} && {(_bb select 0) isEqualType []} && {(_bb select 0) isNotEqualTo (_bb select 1)}) then {
            for "_i" from 0 to 2 do {
                _mn set [_i, (_mn select _i) min ((_bb select 0) select _i)];
                _mx set [_i, (_mx select _i) max ((_bb select 1) select _i)];
            };
            _n = _n + 1;
        };
    } forEach ["head", "neck", "spine3", "pelvis", "arms", "hands", "legs", "body"];
    if (_n < 2) exitWith {
        private _bb = boundingBoxReal _u;
        [_bb select 0, _bb select 1]
    };
    private _pad = ZPI_cfg_soldierPad;
    [_mn vectorDiff [_pad, _pad, _pad], _mx vectorAdd [_pad, _pad, _pad + 0.1]]   // +0.1 m helmet
};

// ---- tight soldier box ----------------------------------------------------------------
// The box above is ONE 3D box around the whole body; projected from an oblique drone view its
// near-bottom corners land well below the feet (box bottom 10-40 % of the box height below the
// ground point). The label therefore uses the body parts one by one: every bone of the visible
// model (head, upper arm, forearm, hand, thigh, shin, foot, toes, ...) has its own small box;
// the corners of each are projected and the 2D box is their union, which hugs the silhouette.
// Fallback: the same with the hit-point parts (bigger, still much tighter than one 3D box).
ZPI_soldierBones = ["head", "neck", "neck1", "spine", "spine1", "spine2", "spine3", "pelvis",
    "leftshoulder", "leftarm", "leftforearm", "lefthand", "rightshoulder", "rightarm", "rightforearm", "righthand",
    "leftupleg", "leftleg", "leftfoot", "lefttoebase", "rightupleg", "rightleg", "rightfoot", "righttoebase"];
ZPI_soldierHitParts = ["head", "neck", "spine3", "pelvis", "arms", "hands", "legs", "body"];

// [unit, names, LOD (index number or name)] -> [[name, mn, mx], ...] of the parts that exist
ZPI_fnc_partBoxes = {
    params ["_u", "_names", "_lod"];
    private _out = [];
    {
        private _bb = if (_lod isEqualType 0) then {
            selectionPosition [_u, _x, _lod, true, "BoundingBox"]
        } else {
            _u selectionPosition [_x, _lod, "BoundingBox"]
        };
        if (!isNil "_bb" && {_bb isEqualType []} && {count _bb == 2} && {(_bb select 0) isEqualType []}
            && {(_bb select 0) isNotEqualTo (_bb select 1)}) then {
            _out pushBack [_x, _bb select 0, _bb select 1];
        };
    } forEach _names;
    _out
};

// [unit, hit-point box [mn, mx], basis, th, tv] -> [[x0, y0, x1, y1] normalized, method]
// method "v" = bones of the visible model, "h" = hit-point parts, "" = nothing usable
ZPI_fnc_soldierBox2D = {
    params ["_u", "_hb", "_basis", "_th", "_tv"];
    private _parts = [_u, ZPI_soldierBones, 0] call ZPI_fnc_partBoxes;
    private _meth = "v";
    // sanity: the bones must follow the animation (top of the body like the hit points, which do)
    // and lie inside the hit-point body box (+ margin), else the pose is not the animated one
    private _hmn = (_hb select 0) vectorAdd [ZPI_cfg_soldierPad - 0.35, ZPI_cfg_soldierPad - 0.35, ZPI_cfg_soldierPad - 0.35];
    private _hmx = (_hb select 1) vectorAdd [0.35 - ZPI_cfg_soldierPad, 0.35 - ZPI_cfg_soldierPad, 0.25 - ZPI_cfg_soldierPad];
    private _top = -1e9;
    private _outside = 0;
    {
        _top = _top max ((_x select 2) select 2);
        private _c = ((_x select 1) vectorAdd (_x select 2)) vectorMultiply 0.5;
        if (((_c select 0) < (_hmn select 0)) || {(_c select 0) > (_hmx select 0)} || {(_c select 1) < (_hmn select 1)}
            || {(_c select 1) > (_hmx select 1)} || {(_c select 2) < (_hmn select 2)} || {(_c select 2) > (_hmx select 2)}) then { _outside = _outside + 1 };
    } forEach _parts;
    if (count _parts < 10 || {_outside > 1} || {abs (_top - (((_hb select 1) select 2) - ZPI_cfg_soldierPad - 0.1)) > 0.45}) then {
        _parts = [_u, ZPI_soldierHitParts, "HitPoints"] call ZPI_fnc_partBoxes;
        _meth = "h";
    };
    if (count _parts < 2) exitWith { [[], ""] };
    private _pad = ZPI_cfg_soldierPartPad;
    private _pack = (backpack _u) != "";
    private _x0 = 1e9;
    private _y0 = 1e9;
    private _x1 = -1e9;
    private _y1 = -1e9;
    private _ok = true;
    {
        _x params ["_name", "_mn", "_mx"];
        _mn = _mn vectorDiff [_pad, _pad, _pad];
        _mx = _mx vectorAdd [_pad, _pad, _pad];
        // gear that is not part of the body model: helmet on the head, backpack behind the back
        if (_name == "head") then { _mx = _mx vectorAdd [0, 0, ZPI_cfg_soldierHelmet] };
        if (_pack && {_name in ["spine2", "spine3", "body"]}) then { _mn = _mn vectorAdd [0, -ZPI_cfg_soldierBackpack, 0] };
        private _b = [[_u, _mn, _mx] call ZPI_fnc_corners, _basis, _th, _tv] call ZPI_fnc_boxOfPoints;
        if (_b isEqualTo []) exitWith { _ok = false };
        _x0 = _x0 min (_b select 0);
        _y0 = _y0 min (_b select 1);
        _x1 = _x1 max (_b select 2);
        _y1 = _y1 max (_b select 3);
    } forEach _parts;
    if (!_ok) exitWith { [[], ""] };
    [[_x0, _y0, _x1, _y1], _meth]
};

// Model box (vehicles, buildings): the Geometry LOD's box, which is tight around the hull.
// The whole-model box includes invisible helper parts, so it is only the fallback
// for models without a Geometry LOD.
ZPI_fnc_modelBox = {
    params ["_v"];
    private _bb = boundingBoxReal [_v, "Geometry"];
    if (count _bb < 2 || {((_bb select 1) vectorDiff (_bb select 0)) findIf { _x <= 0 } >= 0}) then { _bb = boundingBoxReal _v };
    [_bb select 0, _bb select 1]
};

// Fraction of sample points visible from the camera (terrain, buildings, trees, nets).
ZPI_fnc_visibility = {
    params ["_camASL", "_pts", "_ignore", ["_lod", "VIEW"]];
    if (_pts isEqualTo []) exitWith { 1 };
    private _sum = 0;
    { _sum = _sum + ([_ignore, _lod, objNull] checkVisibility [_camASL, _x]) } forEach _pts;
    _sum / (count _pts)
};

// ---- is a soldier inside a building? -------------------------------------------------
// Inside = standing within the building's footprint AND a ray straight up hits that
// building (a roof over his head). insideBuilding (sound-based) is used as a backup.
ZPI_fnc_insideOf = {
    params ["_u", "_b"];
    private _m = _b worldToModel (ASLToAGL (getPosASL _u));
    private _bb = boundingBoxReal _b;
    private _in = (_m select 0) > ((_bb select 0) select 0) && {(_m select 0) < ((_bb select 1) select 0)}
        && {(_m select 1) > ((_bb select 0) select 1)} && {(_m select 1) < ((_bb select 1) select 1)};
    if (!_in) exitWith { false };
    private _e = eyePos _u;
    private _roof = (lineIntersectsSurfaces [_e, _e vectorAdd [0, 0, 40], _u, objNull, true, 4, "GEOM", "NONE"])
        findIf { (_x select 2) isEqualTo _b || {(_x select 3) isEqualTo _b} } >= 0;
    _roof || {(insideBuilding _u) >= 1}
};

ZPI_fnc_buildingOf = {          // [unit] -> building he is inside, or objNull
    params ["_u"];
    if (!isNull objectParent _u) exitWith { objNull };
    private _res = objNull;
    {
        if ([_u, _x] call ZPI_fnc_insideOf) exitWith { _res = _x };
    } forEach (nearestObjects [_u, ["House", "Building"], 30]);
    _res
};

// Clip, filter and format one box. Returns "" when the box is rejected.
// _g = ground point ASL (feet / terrain under the hull or building / impact point); _meth: soldiers only
ZPI_fnc_finishBox = {
    params ["_kind", "_box", "_id", "_vis", "_W", "_H", "_stance", "_inside", "_g", "_basis", "_th", "_tv", ["_meth", ""]];
    if (_box isEqualTo []) exitWith { "" };
    _box params ["_x0", "_y0", "_x1", "_y1"];
    private _area = (_x1 - _x0) * (_y1 - _y0);
    if (_area <= 0) exitWith { "" };
    private _cx0 = _x0 max 0;
    private _cy0 = _y0 max 0;
    private _cx1 = _x1 min 1;
    private _cy1 = _y1 min 1;
    if (_cx1 <= _cx0 || {_cy1 <= _cy0}) exitWith { "" };            // completely outside
    private _inFrac = ((_cx1 - _cx0) * (_cy1 - _cy0)) / _area;
    if (_inFrac < ZPI_cfg_minInFrame) exitWith { "" };               // mostly outside the image
    if (((_cx1 - _cx0) * _W) < ZPI_cfg_minBoxPx || {((_cy1 - _cy0) * _H) < ZPI_cfg_minBoxPx}) exitWith { "" };
    if (_vis < ZPI_cfg_minVisible) exitWith { "" };
    private _gn = [_g, _basis, _th, _tv] call ZPI_fnc_projectN;
    // fields 13-15: ground point ASL; 16-17: its normalized image position (null when behind the camera)
    // field 18: soldier box method ("v" body bones, "h" hit-point parts, "" one 3D box)
    format ['["%1",%2,%3,%4,%5,%6,%7,%8,"%9",%10,%11,"%12",%13,%14,%15,%16,%17,"%18"]',
        _kind, ((_cx0 + _cx1) / 2) toFixed 5, ((_cy0 + _cy1) / 2) toFixed 5, (_cx1 - _cx0) toFixed 5, (_cy1 - _cy0) toFixed 5,
        _id, _vis toFixed 2, (1 - _inFrac) toFixed 2, _stance, ((_basis select 0) vectorDistance _g) toFixed 1, [0, 1] select _inside, mapGridPosition _g,
        (_g select 0) toFixed 2, (_g select 1) toFixed 2, (_g select 2) toFixed 2,
        ["null", (_gn select 0) toFixed 6] select (_gn isNotEqualTo []), ["null", (_gn select 1) toFixed 6] select (_gn isNotEqualTo []), _meth]
};

ZPI_fnc_computeLabels = {
    private _basis = call ZPI_fnc_camBasis;
    private _cam = _basis select 0;
    private _th = tan (ZPI_hfov / 2);
    private _tv = tan (ZPI_vfov / 2);
    private _res = getResolution;
    private _W = _res select 0;
    private _H = _res select 1;
    private _boxes = [];

    // soldiers and vehicles
    {
        _x params ["_id", "_obj", "_cls"];
        private _kind = ZPI_clsToKind getOrDefault [_cls, ""];       // negatives have no kind
        if (_kind != "" && {!isNull _obj} && {alive _obj} && {(_cam vectorDistance (getPosASL _obj)) < ZPI_cfg_maxLabelDist}) then {
            (if (_kind == "s") then { [_obj] call ZPI_fnc_soldierBox } else { [_obj] call ZPI_fnc_modelBox }) params ["_mn", "_mx"];
            private _box = [[_obj, _mn, _mx] call ZPI_fnc_corners, _basis, _th, _tv] call ZPI_fnc_boxOfPoints;
            private _meth = "";
            if (_kind == "s" && {_box isNotEqualTo []}) then {
                ([_obj, [_mn, _mx], _basis, _th, _tv] call ZPI_fnc_soldierBox2D) params ["_tb", "_tm"];
                if (_tb isNotEqualTo []) then {
                    _box = _tb;
                    _meth = _tm;
                };
            };
            if (_box isNotEqualTo []) then {
                // sample points: center + 4 points around it at 60 % of the box, mid height
                private _c = (_mn vectorAdd _mx) vectorMultiply 0.5;
                private _e = (_mx vectorDiff _mn) vectorMultiply 0.3;
                private _pts = [_c, _c vectorAdd [0, 0, _e select 2]] + ([[1, 1], [1, -1], [-1, 1], [-1, -1]] apply {
                    _c vectorAdd [(_e select 0) * (_x select 0), (_e select 1) * (_x select 1), 0]
                });
                private _vis = [_cam, _pts apply { _obj modelToWorldVisualWorld _x }, _obj] call ZPI_fnc_visibility;
                private _p = getPosASLVisual _obj;
                private _st = if (_kind == "s") then { stance _obj } else { "" };
                private _inside = (_kind == "s") && {!isNull ([_obj] call ZPI_fnc_buildingOf)};
                // ground point: soldier = his feet (floor height inside buildings); vehicle = terrain under the hull centre
                private _g = if (_kind == "s") then { _p } else {
                    private _bc = _obj modelToWorldVisualWorld [_c select 0, _c select 1, _mn select 2];
                    [_bc select 0, _bc select 1, getTerrainHeightASL _bc]
                };
                private _s = [_kind, _box, _id, _vis, _W, _H, _st, _inside, _g, _basis, _th, _tv, _meth] call ZPI_fnc_finishBox;
                if (_s != "") then { _boxes pushBack _s };
            };
        };
    } forEach ZPI_entities;

    {
        _boxes pushBack _x;
    } forEach ([_basis, _th, _tv, _W, _H] call ZPI_fnc_buildingLabels);

    // explosions: approximate fireball + dust column that grows over time.
    // make_yolo_dataset.py replaces it with the measured box when a reference image exists.
    {
        _x params ["_p", "_t0", "_R", "_Hh", "_dur"];
        private _t = time - _t0;
        if (_t > 0.03 && {_t < _dur}) then {
            private _r = _R * ((_t / 0.3) min 1);
            private _h = _Hh * ((_t / 0.8) min 1) max (_r * 1.2);
            private _box = [[_p, _r, -0.5, _h] call ZPI_fnc_worldBoxCorners, _basis, _th, _tv] call ZPI_fnc_boxOfPoints;
            private _vis = [_cam, [_p vectorAdd [0, 0, _h / 2], _p vectorAdd [0, 0, _h]], objNull, "GEOM"] call ZPI_fnc_visibility;
            private _s = ["e", _box, -1, _vis, _W, _H, "", false, _p, _basis, _th, _tv] call ZPI_fnc_finishBox;
            if (_s != "") then { _boxes pushBack _s };
        };
    } forEach ZPI_explosions;

    // gun firing (muzzle blast + smoke in front of the barrel), kind "f". The box is estimated here;
    // make_yolo_dataset.py measures it from the reference picture taken just before the shot.
    {
        _x params ["_p", "_dir", "_t0", "_vid", "_R", "_dur"];
        private _t = time - _t0;
        if (_t >= 0 && {_t < _dur}) then {
            private _r = _R * (0.6 + 0.4 * ((_t / 0.5) min 1));
            private _c = _p vectorAdd (_dir vectorMultiply (_r * 0.7));
            private _box = [[_c, _r, -_r * 0.6, _r * 0.9] call ZPI_fnc_worldBoxCorners, _basis, _th, _tv] call ZPI_fnc_boxOfPoints;
            private _vis = [_cam, [_p, _c], objNull, "GEOM"] call ZPI_fnc_visibility;
            private _s = ["f", _box, _vid, _vis max 0.5, _W, _H, "", false, _p, _basis, _th, _tv] call ZPI_fnc_finishBox;
            if (_s != "") then { _boxes pushBack _s };
        };
    } forEach ZPI_firings;

    _boxes
};

// ---- buildings ---------------------------------------------------------------------
ZPI_bldTypes = ["BUILDING", "CHAPEL", "CHURCH", "FUELSTATION", "HOSPITAL", "HOUSE"];
ZPI_bldSkip  = ["wall", "fence", "ruin", "pier", "sign", "lamp", "pole", "wreck", "gate", "pipe", "dam_", "bridge"];

// Ground area seen by the camera: where the 4 image-corner rays hit the ground
// (flat ground at the height below the image center). -> [center, radius]
ZPI_fnc_viewFootprint = {
    params ["_basis", "_th", "_tv"];
    _basis params ["_o", "_r", "_u", "_f"];
    private _gz = if (ZPI_laserRange > 0) then { ZPI_laserPos select 2 } else { (getTerrainHeightASL _o) max 0 };
    private _pts = [];
    {
        private _d = vectorNormalized ((_f vectorAdd (_r vectorMultiply ((_x select 0) * _th))) vectorAdd (_u vectorMultiply ((_x select 1) * _tv)));
        private _t = if ((_d select 2) < -0.02) then { ((_gz - (_o select 2)) / (_d select 2)) min 2500 } else { 2500 };
        _pts pushBack (_o vectorAdd (_d vectorMultiply _t));
    } forEach [[-1, -1], [1, -1], [1, 1], [-1, 1]];
    private _c = [0, 0, 0];
    { _c = _c vectorAdd _x } forEach _pts;
    _c = _c vectorMultiply 0.25;
    private _rad = 0;
    { _rad = _rad max (_c distance2D _x) } forEach _pts;
    [[_c select 0, _c select 1, _gz], (_rad + 30) min 1500]
};

ZPI_fnc_buildingLabels = {
    params ["_basis", "_th", "_tv", "_W", "_H"];
    private _cam = _basis select 0;
    ([_basis, _th, _tv] call ZPI_fnc_viewFootprint) params ["_c", "_rad"];
    private _out = [];
    {
        private _b = _x;
        if ([_b] call ZPI_fnc_isLabelBuilding) then {
            ([_b] call ZPI_fnc_modelBox) params ["_mn", "_mx"];

            private _corners = [_b, _mn, _mx] call ZPI_fnc_corners;
            {
                private _p = _corners select _x;
                _p set [2, (_p select 2) max (getTerrainHeightASL _p)];
            } forEach [0, 2, 4, 6];
            private _box = [_corners, _basis, _th, _tv] call ZPI_fnc_boxOfPoints;

            // cheap checks first: inside the picture and big enough
            if (_box isNotEqualTo []
                && {(((_box select 2) min 1) - ((_box select 0) max 0)) * _W >= ZPI_cfg_minBoxPx}
                && {(((_box select 3) min 1) - ((_box select 1) max 0)) * _H >= ZPI_cfg_minBoxPx}) then {
                private _mid = (_mn vectorAdd _mx) vectorMultiply 0.5;
                private _q = (_mx vectorDiff _mn) vectorMultiply 0.3;
                private _pts = [_mid, [_mid select 0, _mid select 1, (_mx select 2) - 0.3]] + ([[1, 1], [1, -1], [-1, 1], [-1, -1]] apply {
                    _mid vectorAdd [(_q select 0) * (_x select 0), (_q select 1) * (_x select 1), (_q select 2)]
                });
                private _vis = [_cam, _pts apply { _b modelToWorldVisualWorld _x }, _b] call ZPI_fnc_visibility;
                private _bc = _b modelToWorldVisualWorld [_mid select 0, _mid select 1, _mn select 2];
                private _g = [_bc select 0, _bc select 1, getTerrainHeightASL _bc];
                private _s = ["b", _box, -2, _vis, _W, _H, "", false, _g, _basis, _th, _tv] call ZPI_fnc_finishBox;
                if (_s != "") then { _out pushBack _s };
            };
        };
    } forEach (nearestTerrainObjects [_c, ZPI_bldTypes, _rad, false, true]);
    _out
};

// How many buildings would get a box in a picture taken right now (generator limit).
ZPI_fnc_buildingsInView = {
    private _res = getResolution;
    count ([call ZPI_fnc_camBasis, tan (ZPI_hfov / 2), tan (ZPI_vfov / 2), _res select 0, _res select 1] call ZPI_fnc_buildingLabels)
};

// ---- geometry records for localisation -----------------------------------
// Check of the camera model: for up to 4 scene objects, our pinhole projection of the
// ground point vs the engine's own worldToScreen, in pixels [du, dv]. Should be ~0.
ZPI_fnc_projCheck = {
    params ["_basis", "_th", "_tv", "_W", "_H"];
    private _out = [];
    {
        private _o = _x select 1;
        if (count _out < 4 && {!isNull _o}) then {
            private _g = getPosASLVisual _o;
            private _pn = [_g, _basis, _th, _tv] call ZPI_fnc_projectN;
            private _ws = worldToScreen (ASLToAGL _g);
            if (_pn isNotEqualTo [] && {count _ws == 2} && {(_pn select 0) > 0} && {(_pn select 0) < 1} && {(_pn select 1) > 0} && {(_pn select 1) < 1}) then {
                private _wu = ((_ws select 0) - safeZoneX) / safeZoneW;
                private _wv = ((_ws select 1) - safeZoneY) / safeZoneH;
                _out pushBack format ["[%1,%2]", (((_pn select 0) - _wu) * _W) toFixed 2, (((_pn select 1) - _wv) * _H) toFixed 2];
            };
        };
    } forEach ZPI_entities;
    "[" + (_out joinString ",") + "]"
};

// Terrain heights (getTerrainHeightASL) on a regular grid over the ground seen in the
// picture (+ margin), at most 33 x 33 points, 2 m spacing or coarser.
// ZPI|dem| {"image","part","parts","x0","y0","d","nx","ny","row0","h":[[row row0], [row0+1], ...]}
// h[j][i] = height at (x0 + i*d, y0 + j*d), metres ASL.
ZPI_fnc_logTerrain = {
    params ["_img", "_basis", "_th", "_tv"];
    _basis params ["_o", "_r", "_u", "_f"];
    private _hits = [];
    {
        private _d = vectorNormalized ((_f vectorAdd (_r vectorMultiply ((_x select 0) * _th))) vectorAdd (_u vectorMultiply ((_x select 1) * _tv)));
        private _t = terrainIntersectAtASL [_o, _o vectorAdd (_d vectorMultiply 6000)];
        if (_t isNotEqualTo [0, 0, 0]) then { _hits pushBack _t };
    } forEach [[-1, -1], [1, -1], [1, 1], [-1, 1], [0, 0], [0, -1], [0, 1], [-1, 0], [1, 0]];
    if (_hits isEqualTo [] && {ZPI_laserRange > 0}) then { _hits = [ZPI_laserPos] };
    if (_hits isEqualTo []) exitWith {};
    private _xs = _hits apply { _x select 0 };
    private _ys = _hits apply { _x select 1 };
    private _x0 = selectMin _xs;
    private _x1 = selectMax _xs;
    private _y0 = selectMin _ys;
    private _y1 = selectMax _ys;
    private _m = ((((_x1 - _x0) max (_y1 - _y0)) * 0.1) max 10);
    _x0 = _x0 - _m;
    _x1 = _x1 + _m;
    _y0 = _y0 - _m;
    _y1 = _y1 + _m;
    private _d = ((((_x1 - _x0) max (_y1 - _y0)) / 32) max 2);
    private _nx = (ceil ((_x1 - _x0) / _d) + 1) min 33;
    private _ny = (ceil ((_y1 - _y0) / _d) + 1) min 33;
    private _per = 2;                                    // rows per log line (keeps lines under ~700 characters)
    private _parts = ceil (_ny / _per);
    for "_k" from 0 to (_parts - 1) do {
        private _rows = [];
        for "_j" from (_k * _per) to (((_k + 1) * _per - 1) min (_ny - 1)) do {
            private _y = _y0 + _j * _d;
            private _row = [];
            for "_i" from 0 to (_nx - 1) do { _row pushBack ((getTerrainHeightASL [_x0 + _i * _d, _y]) toFixed 2) };
            _rows pushBack ("[" + (_row joinString ",") + "]");
        };
        ["dem", format ['{"image":"%1","part":%2,"parts":%3,"x0":%4,"y0":%5,"d":%6,"nx":%7,"ny":%8,"row0":%9,"h":[%10]}',
            _img, _k, _parts, _x0 toFixed 2, _y0 toFixed 2, _d toFixed 3, _nx, _ny, _k * _per, _rows joinString ","]] call ZPI_fnc_emit;
    };
};

// What the camera really sees through 9 x 5 image points (first surface on the ray:
// ground, roof, tree, vehicle ...). Ground truth for "pixel -> world" incl. roofs.
// ZPI|ray| {"image","part","parts","rays":[[u, v, x, y, z, kind, objectId], ...]}
// u, v normalized image position; kind: g ground, b building, t tree/bush, e scene object, o other
ZPI_fnc_logRays = {
    params ["_img", "_basis", "_th", "_tv"];
    _basis params ["_o", "_r", "_u", "_f"];
    private _rays = [];
    for "_j" from 0 to 4 do {
        for "_i" from 0 to 8 do {
            private _un = (_i + 0.5) / 9;
            private _vn = (_j + 0.5) / 5;
            private _d = vectorNormalized ((_f vectorAdd (_r vectorMultiply ((2 * _un - 1) * _th))) vectorAdd (_u vectorMultiply ((1 - 2 * _vn) * _tv)));
            private _hit = lineIntersectsSurfaces [_o, _o vectorAdd (_d vectorMultiply 6000), objNull, objNull, true, 1, "VIEW", "GEOM"];
            if (_hit isNotEqualTo []) then {
                (_hit select 0) params ["_pos", "_nrm", "_obj", "_par"];
                private _ob = if (isNull _par) then { _obj } else { _par };
                private _id = -1;
                private _kind = "o";
                if (isNull _ob) then { _kind = "g" } else {
                    _id = _ob getVariable ["ZPI_id", -1];
                    private _mdl = toLower ((getModelInfo _ob) select 0);
                    _kind = switch (true) do {
                        case (_id >= 0): { "e" };
                        case ((_mdl find "t_") == 0 || {(_mdl find "b_") == 0}): { "t" };
                        case ([_ob] call ZPI_fnc_isLabelBuilding): { "b" };
                        default { "o" };
                    };
                };
                _rays pushBack format ['[%1,%2,%3,%4,%5,"%6",%7]', _un toFixed 4, _vn toFixed 4,
                    (_pos select 0) toFixed 2, (_pos select 1) toFixed 2, (_pos select 2) toFixed 2, _kind, _id];
            };
        };
    };
    private _per = 12;
    private _parts = ceil ((count _rays) / _per);
    for "_k" from 0 to (_parts - 1) do {
        ["ray", format ['{"image":"%1","part":%2,"parts":%3,"rays":[%4]}', _img, _k, _parts, (_rays select [_k * _per, _per]) joinString ","]] call ZPI_fnc_emit;
    };
};

// ---- capture state machine ---------------------------------------------------------
ZPI_burstId  = 0;                // burst counter (generator); pictures of one burst share the camera
ZPI_burstIdx = -1;               // index inside the current burst, -1 = not in a burst
ZPI_burstLen = 0;
ZPI_fnc_startCapture = {
    if (ZPI_frozen) exitWith {};
    ZPI_frozen = true;
    ZPI_capFrozenEntities = [];
    {
        private _o = _x select 1;
        if (!isNull _o && {simulationEnabled _o} && {(vectorMagnitude (velocity _o)) > 0.05 || {!(_o isKindOf "Man")} || {!(isNull (objectParent _o))}}) then {
            _o enableSimulation false;
            ZPI_capFrozenEntities pushBack _o;
        };
    } forEach ZPI_entities;
};

ZPI_fnc_doCapture = {
    ZPI_shotCount = ZPI_shotCount + 1;
    // burst pictures (same camera position) share a name prefix: <scene>_b<burst>_<n>_<frame>
    private _file = if (ZPI_burstIdx >= 0) then {
        format ["%1_b%2_%3_%4.png", ZPI_sceneName, [ZPI_burstId, 4] call ZPI_fnc_pad, ZPI_burstIdx + 1, [diag_frameNo, 8] call ZPI_fnc_pad]
    } else {
        format ["%1_%2.png", ZPI_sceneName, [diag_frameNo, 8] call ZPI_fnc_pad]
    };
    private _img = format ["zpi/%1/%2", ZPI_sessionTag, _file];
    private _boxes = call ZPI_fnc_computeLabels;
    private _ok = screenshot _img;
    private _basis = call ZPI_fnc_camBasis;
    _basis params ["_o", "_r", "_u", "_f"];
    // attitude from the rendered camera axes (heading 0 = north, pitch < 0 = down, bank = roll)
    private _hdg   = ((_f select 0) atan2 (_f select 1) + 360) mod 360;
    private _pitch = asin (((_f select 2) max -1) min 1);
    private _bank  = (_r select 2) atan2 (_u select 2);
    private _gz = (getTerrainHeightASL _o) max 0;
    private _res = getResolution;
    private _W = _res select 0;
    private _H = _res select 1;
    private _th = tan (ZPI_hfov / 2);
    private _tv = tan (ZPI_vfov / 2);
    private _n = ZPI_cfg_labelsPerLine;
    private _parts = (ceil ((count _boxes) / _n)) max 1;

    ["shot", format ['{"image":"%1","ok":%2,"frame":%3,"t_game":%4,"parts":%5,"res":[%6,%7],"cam":{"pos_asl":%8,"x_axis":%9,"y_axis":%10,"z_axis":%11,"hfov":%12,"vfov":%13,"hdg":%14,"pitch":%15,"alt_asl":%16,"alt_agl":%17,"grid":"%18","bank":%19,"fx":%20,"fy":%21,"proj_check_px":%22}}',
        _img, _ok, diag_frameNo toFixed 0, time toFixed 3, _parts, _W, _H,
        [_o, 3] call ZPI_fnc_v3, [_r, 7] call ZPI_fnc_v3, [_u, 7] call ZPI_fnc_v3, [_f, 7] call ZPI_fnc_v3,
        ZPI_hfov toFixed 6, ZPI_vfov toFixed 6, _hdg toFixed 4, _pitch toFixed 4, (_o select 2) toFixed 2, ((_o select 2) - _gz) toFixed 2,
        mapGridPosition [_o select 0, _o select 1], _bank toFixed 4,
        ((_W / 2) / _th) toFixed 2, ((_H / 2) / _tv) toFixed 2,
        [_basis, _th, _tv, _W, _H] call ZPI_fnc_projCheck]] call ZPI_fnc_emit;

    private _laser = if (ZPI_laserRange > 0) then {
        format ['{"range":%1,"pos_asl":%2,"grid":"%3","hit":"%4"}', ZPI_laserRange toFixed 2, [ZPI_laserPos, 2] call ZPI_fnc_v3,
            mapGridPosition [ZPI_laserPos select 0, ZPI_laserPos select 1], ZPI_laserObj]
    } else { "null" };
    private _ref = if (ZPI_camLock && {ZPI_refImage != ""}) then { ZPI_refImage } else { "" };
    ["shotx", format ['{"image":"%1","scene":"%2","seed":%3,"region":%4,"world":"%5","laser":%6,"time_label":"%7","daytime":%8,"weather":"%9","scale_lock":%10,"target_gsd":%11,"ref_image":"%12","occupancy":%13,"burst":%14,"burst_idx":%15,"burst_len":%16,"surface":"%17","fog":%18,"overcast":%19,"aperture":%20,"stage":"%21"}',
        _img, ZPI_sceneName, ZPI_cfg_seed, ZPI_regionId, worldName, _laser,
        (ZPI_timePresets select ZPI_timeIndex) select 2, dayTime toFixed 3, (ZPI_weatherPresets select ZPI_weatherIndex) select 0,
        ZPI_scaleLock, ZPI_targetGSD toFixed 4, _ref, call ZPI_fnc_occupancyJson,
        [-1, ZPI_burstId] select (ZPI_burstIdx >= 0), ZPI_burstIdx, ZPI_burstLen,
        if (ZPI_laserRange > 0) then { surfaceType ZPI_laserPos } else { "" },
        str fogParams, overcast toFixed 3, apertureParams select 0, ZPI_tourStage]] call ZPI_fnc_emit;

    [_img, _basis, _th, _tv] call ZPI_fnc_logTerrain;   // DEM patch under the view
    [_img, _basis, _th, _tv] call ZPI_fnc_logRays;      // what each of 9 x 5 image points really hits
    for "_k" from 0 to (_parts - 1) do {
        ["label", format ['{"image":"%1","part":%2,"parts":%3,"boxes":[%4]}',
            _img, _k, _parts, (_boxes select [_k * _n, _n]) joinString ","]] call ZPI_fnc_emit;
    };
    if (_ok) then {
        [format ["Shot %1: %2 boxes%3", ZPI_shotCount, count _boxes, ["", " (+ reference)"] select (_ref != "")]] call ZPI_fnc_msg;
    } else {
        ["Screenshot FAILED: set HDR quality to standard or check the Screenshots folder size limit"] call ZPI_fnc_msg;
    };
};

ZPI_fnc_unfreeze = {
    { if (!isNull _x) then { _x enableSimulation true } } forEach ZPI_capFrozenEntities;
    ZPI_capFrozenEntities = [];
    ZPI_frozen = false;
    ZPI_mouseDX = 0;                 // drop mouse movement made during the freeze
    ZPI_mouseDY = 0;
};

ZPI_fnc_captureTick = {
    // prune finished effects
    ZPI_explosions = ZPI_explosions select { (time - (_x select 1)) < (_x select 4) };
    ZPI_firings = ZPI_firings select { (time - (_x select 2)) < (_x select 5) };
    // a held camera is released when its explosion never came
    if (ZPI_camLock && {ZPI_refImage != ""} && {time > ZPI_refUntil} && {!ZPI_frozen}) then { call ZPI_fnc_releaseRef };

    if (ZPI_frozen) then {
        if (!ZPI_capTaken) then {
            // frozen since last frame: what is rendered now matches the frozen state
            call ZPI_fnc_doCapture;
            ZPI_capTaken = true;
        } else {
            // the screenshot is saved when its frame is rendered: nothing may move or teleport before that
            ZPI_capTaken = false;
            call ZPI_fnc_unfreeze;
            if (ZPI_refImage != "") then { call ZPI_fnc_releaseRef };
        };
    } else {
        if (ZPI_pendingCapture >= 0 && {time >= ZPI_pendingCapture}) exitWith {
            ZPI_pendingCapture = -1;
            call ZPI_fnc_startCapture;
        };
        if (ZPI_autoCapture && {!ZPI_camLock} && {time >= ZPI_nextAuto}) then {
            ZPI_nextAuto = time + ZPI_autoInterval;
            call ZPI_fnc_startCapture;
        };
    };
};

ZPI_fnc_toggleAuto = {
    ZPI_autoCapture = !ZPI_autoCapture;
    ZPI_nextAuto = time;
    [["Auto-capture OFF", format ["Auto-capture ON (every %1 s)", ZPI_autoInterval]] select ZPI_autoCapture] call ZPI_fnc_msg;
};

// ---- explosion reference pictures ---------------------------------------------------
// Right before a shell lands, the camera and zoom are held still and a reference
// picture is taken. The explosion picture is then taken from exactly the same view,
// so make_yolo_dataset.py can box what changed (fireball, dust, debris).
ZPI_refImage = "";
ZPI_refUntil = 0;

// Scheduled code only (waits one frame so the held view is what gets rendered).
ZPI_fnc_takeRef = {             // [impact posASL] -> true if a reference was taken
    params ["_target"];
    if (!ZPI_cfg_explosionRefShots || {!ZPI_eventCapture} || {ZPI_camLock} || {ZPI_frozen}
        || {ZPI_pendingCapture >= 0} || {ZPI_orthoRunning} || {!([_target] call ZPI_fnc_onScreen)}) exitWith { false };
    ZPI_camLock = true;
    ZPI_fovLock = true;
    private _f0 = diag_frameNo;
    waitUntil { diag_frameNo > _f0 };
    private _img = format ["zpi/%1/ref_%2.png", ZPI_sessionTag, [diag_frameNo, 8] call ZPI_fnc_pad];
    if (!(screenshot _img)) exitWith {
        ZPI_camLock = false;
        ZPI_fovLock = false;
        false
    };
    ZPI_refImage = _img;
    ZPI_refUntil = time + ZPI_cfg_refTimeout;
    true
};

ZPI_fnc_releaseRef = {
    ZPI_refImage = "";
    ZPI_camLock = false;
    ZPI_fovLock = false;
    ZPI_mouseDX = 0;
    ZPI_mouseDY = 0;
};

// ---- explosions feed the label list -----------------------------------------------------
ZPI_fnc_addExplosion = {
    params ["_pos", "_size", ["_id", -1]];          // _size = [radius, height, duration]
    ZPI_explosions pushBack ([_pos, time] + _size);
    if (ZPI_cfg_captureOnExplosion && {[_pos] call ZPI_fnc_onScreen}) then { [ZPI_cfg_expCaptureDelay] call ZPI_fnc_requestEventCapture };
    ["explosion", format ['{"id":%1,"cls":"explosion","pos_asl":%2,"radius":%3,"height":%4}',
        _id, [_pos, 2] call ZPI_fnc_v3, _size select 0, _size select 1]] call ZPI_fnc_event;
};

ZPI_fnc_addFiring = {
    params ["_p", "_dir", "_veh", "_hit"];
    if ((vectorMagnitude _dir) < 0.5) then { _dir = vectorDir _veh };
    private _R = [ZPI_cfg_fireSize select 0, ZPI_cfg_fireSize select 1] select (_hit >= 150);   // big cannon / autocannon
    private _id = _veh getVariable ["ZPI_id", -1];
    ZPI_firings pushBack [_p, _dir, time, _id, _R, ZPI_cfg_fireDuration];
    if (ZPI_cfg_captureOnFiring && {[_p] call ZPI_fnc_onScreen}) then {
        ZPI_nextEventCapture = 0;                         // a firing picture always gets taken
        [ZPI_cfg_fireCaptureDelay] call ZPI_fnc_requestEventCapture;
    };
    ["firing", format ['{"vehicle_id":%1,"class":"%2","muzzle_asl":%3,"dir":%4,"hit":%5}',
        _id, typeOf _veh, [_p, 2] call ZPI_fnc_v3, [_dir, 4] call ZPI_fnc_v3, _hit]] call ZPI_fnc_event;
};

ZPI_fnc_explosionSize = {        // from the ammo config: [radius, height, duration]
    params ["_ammo"];
    private _hit = getNumber (configFile >> "CfgAmmo" >> _ammo >> "hit");
    if (_hit >= 300) exitWith { ZPI_cfg_expLarge };
    if (_hit >= 100) exitWith { ZPI_cfg_expMedium };
    ZPI_cfg_expSmall
};

// "Fired" handler, attached to every spawned soldier and vehicle.
ZPI_fnc_onFired = {
    params ["_unit", "_weapon", "_muzzle", "_mode", "_ammo", "_magazine", "_projectile"];
    _unit setVariable ["ZPI_firedAt", time];
    if (isNull _projectile) exitWith {};
    private _cfg = configFile >> "CfgAmmo" >> _ammo;
    // a vehicle's main gun (tank cannon, autocannon): label the muzzle blast and take a picture
    if (!(_unit isKindOf "Man") && {(getNumber (_cfg >> "hit")) >= ZPI_cfg_fireMinHit}) then {
        [getPosASLVisual _projectile, vectorNormalized (velocity _projectile), _unit, getNumber (_cfg >> "hit")] call ZPI_fnc_addFiring;
    };
    if ((getNumber (_cfg >> "explosive")) > 0 && {(getNumber (_cfg >> "indirectHit")) >= 4}) then {
        _projectile setVariable ["ZPI_expSize", [_ammo] call ZPI_fnc_explosionSize];
        _projectile addEventHandler ["Explode", {
            params ["_proj", "_pos"];
            [_pos, _proj getVariable ["ZPI_expSize", ZPI_cfg_expSmall]] call ZPI_fnc_addExplosion;
        }];
    };
};

// ---- automatic captures on explosions ---------------------------------------------------
ZPI_pendingCapture   = -1;
ZPI_nextEventCapture = 0;
ZPI_eventCapture     = true;    // I toggles

ZPI_fnc_onScreen = {            // [posASL] -> inside the picture and not too far
    params ["_p"];
    if ((ZPI_camPosASL vectorDistance _p) > ZPI_cfg_maxLabelDist) exitWith { false };
    // worldToScreen also returns coordinates for points outside the picture: check the edges
    private _s = worldToScreen (ASLToAGL _p);
    count _s == 2 && {(_s select 0) > safeZoneX} && {(_s select 0) < safeZoneX + safeZoneW}
        && {(_s select 1) > safeZoneY} && {(_s select 1) < safeZoneY + safeZoneH}
};

ZPI_fnc_requestEventCapture = {
    params ["_delay"];
    if (!ZPI_eventCapture || {time < ZPI_nextEventCapture} || {ZPI_pendingCapture >= 0}) exitWith {};
    ZPI_pendingCapture = time + _delay;
    ZPI_nextEventCapture = time + ZPI_cfg_eventCaptureGap;
};

ZPI_fnc_toggleEventCapture = {
    ZPI_eventCapture = !ZPI_eventCapture;
    [["Auto-shot on explosions: OFF", "Auto-shot on explosions: ON"] select ZPI_eventCapture] call ZPI_fnc_msg;
};

// ---- firing ----------------------------------------------------------------------------
// Everything shoots at empty ground (at least ZPI_cfg_barrageMinClear m from any scene
// object), so the shells explode inside the picture. Everything is invulnerable anyway.
ZPI_firefight = false;

ZPI_fnc_fireTarget = {          // [unit, dMin, dMax] -> clear ground point, ASL
    params ["_u", "_dMin", "_dMax"];
    private _o = getPosATL _u;
    private _best = [];
    for "_t" from 1 to 40 do {
        private _spread = [70, 180] select (_t > 20);           // first try in front, then anywhere
        private _p = _o getPos [_dMin + random (_dMax - _dMin), (getDir _u) - _spread + random (2 * _spread)];
        private _clear = (ZPI_entities findIf { !isNull (_x select 1) && {((_x select 1) distance2D _p) < ZPI_cfg_barrageMinClear} }) == -1;
        if (_clear && {!surfaceIsWater _p}) exitWith { _best = _p };
    };
    if (_best isEqualTo []) then { _best = _o getPos [_dMax, getDir _u] };
    [_best select 0, _best select 1, getTerrainHeightASL _best]
};

// All (weapon, muzzle, fire mode) combinations of the main turret, main gun first.
ZPI_fnc_fireOptions = {
    params ["_v"];
    private _out = [];
    {
        private _w = _x;
        private _lw = toLower _w;
        if (({ (_lw find _x) >= 0 } count ["horn", "smoke", "flare", "laser", "cmflare"]) == 0) then {
            private _cfg = configFile >> "CfgWeapons" >> _w;
            private _muzzles = (getArray (_cfg >> "muzzles")) apply { [_x, _w] select (_x == "this") };
            if (_muzzles isEqualTo []) then { _muzzles = [_w] };
            {
                private _m = _x;
                private _mcfg = [_cfg >> _m, _cfg] select (_m == _w);
                private _modes = (getArray (_mcfg >> "modes")) apply { [_x, _m] select (_x == "this") };
                if (_modes isEqualTo []) then { _modes = [_m] };
                _out pushBack [_w, _m, _modes select 0];
            } forEach _muzzles;
        };
    } forEach (_v weaponsTurret [0]);
    _out
};

// One attempt with one method; true when the Fired handler confirms a shot.
ZPI_fnc_tryFire = {
    params ["_v", "_g", "_opt", "_method"];
    _opt params ["_w", "_m", "_mode"];
    private _t0 = time;
    _v selectWeaponTurret [_w, [0]];
    switch (_method) do {
        case 0: { [_v, _m, [0]] call BIS_fnc_fire };
        case 1: { _g forceWeaponFire [_m, _mode] };
        default { _v fire _m };
    };
    sleep 0.3;
    (_v getVariable ["ZPI_firedAt", -1]) >= _t0
};

// Spawned per vehicle: aim at clear ground, then fire _shots rounds (waits through reloads).
ZPI_fnc_vehFire = {
    params ["_v", "_shots"];
    _v setVariable ["ZPI_busy", true];
    if (isNull (gunner _v)) then {
        createVehicleCrew _v;
        { _x allowDamage false } forEach (crew _v);
        ZPI_sceneGroups pushBackUnique (group (effectiveCommander _v));
    };
    private _g = gunner _v;
    if (isNull _g) exitWith {
        diag_log format ["ZPI|warn|%1 has no gunner seat, cannot fire", typeOf _v];
        _v setVariable ["ZPI_busy", false];
    };
    private _grp = group _g;
    _grp setCombatMode "YELLOW";
    private _tgt = [_v, ZPI_cfg_fireRange select 0, ZPI_cfg_fireRange select 1] call ZPI_fnc_fireTarget;
    _g doWatch (ASLToAGL _tgt);
    sleep ZPI_cfg_turretTurnTime;

    // find (once per vehicle) a weapon + method that really fires, then reuse it
    private _plan = _v getVariable ["ZPI_firePlan", []];
    private _fired = 0;
    if (_plan isEqualTo []) then {
        {
            private _opt = _x;
            for "_method" from 0 to 2 do {
                waitUntil { !ZPI_frozen };
                if ([_v, _g, _opt, _method] call ZPI_fnc_tryFire) exitWith { _plan = [_opt, _method]; _fired = 1 };
            };
            if (_plan isNotEqualTo []) exitWith {};
        } forEach ([_v] call ZPI_fnc_fireOptions);
        if (_plan isEqualTo []) then {
            _plan = ["none"];
            diag_log format ["ZPI|warn|%1: no weapon could be fired (%2)", typeOf _v, _v weaponsTurret [0]];
        };
        _v setVariable ["ZPI_firePlan", _plan];
    };
    if (_plan isNotEqualTo ["none"]) then {
        _plan params ["_opt", "_method"];
        private _deadline = time + 6 + 8 * _shots;           // tank guns reload in several seconds
        while { _fired < _shots && {time < _deadline} && {alive _v} } do {
            waitUntil { !ZPI_frozen };
            // the flash and flames of the previous shot must be gone before the reference picture
            waitUntil {
                sleep 0.1;
                time > (_v getVariable ["ZPI_firedAt", -10]) + 2
            };
            // hold the camera for the measured picture: the impact if it is in view, else the firing tank
            if !([_tgt] call ZPI_fnc_takeRef) then { [getPosASL _v] call ZPI_fnc_takeRef };
            if ([_v, _g, _opt, _method] call ZPI_fnc_tryFire) then {
                _fired = _fired + 1;
                sleep (0.8 + random 1.5)
            } else { sleep 0.4 };
        };
    };
    _g doWatch objNull;
    _grp setCombatMode "BLUE";
    _v setVariable ["ZPI_busy", false];
};

// One volley: some vehicles and some soldiers open fire. Returns [vehicles, soldiers].
ZPI_fnc_volley = {
    params [["_nVeh", ZPI_cfg_vehShootersMax], ["_nSol", ZPI_cfg_shootersMax]];
    private _veh = (ZPI_entities select {
        private _o = _x select 1;
        (_x select 2) in ["tracked_vehicle", "wheeled_vehicle"] && {alive _o} && {!(_o getVariable ["ZPI_busy", false])}
        && {(_o getVariable ["ZPI_firePlan", []]) isNotEqualTo ["none"]} && {(_o weaponsTurret [0]) isNotEqualTo []}
    }) apply { _x select 1 };
    _veh = (_veh call BIS_fnc_arrayShuffle) select [0, _nVeh];
    { [_x, ZPI_cfg_vehShots] spawn ZPI_fnc_vehFire } forEach _veh;

    private _men = (ZPI_entities select { (_x select 2) == "soldier" && {alive (_x select 1)} && {isNull objectParent (_x select 1)} }) apply { _x select 1 };
    _men = (_men call BIS_fnc_arrayShuffle) select [0, _nSol];
    {
        (group _x) setCombatMode "YELLOW";
        _x doSuppressiveFire ([_x, 80, 200] call ZPI_fnc_fireTarget);
    } forEach _men;
    ["shoot", format ['{"soldiers":%1,"vehicles":%2}', count _men, count _veh]] call ZPI_fnc_event;
    [count _veh, count _men]
};

// Shift+K: one volley
ZPI_fnc_shoot = {
    (call ZPI_fnc_volley) params ["_nv", "_ns"];
    [format ["Firing: %1 vehicles (aiming, first shot in ~%2 s), %3 soldiers", _nv, ZPI_cfg_turretTurnTime, _ns]] call ZPI_fnc_msg;
};

// K: firefight on/off - a new volley every ZPI_cfg_fireInterval seconds
ZPI_fnc_toggleFirefight = {
    ZPI_firefight = !ZPI_firefight;
    if (ZPI_firefight) then {
        ["Firefight ON (K to stop)"] call ZPI_fnc_msg;
        [] spawn {
            while { ZPI_firefight } do {
                if (!ZPI_frozen && {ZPI_entities isNotEqualTo []}) then { call ZPI_fnc_volley };
                sleep ZPI_cfg_fireInterval;
            };
        };
    } else {
        ["Firefight OFF"] call ZPI_fnc_msg;
    };
};
