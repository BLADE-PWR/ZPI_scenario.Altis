// =====================================================================
//  ZPI scene pack - camera, FOV, per-frame loop,
//  telemetry and ground-truth logging, frame-number bar
//
//  The camera pose is set directly every frame (setPosASL +
//  setVectorDirAndUp).
// =====================================================================

ZPI_frozen      = false;   // true while a capture is being taken
ZPI_camLock     = false;   // camera pose held still (explosion reference shots, orthophoto)
ZPI_fovLock     = false;   // zoom held still (explosion reference shots)

// laser rangefinder: first surface in the middle of the screen
ZPI_laserRange  = -1;      // m, -1 = nothing hit (sky)
ZPI_laserPos    = [];      // ASL
ZPI_laserObj    = "";      // what was hit ("" = terrain)

// constant pixel size (R)
ZPI_scaleLock   = true;
ZPI_targetGSD   = ZPI_cfg_targetGSD;

ZPI_hfov        = -1;      // horizontal FOV, deg
ZPI_vfov        = -1;      // vertical FOV, deg

// pose
ZPI_camPosASL   = [0, 0, 0];
ZPI_camDir      = [0, 1, 0];
ZPI_camUp       = [0, 0, 1];

// camera state
ZPI_yaw         = 0;       // deg, compass
ZPI_pitch       = -30;     // deg, negative = looking down
ZPI_camVel      = [0, 0, 0];
ZPI_mouseDX     = 0;
ZPI_mouseDY     = 0;
ZPI_keysDown    = createHashMap;

// ---- helpers ----------------------------------------------------------------
ZPI_fnc_dirFromYawPitch = {
    params ["_y", "_p"];
    [(sin _y) * (cos _p), (cos _y) * (cos _p), sin _p]
};

ZPI_fnc_upFromYawPitch = {      // camera up vector, no roll
    params ["_y", "_p"];
    [-(sin _y) * (sin _p), -(cos _y) * (sin _p), cos _p]
};

ZPI_fnc_applyCamPose = {
    ZPI_cam setPosASL ZPI_camPosASL;
    ZPI_cam setVectorDirAndUp [ZPI_camDir, ZPI_camUp];
};

// ---- camera ------------------------------------------------------------------
// WASD move, E/Q up/down, Shift = fast, mouse = look, wheel = zoom, arrows = look.
ZPI_fnc_keyHeld = {
    params ["_dik"];
    ZPI_keysDown getOrDefault [_dik, false]
};

