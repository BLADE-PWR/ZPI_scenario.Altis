// zpi_nograss: units in grass are always drawn whole.
//
// Beyond the grass draw distance Arma sinks units standing on grassy surfaces into the ground
// (a stand-in for the grass it no longer draws; objects like boxes are not affected). Seen from the
// drone camera, that cuts off boots and up to half of a prone soldier, while the labels still cover
// the whole body. character = "Empty" removes the grass (clutter) from these surfaces, so the engine
// has nothing to stand in for and units are drawn whole (tested; grassCover = 0 alone did not help).
//
// The class list (with each class's original parent and the addons that define it) was generated
// in the game from CfgSurfaces. After changing it, pack it again with Addon Builder (README.md, "Grass addon").

class CfgPatches {
    class zpi_nograss {
        units[] = {};
        weapons[] = {};
        requiredVersion = 0.1;
        requiredAddons[] = {"A3_Map_Data", "A3_Map_Tanoabuka", "A3_Data_F_Exp", "A3_Map_Malden", "A3_Map_Enoch"};
    };
};

class CfgSurfaces {
    class Default;
    class GdtStratisDirt: Default { grassCover = 0; character = "Empty"; };
    class GdtStratisSeabedCluttered: Default { grassCover = 0; character = "Empty"; };
    class GdtStratisDryGrass: Default { grassCover = 0; character = "Empty"; };
    class GdtStratisGreenGrass: Default { grassCover = 0; character = "Empty"; };
    class GdtStratisRocky: Default { grassCover = 0; character = "Empty"; };
    class GdtStratisForestPine: Default { grassCover = 0; character = "Empty"; };
    class GdtForestPine: Default { grassCover = 0; character = "Empty"; };
    class GdtDirt: Default { grassCover = 0; character = "Empty"; };
    class GdtGrassGreen: Default { grassCover = 0; character = "Empty"; };
    class GdtGrassDry: Default { grassCover = 0; character = "Empty"; };
    class GdtGrassWild: Default { grassCover = 0; character = "Empty"; };
    class GdtWeed: Default { grassCover = 0; character = "Empty"; };
    class GdtWildField: Default { grassCover = 0; character = "Empty"; };
    class GdtThorn: Default { grassCover = 0; character = "Empty"; };
    class GdtStonyThistle: Default { grassCover = 0; character = "Empty"; };
    class GdtMud: Default { grassCover = 0; character = "Empty"; };
    class dirtrunway: GdtStratisDirt { grassCover = 0; character = "Empty"; };
    class mud: GdtStratisDirt { grassCover = 0; character = "Empty"; };
    class surf_roaddirt: GdtDirt { grassCover = 0; character = "Empty"; };
    class surf_wood: GdtForestPine { grassCover = 0; character = "Empty"; };
    class surfint_wood: GdtForestPine { grassCover = 0; character = "Empty"; };
    class mud_exp: mud { grassCover = 0; character = "Empty"; };
    class straw_exp: mud { grassCover = 0; character = "Empty"; };
    class GdtForestMalden: Default { grassCover = 0; character = "Empty"; };
    class GdtGrassShort: Default { grassCover = 0; character = "Empty"; };
    class GdtGrassTall: Default { grassCover = 0; character = "Empty"; };
    class GdtGrassLong: Default { grassCover = 0; character = "Empty"; };
    class GdtRedDirt: Default { grassCover = 0; character = "Empty"; };
    class GdtField: Default { grassCover = 0; character = "Empty"; };
    class GdtForest: Default { grassCover = 0; character = "Empty"; };
    class GdtVolcano: Default { grassCover = 0; character = "Empty"; };
    class GdtKLGrass1: Default { grassCover = 0; character = "Empty"; };
    class GdtKLGrass2: Default { grassCover = 0; character = "Empty"; };
    class GdtKLForestCon: Default { grassCover = 0; character = "Empty"; };
    class GdtKLForestDec: Default { grassCover = 0; character = "Empty"; };
    class GdtKlField: Default { grassCover = 0; character = "Empty"; };
    class GdtKlStubble: Default { grassCover = 0; character = "Empty"; };
};
