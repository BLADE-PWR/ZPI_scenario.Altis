// =====================================================================
//  ZPI scene pack - orthophoto (Z key)
//
//  The camera flies a grid of tiles over the scene, looking straight down
//  with north at the top of every picture, and takes one screenshot per tile.
//  All scene objects are frozen during the flight and their positions are
//  logged once, so the map and the object positions match exactly.
//  tools/make_ortho.py stitches the tiles into one georeferenced image
//  (PNG + world file for GIS) and draws the soldiers / vehicles on it.
//
//  Log records:
//    ZPI|ortho|     {"ortho":tag, "center", "size", "step":[x,y], "nx","ny", ...}
//    ZPI|otile|     {"ortho":tag, "image", "ok", "row", "col", "cam_pos_asl", "ground_z", "hfov", "vfov", "x_axis", "y_axis"}
//    ZPI|oobj|      {"ortho":tag, "objs":[[id, kind, stance, x, y, z, dir, inside], ...]}
// =====================================================================

ZPI_orthoRunning = false;

ZPI_fnc_orthoCapture = {
    if (ZPI_orthoRunning) exitWith { ["Orthophoto already running"] call ZPI_fnc_msg };
    if (ZPI_frozen || {ZPI_camLock}) exitWith { ["Busy (capture in progress), try again"] call ZPI_fnc_msg };
    ZPI_orthoRunning = true;
    [] spawn {
        // ---- save the current view, hold everything still ----
        private _saved = [ZPI_camPosASL, ZPI_camDir, ZPI_camUp, ZPI_yaw, ZPI_pitch, ZPI_hfov, ZPI_scaleLock, ZPI_autoCapture, ZPI_firefight];
        ZPI_camLock = true;
        ZPI_fovLock = true;
        ZPI_scaleLock = false;
        ZPI_autoCapture = false;
        ZPI_firefight = false;
        private _frozen = [];
        {
            private _o = _x select 1;
            if (!isNull _o && {simulationEnabled _o}) then {
                _o enableSimulation false;
                _frozen pushBack _o;
            };
        } forEach ZPI_entities;

        // ---- zoom to the tile FOV ----
        [ZPI_cfg_orthoFov] call ZPI_fnc_setFov;

        // ---- tile grid ----
        private _c = ZPI_center;
        private _H = ZPI_cfg_orthoAlt;
        private _tileW = 2 * _H * (tan (ZPI_hfov / 2));
        private _tileH = 2 * _H * (tan (ZPI_vfov / 2));
        private _sx = _tileW * (1 - ZPI_cfg_orthoOverlap);
        private _sy = _tileH * (1 - ZPI_cfg_orthoOverlap);
        private _nx = ceil (ZPI_cfg_orthoSize / _sx);
        private _ny = ceil (ZPI_cfg_orthoSize / _sy);
        private _tag = format ["%1_%2", ZPI_sessionTag, [diag_frameNo, 8] call ZPI_fnc_pad];
        ["ortho", format ['{"ortho":"%1","world":"%2","center":%3,"size":%4,"alt":%5,"step":[%6,%7],"nx":%8,"ny":%9,"hfov":%10,"vfov":%11,"scene":"%12","time_label":"%13","weather":"%14"}',
            _tag, worldName, [_c, 1] call ZPI_fnc_v3, ZPI_cfg_orthoSize, _H, _sx toFixed 2, _sy toFixed 2, _nx, _ny,
            ZPI_hfov toFixed 4, ZPI_vfov toFixed 4, ZPI_sceneName,
            (ZPI_timePresets select ZPI_timeIndex) select 2, (ZPI_weatherPresets select ZPI_weatherIndex) select 0]] call ZPI_fnc_emit;
        [format ["Orthophoto: %1 x %2 tiles, please wait", _nx, _ny]] call ZPI_fnc_msg;

        // ---- fly the grid: rows from north to south, columns west to east ----
        private _done = 0;
        for "_r" from 0 to (_ny - 1) do {
            for "_k" from 0 to (_nx - 1) do {
                private _tx = (_c select 0) + (_k - (_nx - 1) / 2) * _sx;
                private _ty = (_c select 1) - (_r - (_ny - 1) / 2) * _sy;
                private _gz = (getTerrainHeightASL [_tx, _ty]) max 0;
                ZPI_camPosASL = [_tx, _ty, _gz + _H];
                ZPI_camDir = [0, 0, -1];
                ZPI_camUp  = [0, 1, 0];              // north up in the picture
                call ZPI_fnc_applyCamPose;
                sleep ZPI_cfg_orthoSettle;           // terrain and objects load in
                private _f0 = diag_frameNo;
                waitUntil { diag_frameNo > _f0 };
                private _img = format ["zpi/%1/ortho_%2/tile_%3_%4.png", ZPI_sessionTag, _tag, [_r, 2] call ZPI_fnc_pad, [_k, 2] call ZPI_fnc_pad];
                private _ok = screenshot _img;
                (call ZPI_fnc_camBasis) params ["_o", "_rx", "_uy", "_fz"];
                ["otile", format ['{"ortho":"%1","image":"%2","ok":%3,"row":%4,"col":%5,"cam_pos_asl":%6,"ground_z":%7,"hfov":%8,"vfov":%9,"x_axis":%10,"y_axis":%11}',
                    _tag, _img, _ok, _r, _k, [_o, 2] call ZPI_fnc_v3, _gz toFixed 2,
                    ZPI_hfov toFixed 4, ZPI_vfov toFixed 4, [_rx, 5] call ZPI_fnc_v3, [_uy, 5] call ZPI_fnc_v3]] call ZPI_fnc_emit;
                private _f1 = diag_frameNo;
                waitUntil { diag_frameNo > _f1 };
                _done = _done + 1;
                if (_done % 5 == 0) then { [format ["Orthophoto: %1 / %2 tiles", _done, _nx * _ny]] call ZPI_fnc_msg };
            };
        };

        // ---- object positions at the moment of the flight ----
        private _items = [];
        {
            _x params ["_id", "_obj", "_cls"];
            if (!isNull _obj) then {
                private _kind = ZPI_clsToKind getOrDefault [_cls, _cls];
                private _st = if (_obj isKindOf "Man") then { stance _obj } else { "" };
                private _in = (_obj isKindOf "Man") && {!isNull ([_obj] call ZPI_fnc_buildingOf)};
                private _p = getPosASL _obj;
                _items pushBack format ['[%1,"%2","%3",%4,%5,%6,%7,%8]', _id, _kind, _st,
                    (_p select 0) toFixed 2, (_p select 1) toFixed 2, (_p select 2) toFixed 2, (getDir _obj) toFixed 1, [0, 1] select _in];
            };
        } forEach ZPI_entities;
        for "_i" from 0 to ((count _items) - 1) step 8 do {
            ["oobj", format ['{"ortho":"%1","objs":[%2]}', _tag, (_items select [_i, 8]) joinString ","]] call ZPI_fnc_emit;
        };

        // ---- restore ----
        { if (!isNull _x) then { _x enableSimulation true } } forEach _frozen;
        _saved params ["_pos", "_dir", "_up", "_yaw", "_pitch", "_fov", "_lock", "_auto", "_fight"];
        ZPI_camPosASL = _pos;
        ZPI_camDir = _dir;
        ZPI_camUp = _up;
        ZPI_yaw = _yaw;
        ZPI_pitch = _pitch;
        call ZPI_fnc_applyCamPose;
        [_fov] call ZPI_fnc_setFov;
        ZPI_scaleLock = _lock;
        ZPI_autoCapture = _auto;
        if (_fight) then { call ZPI_fnc_toggleFirefight };
        ZPI_camLock = false;
        ZPI_fovLock = false;
        ZPI_mouseDX = 0;
        ZPI_mouseDY = 0;
        ZPI_orthoRunning = false;
        [format ["Orthophoto done: %1 tiles, %2 objects. Run tools/make_ortho.py", _done, count _items]] call ZPI_fnc_msg;
    };
};