ZPI_fnc_updateCam = {
    params ["_dt"];
    private _fovScale = tan (ZPI_hfov / 2) / tan (30);
    // yaw = pan (cos pitch, moves the image sideways, scales with FOV) + roll (sin pitch, rotates it around the centre,
    // doesn't scale): pan and roll are perpendicular motions, so they add like the two sides of a right triangle
    private _yawScale = 1 / sqrt ((cos ZPI_pitch / _fovScale)^2 + (sin ZPI_pitch)^2);

    // look: mouse deltas + arrow keys, scaled by FOV so zoomed views stay controllable
    ZPI_yaw   = ZPI_yaw + ZPI_mouseDX * ZPI_cfg_mouseSens * _yawScale;
    ZPI_pitch = ZPI_pitch - ZPI_mouseDY * ZPI_cfg_mouseSens * _fovScale;
    ZPI_mouseDX = 0;
    ZPI_mouseDY = 0;
    private _rate = ZPI_cfg_keyLookRate * _dt;
    if ([203] call ZPI_fnc_keyHeld) then { ZPI_yaw = ZPI_yaw - _rate * _yawScale };       // Left
    if ([205] call ZPI_fnc_keyHeld) then { ZPI_yaw = ZPI_yaw + _rate * _yawScale };       // Right
    if ([200] call ZPI_fnc_keyHeld) then { ZPI_pitch = ZPI_pitch + _rate * _fovScale };   // Up
    if ([208] call ZPI_fnc_keyHeld) then { ZPI_pitch = ZPI_pitch - _rate * _fovScale };   // Down
    ZPI_yaw   = (ZPI_yaw + 360) mod 360;
    ZPI_pitch = (ZPI_pitch max -89.5) min 89.5;

    // move: input in (right, forward, up), speed grows with height above ground
    private _in = [0, 0, 0];
    if ([17] call ZPI_fnc_keyHeld) then { _in set [1, (_in select 1) + 1] };   // W
    if ([31] call ZPI_fnc_keyHeld) then { _in set [1, (_in select 1) - 1] };   // S
    if ([32] call ZPI_fnc_keyHeld) then { _in set [0, (_in select 0) + 1] };   // D
    if ([30] call ZPI_fnc_keyHeld) then { _in set [0, (_in select 0) - 1] };   // A
    if ([18] call ZPI_fnc_keyHeld) then { _in set [2, (_in select 2) + 1] };   // E
    if ([16] call ZPI_fnc_keyHeld) then { _in set [2, (_in select 2) - 1] };   // Q
    private _ground = (getTerrainHeightASL ZPI_camPosASL) max 0;
    private _agl = (ZPI_camPosASL select 2) - _ground;
    private _fast = ([42] call ZPI_fnc_keyHeld) || {[54] call ZPI_fnc_keyHeld};
    private _speed = (((_agl * 0.5) max ZPI_cfg_MinSpeed) min ZPI_cfg_MaxSpeed) * ([1, ZPI_cfg_FastMul] select _fast);
    private _fwd   = [sin ZPI_yaw, cos ZPI_yaw, 0];
    private _right = [cos ZPI_yaw, -(sin ZPI_yaw), 0];
    private _vWant = ((_fwd vectorMultiply (_in select 1)) vectorAdd (_right vectorMultiply (_in select 0))) vectorMultiply _speed;
    _vWant set [2, (_in select 2) * _speed * 0.6];
    ZPI_camVel = ZPI_camVel vectorAdd ((_vWant vectorDiff ZPI_camVel) vectorMultiply (1 - exp (-ZPI_cfg_Smoothing * _dt)));
    private _p = ZPI_camPosASL vectorAdd (ZPI_camVel vectorMultiply _dt);
    _p set [2, (_p select 2) max (((getTerrainHeightASL _p) max 0) + 2)];

    ZPI_camPosASL = _p;
    ZPI_camDir = [ZPI_yaw, ZPI_pitch] call ZPI_fnc_dirFromYawPitch;
    ZPI_camUp  = [ZPI_yaw, ZPI_pitch] call ZPI_fnc_upFromYawPitch;
};

// First surface (ground, building, tree) in the middle of the screen, ASL; [] when looking at the sky.
ZPI_fnc_lookPoint = {
    private _hits = lineIntersectsSurfaces [ZPI_camPosASL, ZPI_camPosASL vectorAdd (ZPI_camDir vectorMultiply 8000),
        objNull, objNull, true, 1, "GEOM", "NONE"];
    if (_hits isEqualTo []) exitWith { [] };
    (_hits select 0) select 0
};

// Camera: jump to a viewpoint looking at the scene center.
// _force = false: only when the scene is out of view or far away.
ZPI_fnc_viewScene = {
    params [["_force", false]];
    if (!_force && {[AGLToASL [ZPI_center select 0, ZPI_center select 1, 2]] call ZPI_fnc_onScreen}) exitWith {};
    private _c  = ZPI_center;
    private _gz = getTerrainHeightASL _c;
    private _bear = if ((ZPI_camPosASL distance2D _c) > 1) then { ZPI_camPosASL getDir _c } else { ZPI_yaw };
    private _p = _c getPos [ZPI_cfg_viewDist, _bear + 180];
    ZPI_camPosASL = [_p select 0, _p select 1, (_gz + ZPI_cfg_viewHeight) max ((getTerrainHeightASL _p) + 50)];
    private _dir = vectorNormalized ([_c select 0, _c select 1, _gz] vectorDiff ZPI_camPosASL);
    ZPI_yaw   = (_dir select 0) atan2 (_dir select 1);
    ZPI_pitch = asin (_dir select 2);
    ZPI_camDir = _dir;
    ZPI_camUp  = [ZPI_yaw, ZPI_pitch] call ZPI_fnc_upFromYawPitch;
    ZPI_camVel = [0, 0, 0];
    call ZPI_fnc_applyCamPose;
};

ZPI_fnc_createCamera = {
    ZPI_cam = "camera" camCreate [0, 0, 0];
    [ZPI_cfg_startFov] call ZPI_fnc_setFov;
    showCinemaBorder false;
    ZPI_cam cameraEffect ["internal", "back"];
    call ZPI_fnc_showHud;
    cameraEffectEnableHUD true;
    [true] call ZPI_fnc_viewScene;
};

// ---- FOV ---------------------------------------------------------------------------
// camSetFov takes Arma's fovTop: zoom = 4/3 * tan(hfov/2) / AR, and vfov follows from square pixels.
ZPI_fnc_setFov = {
    params ["_deg"];
    ZPI_hfov = (_deg max 1.6) min 100;
    private _res = getResolution;
    private _ar = (_res select 0) / (_res select 1);
    ZPI_vfov = 2 * atan ((tan (ZPI_hfov / 2)) / _ar);
    private _zoom = (4 / 3) * (tan (ZPI_hfov / 2)) / _ar;
    ZPI_cam camSetFov _zoom;
    ZPI_cam camCommit 0;
    call ZPI_fnc_applyCamPose;
};

ZPI_fnc_zoom = {                  // _z > 0 zoom in, < 0 zoom out
    params ["_z"];
    if (ZPI_fovLock) exitWith {};
    if (ZPI_scaleLock) exitWith { [ZPI_targetGSD * (ZPI_cfg_zoomStep ^ _z)] call ZPI_fnc_setGSD };
    [ZPI_hfov * (ZPI_cfg_zoomStep ^ _z)] call ZPI_fnc_setFov;
};

// ---- frame-number bar (image <-> telemetry sync) --------------------------
// 2 sentinel squares (white, black) + 24 data bits, LSB first, 8x8 px each,
// starting 4 px from the top-left corner. Decoder: tools/frame_code.py
// Note: the screenshot command does not capture UI, so the bar is only in
// screen captures (dxcam/OBS), never in screenshots taken with the P key.

ZPI_fnc_hideHud = {
    ("ZPI_hudLayer" call BIS_fnc_rscLayer) cutText ["", "PLAIN"];
    ("ZPI_frameCodeLayer" call BIS_fnc_rscLayer) cutText ["", "PLAIN"];
};

ZPI_fnc_showHud = {
    ("ZPI_hudLayer" call BIS_fnc_rscLayer) cutRsc ["ZPI_Hud", "PLAIN", 0, false];
    ("ZPI_frameCodeLayer" call BIS_fnc_rscLayer) cutRsc ["ZPI_FrameCode", "PLAIN", 0, false];
};

ZPI_fnc_updateFrameCode = {
    private _d = uiNamespace getVariable ["ZPI_frameCodeDisplay", displayNull];
    if (isNull _d) exitWith {};
    private _n = diag_frameNo mod 16777216;
    for "_i" from 0 to 23 do {
        private _b = _n mod 2;
        _n = floor (_n / 2);
        (_d displayCtrl (1100 + _i)) ctrlSetBackgroundColor ([[0, 0, 0, 1], [1, 1, 1, 1]] select _b);
    };
};

// ---- camera basis of the frame actually rendered ----------------------------------------
// Axes from points 1 km along each camera axis, then normalized
ZPI_fnc_camBasis = {            // -> [originASL, right, up, forward] (unit vectors)
    private _o = AGLToASL (positionCameraToWorld [0, 0, 0]);
    private _L = 1000;
    [
        _o,
        vectorNormalized ((AGLToASL (positionCameraToWorld [_L, 0, 0])) vectorDiff _o),
        vectorNormalized ((AGLToASL (positionCameraToWorld [0, _L, 0])) vectorDiff _o),
        vectorNormalized ((AGLToASL (positionCameraToWorld [0, 0, _L])) vectorDiff _o)
    ]
};

// ---- telemetry (JSON contract from the project description, plus extras) ------------
ZPI_fnc_logTelemetry = {
    (call ZPI_fnc_camBasis) params ["_o", "_r", "_u", "_f"];
    private _range = ["null", ZPI_laserRange toFixed 2] select (ZPI_laserRange > 0);
    private _res = getResolution;
    ["tel", format [
        '{"frame":%1,"t_game":%2,"t_tick":%3,"camera":{"pos_asl":%4,"x_axis":%5,"y_axis":%6,"z_axis":%7,"hfov_deg":%8,"vfov_deg":%9},"range_m":%10,"image":{"w":%11,"h":%12},"scene":"%13","seed":%14,"region":%15}',
        diag_frameNo toFixed 0, time toFixed 3, diag_tickTime toFixed 4,
        [_o, 3] call ZPI_fnc_v3, [_r, 7] call ZPI_fnc_v3, [_u, 7] call ZPI_fnc_v3, [_f, 7] call ZPI_fnc_v3,
        ZPI_hfov toFixed 6, ZPI_vfov toFixed 6, _range, _res select 0, _res select 1, ZPI_sceneName, ZPI_cfg_seed, ZPI_regionId
    ]] call ZPI_fnc_emit;
};

// ---- ground truth ---------------------------------------------------------------
// objs: [id, pos_asl, dir_deg, velocity, stance]; class + bbox are in the "spawn" record.
ZPI_fnc_logGT = {
    if (ZPI_entities isEqualTo []) exitWith {};
    private _items = [];
    {
        _x params ["_id", "_obj"];
        if (!isNull _obj) then {
            private _st = if (_obj isKindOf "Man") then { stance _obj } else { "" };
            _items pushBack format ['[%1,%2,%3,%4,"%5"]',
                _id, [getPosASL _obj, 2] call ZPI_fnc_v3, (getDir _obj) toFixed 1, [velocity _obj, 2] call ZPI_fnc_v3, _st];
        };
    } forEach ZPI_entities;
    private _n = ZPI_cfg_gtMaxPerLine;
    private _parts = ceil ((count _items) / _n);
    for "_k" from 0 to (_parts - 1) do {
        ["gt", format ['{"frame":%1,"t_game":%2,"part":%3,"parts":%4,"objs":[%5]}',
            diag_frameNo toFixed 0, time toFixed 3, _k, _parts, (_items select [_k * _n, _n]) joinString ","]] call ZPI_fnc_emit;
    };
};

// ---- laser rangefinder ---------------------------------------------------------------
ZPI_fnc_updateLaser = {
    private _hits = lineIntersectsSurfaces [ZPI_camPosASL, ZPI_camPosASL vectorAdd (ZPI_camDir vectorMultiply 8000),
        objNull, objNull, true, 1, "GEOM", "NONE"];
    if (_hits isEqualTo []) exitWith { ZPI_laserRange = -1; ZPI_laserPos = []; ZPI_laserObj = "" };
    private _h = _hits select 0;
    ZPI_laserPos = _h select 0;
    ZPI_laserRange = ZPI_camPosASL vectorDistance ZPI_laserPos;
    private _o = _h select 3;
    if (isNull _o) then { _o = _h select 2 };
    ZPI_laserObj = if (isNull _o) then { "" } else { typeOf _o };
};

// heading (0 = north, clockwise) and pitch (negative = looking down) of the view, deg
ZPI_fnc_attitude = {
    [((ZPI_camDir select 0) atan2 (ZPI_camDir select 1) + 360) mod 360, asin (((ZPI_camDir select 2) max -1) min 1)]
};

// ground sample distance at the laser point, m per screen pixel
ZPI_fnc_gsdNow = {
    if (ZPI_laserRange <= 0) exitWith { -1 };
    2 * ZPI_laserRange * (tan (ZPI_hfov / 2)) / ((getResolution) select 0)
};

// ---- constant pixel size: zoom follows the laser range --------------------------------
ZPI_fnc_setGSD = {
    params ["_g"];
    ZPI_targetGSD = (_g max 0.004) min 0.5;
    [format ["Scale %1 m/px: soldier ~%2 px tall, tank ~%3 px long", ZPI_targetGSD toFixed 3, round (1.8 / ZPI_targetGSD), round (7 / ZPI_targetGSD)]] call ZPI_fnc_msg;
};

ZPI_fnc_toggleScaleLock = {
    ZPI_scaleLock = !ZPI_scaleLock;
    if (ZPI_scaleLock) then {
        // always the same scale (ZPI_cfg_targetGSD unless changed with the wheel), so all shots match
        [ZPI_targetGSD] call ZPI_fnc_setGSD;
        ["Constant pixel size ON (wheel / PgUp / PgDn change the scale)"] call ZPI_fnc_msg;
    } else {
        ["Constant pixel size OFF"] call ZPI_fnc_msg;
    };
    ["scale_lock", format ['{"on":%1,"gsd":%2}', ZPI_scaleLock, ZPI_targetGSD toFixed 4]] call ZPI_fnc_event;
};

ZPI_fnc_updateScaleLock = {
    params ["_dt"];
    if (!ZPI_scaleLock || {ZPI_fovLock} || {ZPI_laserRange <= 0}) exitWith {};
    private _want = 2 * atan ((ZPI_targetGSD * ((getResolution) select 0)) / (2 * ZPI_laserRange));
    if (abs (_want - ZPI_hfov) / ZPI_hfov < 0.005) exitWith {};
    [ZPI_hfov + (_want - ZPI_hfov) * ((ZPI_cfg_scaleLockRate * _dt) min 1)] call ZPI_fnc_setFov;
};

ZPI_hudExtra = "";                // extra line, e.g. building occupancy
ZPI_hudBld = 0;
ZPI_hudGround = "---";

ZPI_fnc_updateHud = {
    private _d = uiNamespace getVariable ["ZPI_hudDisplay", displayNull];
    if (isNull _d) exitWith {};
    (call ZPI_fnc_attitude) params ["_hdg", "_pitch"];
    private _gz  = (getTerrainHeightASL ZPI_camPosASL) max 0;
    private _alt = ZPI_camPosASL select 2;
    private _nl = toString [10];
    private _range = if (ZPI_laserRange > 0) then {
        format ["LASER %1 m   TGT %2  (%3, %4)  elev %5 m%6", ZPI_laserRange toFixed 1, mapGridPosition [ZPI_laserPos select 0, ZPI_laserPos select 1],
            (ZPI_laserPos select 0) toFixed 0, (ZPI_laserPos select 1) toFixed 0, (ZPI_laserPos select 2) toFixed 1,
            ["", "  [" + ZPI_laserObj + "]"] select (ZPI_laserObj != "")]
    } else { "LASER  --- no return ---" };
    private _gsd = call ZPI_fnc_gsdNow;
    private _scale = if (_gsd > 0) then { format ["GSD %1 m/px  soldier ~%2 px", _gsd toFixed 3, round (1.8 / _gsd)] } else { "GSD ---" };
    private _lock = if (ZPI_scaleLock) then { format ["  SCALE LOCK %1", ZPI_targetGSD toFixed 3] } else { "" };
    private _hold = if (ZPI_camLock) then { "  [CAMERA HELD]" } else { "" };
    // ground type under the crosshair + buildings that would be labelled (every 30 frames)
    if (diag_frameNo % 30 == 0) then {
        ZPI_hudBld = call ZPI_fnc_buildingsInView;
        ZPI_hudGround = if (ZPI_laserRange > 0) then {
            format ["%1 (green %2)", surfaceType ZPI_laserPos, ([ZPI_laserPos] call ZPI_fnc_surfaceGreen) toFixed 1]
        } else { "---" };
    };
    private _txt = _range + _nl
        + format ["ALT %1 m ASL / %2 m AGL   HDG %3   PITCH %4   CAM %5", _alt toFixed 0, (_alt - _gz) toFixed 0, _hdg toFixed 1, _pitch toFixed 1, mapGridPosition [ZPI_camPosASL select 0, ZPI_camPosASL select 1]] + _nl
        + format ["FOV %1 deg   %2%3%4", ZPI_hfov toFixed 2, _scale, _lock, _hold] + _nl
        + format ["GROUND %1   BUILDINGS IN VIEW %2%3", ZPI_hudGround, ZPI_hudBld, ["", " (too many for the generator)"] select (ZPI_hudBld > ZPI_cfg_maxBuildings)]
        + (["", _nl + ZPI_hudExtra] select (ZPI_hudExtra != ""));
    (_d displayCtrl 1200) ctrlSetText _txt;
};

// ---- per-frame loop -------------------------------------------------------------
ZPI_fnc_onFrame = {
    if (isGamePaused) exitWith {};
    private _rdt = diag_deltaTime min 0.1;

    if (!ZPI_frozen && {!ZPI_camLock}) then {
        [_rdt] call ZPI_fnc_updateCam;
        call ZPI_fnc_applyCamPose;
    };
    call ZPI_fnc_updateLaser;
    [_rdt] call ZPI_fnc_updateScaleLock;
    call ZPI_fnc_captureTick;
    call ZPI_fnc_buildingTick;
    if (!ZPI_quiet) then {
        call ZPI_fnc_updateHud;
        call ZPI_fnc_updateFrameCode;
    };
    if (ZPI_cfg_telemetryEvery > 0 && {diag_frameNo % ZPI_cfg_telemetryEvery == 0}) then {
        call ZPI_fnc_logTelemetry;
    };
    if (ZPI_cfg_gtEvery > 0 && {diag_frameNo % ZPI_cfg_gtEvery == 0}) then {
        call ZPI_fnc_logGT;
    };
};
