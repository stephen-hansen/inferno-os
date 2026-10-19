# Play simulation.  Reference: doomgeneric p_mobj.c p_map.c
# p_maputl.c p_user.c p_tick.c p_doors.c p_spec.c p_switch.c
# p_floor.c (GPL-2).  Collision walks every line/thing each check
# (no blockmap); P_SlideMove traces its three leading corners
# brute-force over all lines; doors + use-lines are in (milestone
# 13 slice).  Item pickup, weapons/psprites and AI actions are
# no-op stubs for now.

implement Game;

include "sys.m";
	sys: Sys;
include "rend.m";
	rend: Rend;
include "wad.m";
	wad: Wad;
include "map.m";
	map: Map;
	Level: import map;
	Thing: import map;
include "info.m";
	inf: Info;
	MobjInfo: import inf;
include "game.m";
include "sound.m";
	sound: Sound;

# collision temporaries (vanilla module globals in p_map.c)
tmthing: ref Mobj;
tmflags, tmx, tmy: int;
tmbbox: array of int;		# BOXTOP, BOXBOTTOM, BOXLEFT, BOXRIGHT
tmfloorz, tmceilingz, tmdropoffz: int;
floatok: int;
ceilingline: int;		# linedef index, -1 if none
opentop, openbottom, openrange, lowfloor: int;

# P_RadiusAttack temporaries (vanilla p_map.c globals)
bombspot, bombsource: ref Mobj;
bombdamage: int;

# P_SlideMove temporaries (vanilla p_map.c module globals)
slidemo: ref Mobj;
bestslidefrac, secondslidefrac: int;
bestslideline, secondslideline: int;	# linedef index
tmxmove, tmymove: int;
tantoangle: array of int;		# 2049; vanilla tables.c table
SLOPERANGE: con 2048;

# --- sector thinkers (p_tick.c subset, milestone 13 slice) ---
# vanilla keeps one thinker list for mobjs and special sectors;
# ours runs mobjs first, then sector thinkers (1-tic ordering
# difference is unobservable at door speeds).
THINK_DOOR: con 0;
THINK_FLOOR: con 1;
THINK_PLAT: con 2;
THINK_LIGHT: con 3;
RES_OK: con 0;			# T_MovePlane result_e
RES_CRUSHED: con 1;
RES_PASTDEST: con 2;
VDOORSPEED: con 2*FRACUNIT;	# p_spec.h
VDOORWAIT: con 150;
FLOORSPEED: con FRACUNIT;	# p_spec.h (turboLower uses 4x)
PLATSPEED: con FRACUNIT;
PLATWAIT: con 3;		# p_spec.h (x TICRATE)
MELEERANGE: con 64*FRACUNIT;
MISSILERANGE: con 32*64*FRACUNIT;
SKYFLAT: con "F_SKY1";		# map flat marking a sky ceiling (mirrors view.b)
MAXSPECIALCROSS: con 20;	# p_local.h (no overrun emulation)
USERANGE: con 64*FRACUNIT;	# P_UseLines reach (p_local.h)
Door: adt {			# vanilla vldoor_t
	sec:	ref Map->Sector;
	dtype:	int;		# VLD_*
	topheight:	int;	# 16.16
	speed:	int;		# 16.16 per tic
	direction:	int;	# 0 wait, 1 up, 2 wait-then-open, -1 down
	topwait:	int;	# tics at top before closing
	topcountdown:	int;
};
Floor: adt {			# vanilla floormove_t (subset)
	sec:	ref Map->Sector;
	fltype:	int;		# FL_* (turboLower/lowerFloor/donutRaise)
	floordestheight:	int;	# 16.16
	speed:	int;
	direction:	int;	# 1 up, -1 down
	crush:	int;
	texture:	string;	# donutRaise/lowerAndChange end texture
	newspecial:	int;	# donutRaise/lowerAndChange end special
};
Plat: adt {			# vanilla plat_t (subset)
	sec:	ref Map->Sector;
	pltype:	int;		# PL_* (downWaitUpStay/raiseToNearestAndChange)
	speed:	int;
	low, high:	int;	# 16.16
	wait:	int;		# tics at each end
	count:	int;
	status:	int;		# PLS_* (up/down/waiting/stasis)
	crush:	int;
	tag:	int;
};
Thinker: adt {
	kind:	int;		# THINK_DOOR/FLOOR/PLAT/LIGHT (ceilings later)
	door:	ref Door;
	floor:	ref Floor;
	plat:	ref Plat;
	light:	ref Light;
	removed:	int;		# lazy unlink, like mobjs
};

# vanilla light thinkers (p_lights.c) unified: only the fields each
# type touches are meaningful, but ALL are set at spawn (dirty heap).
Light: adt {
	sec:	ref Map->Sector;
	ltype:	int;		# LT_FIRE/FLASH/STROBE/GLOW
	count:	int;
	minlight, maxlight:	int;
	darktime, brighttime:	int;	# strobe only
	direction:	int;	# glow only (-1 down, 1 up)
	maxtime, mintime:	int;	# flash only
};
thinkers: array of ref Thinker;
activeplats: array of ref Thinker;	# plats only (p_plats.c list)
Button: adt {			# vanilla button_t (p_switch.c)
	li:	int;		# linedef index
	where:	int;		# BW_TOP/MIDDLE/BOTTOM
	btexture:	string;	# texture to restore
	btimer:	int;		# tics left, 0 = free
};
buttonlist: array of ref Button;	# [MAXBUTTONS], timer-ordered use
spechit: array of int;	# crossed special linedefs (p_map.c)
nspechit: int;
exited: int;		# G_ExitLevel flag (consumed by milestone 16)
sexited: int;		# G_SecretExitLevel flag (S1 special 51)

# switch texture pairs (vanilla p_switch.c alphSwitchList,
# shareware episode 1 set, as P_InitSwitchList loads it).
# Textures stay name strings here (no texture numbers).
switchpairs: array of (string, string);

# ammo table (vanilla d_items.c weaponinfo ammo column + p_inter.c
# clipammo, indexed by WP_* / AM_*); set in init()
weaponammo: array of int;
clipammo: array of int;

init(): string
{
	if (sys == nil) {
		sys = load Sys Sys->PATH;
		if (sys == nil)
			return "can't load Sys";
	}
	if (inf == nil) {
		inf = load Info Info->PATH;
		if (inf == nil)
			inf = load Info "info.dis";
		if (inf == nil)
			return "can't load Info module";
		err := inf->init();
		if (err != nil)
			return err;
	}
	if (rend == nil) {
		rend = load Rend Rend->PATH;
		if (rend == nil)
			rend = load Rend "rend.dis";
		if (rend == nil)
			return "can't load Rend module";
	}
	if (map == nil) {		# ST_* constants via map->
		map = load Map Map->PATH;
		if (map == nil)
			map = load Map "map.dis";
		if (map == nil)
			return "can't load Map module";
	}
	if (sound == nil) {
		sound = load Sound Sound->PATH;
		if (sound == nil)
			sound = load Sound "sound.dis";
		if (sound == nil)
			return "can't load Sound module";
		err := sound->init();
		if (err != nil)
			return err;
	}
	if (tmbbox == nil)
		tmbbox = array[4] of int;
	if (tantoangle == nil)
		tantoangle = array[] of {
	16r0, 16r517cc, 16ra2f98, 16rf4763, 16r145f2e, 16r1976f9, 16r1e8ec2, 16r23a68b, 16r28be53, 16r2dd619, 16r32edde, 16r3805a1,
	16r3d1d63, 16r423523, 16r474ce0, 16r4c649c, 16r517c55, 16r56940b, 16r5babbf, 16r60c370, 16r65db1e, 16r6af2c8, 16r700a70, 16r752213,
	16r7a39b4, 16r7f5150, 16r8468e9, 16r89807d, 16r8e980d, 16r93af98, 16r98c71f, 16r9ddea1, 16ra2f61e, 16ra80d96, 16rad2509, 16rb23c77,
	16rb753de, 16rbc6b41, 16rc1829d, 16rc699f3, 16rcbb143, 16rd0c88d, 16rd5dfd0, 16rdaf70c, 16re00e42, 16re52570, 16rea3c98, 16ref53b8,
	16rf46ad1, 16rf981e2, 16rfe98eb, 16r103afec, 16r108c6e6, 16r10dddd6, 16r112f4be, 16r1180b9e, 16r11d2276, 16r1223944, 16r127500a, 16r12c66c6,
	16r1317d78, 16r1369420, 16r13baac0, 16r140c156, 16r145d7e2, 16r14aee62, 16r15004da, 16r1551b46, 16r15a31a8, 16r15f4800, 16r1645e4c, 16r169748c,
	16r16e8ac2, 16r173a0ec, 16r178b70c, 16r17dcd1e, 16r182e326, 16r187f920, 16r18d0f10, 16r19224f2, 16r1973ac8, 16r19c5090, 16r1a1664e, 16r1a67bfc,
	16r1ab919e, 16r1b0a734, 16r1b5bcbc, 16r1bad234, 16r1bfe7a0, 16r1c4fcfe, 16r1ca124e, 16r1cf2790, 16r1d43cc4, 16r1d951e8, 16r1de66fe, 16r1e37c04,
	16r1e890fc, 16r1eda5e6, 16r1f2babe, 16r1f7cf88, 16r1fce442, 16r201f8ec, 16r2070d88, 16r20c2210, 16r211368c, 16r2164af4, 16r21b5f4c, 16r2207394,
	16r22587cc, 16r22a9bf4, 16r22fb008, 16r234c40c, 16r239d7fc, 16r23eebdc, 16r243ffa8, 16r2491364, 16r24e2710, 16r2533aa8, 16r2584e2c, 16r25d61a0,
	16r2627500, 16r267884c, 16r26c9b84, 16r271aeac, 16r276c1bc, 16r27bd4bc, 16r280e7a8, 16r285fa80, 16r28b0d44, 16r2901ff4, 16r295328c, 16r29a4514,
	16r29f5784, 16r2a469e4, 16r2a97c28, 16r2ae8e5c, 16r2b3a078, 16r2b8b280, 16r2bdc474, 16r2c2d650, 16r2c7e818, 16r2ccf9c8, 16r2d20b64, 16r2d71ce8,
	16r2dc2e54, 16r2e13fac, 16r2e650ec, 16r2eb6214, 16r2f07324, 16r2f58420, 16r2fa9504, 16r2ffa5cc, 16r304b680, 16r309c71c, 16r30ed7a0, 16r313e80c,
	16r318f860, 16r31e0898, 16r32318bc, 16r32828c4, 16r32d38b4, 16r332488c, 16r3375848, 16r33c67ec, 16r3417774, 16r34686e8, 16r34b963c, 16r350a578,
	16r355b49c, 16r35ac3a4, 16r35fd290, 16r364e164, 16r369f01c, 16r36efeb8, 16r3740d3c, 16r3791ba0, 16r37e29ec, 16r383381c, 16r3884630, 16r38d5428,
	16r3926200, 16r3976fc0, 16r39c7d64, 16r3a18aec, 16r3a69854, 16r3aba5a0, 16r3b0b2d0, 16r3b5bfe4, 16r3baccdc, 16r3bfd9b4, 16r3c4e66c, 16r3c9f30c,
	16r3ceff88, 16r3d40bec, 16r3d9182c, 16r3de2454, 16r3e33058, 16r3e83c40, 16r3ed4808, 16r3f253b4, 16r3f75f3c, 16r3fc6aa8, 16r40175f8, 16r4068120,
	16r40b8c30, 16r4109718, 16r415a1e8, 16r41aac98, 16r41fb720, 16r424c190, 16r429cbd8, 16r42ed600, 16r433e010, 16r438e9f8, 16r43df3c0, 16r442fd68,
	16r44806e8, 16r44d1050, 16r4521990, 16r45722b0, 16r45c2bb0, 16r4613488, 16r4663d40, 16r46b45d8, 16r4704e48, 16r4755698, 16r47a5ec8, 16r47f66d8,
	16r4846ec0, 16r4897680, 16r48e7e20, 16r49385a0, 16r4988cf8, 16r49d9430, 16r4a29b40, 16r4a7a228, 16r4aca8f0, 16r4b1af98, 16r4b6b618, 16r4bbbc70,
	16r4c0c2a8, 16r4c5c8b8, 16r4cacea0, 16r4cfd468, 16r4d4da08, 16r4d9df80, 16r4dee4d0, 16r4e3ea00, 16r4e8ef08, 16r4edf3e8, 16r4f2f8a0, 16r4f7fd38,
	16r4fd01a8, 16r50205e8, 16r5070a08, 16r50c0e00, 16r51111d8, 16r5161580, 16r51b1900, 16r5201c58, 16r5251f88, 16r52a2298, 16r52f2578, 16r5342830,
	16r5392ac0, 16r53e2d28, 16r5432f68, 16r5483180, 16r54d3370, 16r5523530, 16r55736c8, 16r55c3840, 16r5613980, 16r5663aa0, 16r56b3b98, 16r5703c60,
	16r5753d00, 16r57a3d70, 16r57f3dc0, 16r5843de0, 16r5893dd0, 16r58e3da0, 16r5933d40, 16r5983cb0, 16r59d3bf8, 16r5a23b18, 16r5a73a08, 16r5ac38d0,
	16r5b13768, 16r5b635d8, 16r5bb3418, 16r5c03228, 16r5c53010, 16r5ca2dd0, 16r5cf2b60, 16r5d428c0, 16r5d925f8, 16r5de2300, 16r5e31fd8, 16r5e81c88,
	16r5ed1908, 16r5f21558, 16r5f71178, 16r5fc0d70, 16r6010938, 16r60604d0, 16r60b0038, 16r60ffb78, 16r614f688, 16r619f160, 16r61eec10, 16r623e690,
	16r628e0e8, 16r62ddb08, 16r632d4f8, 16r637ceb8, 16r63cc850, 16r641c1b0, 16r646bae0, 16r64bb3e8, 16r650acb8, 16r655a558, 16r65a9dc8, 16r65f9608,
	16r6648e18, 16r66985f8, 16r66e7da0, 16r6737520, 16r6786c68, 16r67d6380, 16r6825a68, 16r6875118, 16r68c4798, 16r6913df0, 16r6963408, 16r69b29f8,
	16r6a01fb0, 16r6a51538, 16r6aa0a88, 16r6aeffa8, 16r6b3f498, 16r6b8e950, 16r6bdddd8, 16r6c2d228, 16r6c7c648, 16r6ccba38, 16r6d1adf0, 16r6d6a170,
	16r6db94c0, 16r6e087d8, 16r6e57ac0, 16r6ea6d78, 16r6ef5ff0, 16r6f45238, 16r6f94450, 16r6fe3630, 16r70327d8, 16r7081948, 16r70d0a88, 16r711fb90,
	16r716ec60, 16r71bdd00, 16r720cd68, 16r725bd98, 16r72aad90, 16r72f9d58, 16r7348ce8, 16r7397c38, 16r73e6b58, 16r7435a40, 16r74848f8, 16r74d3770,
	16r75225b0, 16r75713c0, 16r75c0190, 16r760ef30, 16r765dc98, 16r76ac9c0, 16r76fb6b8, 16r774a370, 16r7798ff8, 16r77e7c40, 16r7836850, 16r7885430,
	16r78d3fd0, 16r7922b38, 16r7971668, 16r79c0158, 16r7a0ec18, 16r7a5d698, 16r7aac0e0, 16r7afaaf0, 16r7b494c8, 16r7b97e60, 16r7be67c0, 16r7c350e8,
	16r7c839d8, 16r7cd2288, 16r7d20b00, 16r7d6f338, 16r7dbdb38, 16r7e0c300, 16r7e5aa88, 16r7ea91d8, 16r7ef78f0, 16r7f45fc8, 16r7f94660, 16r7fe2cc8,
	16r80312f0, 16r807f8d0, 16r80cde80, 16r811c3f0, 16r816a920, 16r81b8e20, 16r82072d0, 16r8255750, 16r82a3b90, 16r82f1fa0, 16r8340360, 16r838e6f0,
	16r83dca30, 16r842ad40, 16r8479010, 16r84c72a0, 16r8515500, 16r8563710, 16r85b18f0, 16r85ffa80, 16r864dbe0, 16r869bd00, 16r86e9de0, 16r8737e80,
	16r8785ee0, 16r87d3f00, 16r8821ee0, 16r886fe90, 16r88bddf0, 16r890bd10, 16r8959bf0, 16r89a7aa0, 16r89f5900, 16r8a43720, 16r8a91510, 16r8adf2b0,
	16r8b2d010, 16r8b7ad40, 16r8bc8a20, 16r8c166c0, 16r8c64320, 16r8cb1f40, 16r8cffb20, 16r8d4d6c0, 16r8d9b220, 16r8de8d40, 16r8e36820, 16r8e842b0,
	16r8ed1d10, 16r8f1f720, 16r8f6d0f0, 16r8fbaa80, 16r90083d0, 16r9055ce0, 16r90a35b0, 16r90f0e30, 16r913e680, 16r918be80, 16r91d9640, 16r9226dc0,
	16r92744f0, 16r92c1bf0, 16r930f2a0, 16r935c910, 16r93a9f30, 16r93f7520, 16r9444ac0, 16r9492020, 16r94df540, 16r952ca10, 16r9579eb0, 16r95c7300,
	16r9614700, 16r9661ad0, 16r96aee50, 16r96fc180, 16r9749480, 16r9796730, 16r97e39a0, 16r9830bc0, 16r987dda0, 16r98caf40, 16r99180a0, 16r99651b0,
	16r99b2270, 16r99ff300, 16r9a4c340, 16r9a99330, 16r9ae62e0, 16r9b33250, 16r9b80180, 16r9bcd050, 16r9c19ef0, 16r9c66d40, 16r9cb3b50, 16r9d00910,
	16r9d4d690, 16r9d9a3c0, 16r9de70b0, 16r9e33d50, 16r9e809b0, 16r9ecd5c0, 16r9f1a190, 16r9f66d20, 16r9fb3860, 16ra000350, 16ra04ce00, 16ra099860,
	16ra0e6280, 16ra132c50, 16ra17f5e0, 16ra1cbf20, 16ra218820, 16ra2650d0, 16ra2b1940, 16ra2fe150, 16ra34a930, 16ra3970c0, 16ra3e3800, 16ra42fef0,
	16ra47c5a0, 16ra4c8c00, 16ra515220, 16ra5617f0, 16ra5add80, 16ra5fa2b0, 16ra6467a0, 16ra692c50, 16ra6df0b0, 16ra72b4c0, 16ra777880, 16ra7c3c00,
	16ra80ff30, 16ra85c220, 16ra8a84b0, 16ra8f4700, 16ra940900, 16ra98cac0, 16ra9d8c30, 16raa24d50, 16raa70e20, 16raabceb0, 16rab08ef0, 16rab54ee0,
	16raba0e80, 16rabecde0, 16rac38ce0, 16rac84ba0, 16racd0a10, 16rad1c840, 16rad68610, 16radb43a0, 16rae000e0, 16rae4bdd0, 16rae97a80, 16raee36d0,
	16raf2f2e0, 16raf7ae90, 16rafc6a00, 16rb012520, 16rb05e000, 16rb0a9a80, 16rb0f54b0, 16rb140ea0, 16rb18c840, 16rb1d8180, 16rb223a80, 16rb26f330,
	16rb2bab90, 16rb3063a0, 16rb351b70, 16rb39d2e0, 16rb3e8a00, 16rb4340e0, 16rb47f760, 16rb4cada0, 16rb516380, 16rb561920, 16rb5ace60, 16rb5f8360,
	16rb643800, 16rb68ec60, 16rb6da070, 16rb725420, 16rb770790, 16rb7bbab0, 16rb806d70, 16rb851ff0, 16rb89d210, 16rb8e83f0, 16rb933570, 16rb97e6a0,
	16rb9c9790, 16rba14820, 16rba5f860, 16rbaaa850, 16rbaf57f0, 16rbb40740, 16rbb8b640, 16rbbd64f0, 16rbc21350, 16rbc6c150, 16rbcb6f10, 16rbd01c70,
	16rbd4c980, 16rbd97640, 16rbde22b0, 16rbe2ced0, 16rbe77aa0, 16rbec2610, 16rbf0d140, 16rbf57c10, 16rbfa2690, 16rbfed0c0, 16rc037a90, 16rc082420,
	16rc0ccd50, 16rc117630, 16rc161ec0, 16rc1ac6f0, 16rc1f6ee0, 16rc241670, 16rc28bdb0, 16rc2d64a0, 16rc320b30, 16rc36b180, 16rc3b5770, 16rc3ffd10,
	16rc44a250, 16rc494740, 16rc4debe0, 16rc529030, 16rc573430, 16rc5bd7d0, 16rc607b20, 16rc651e10, 16rc69c0c0, 16rc6e6310, 16rc730500, 16rc77a6b0,
	16rc7c4800, 16rc80e8f0, 16rc8589a0, 16rc8a29f0, 16rc8ec9e0, 16rc936990, 16rc9808e0, 16rc9ca7e0, 16rca14680, 16rca5e4d0, 16rcaa82c0, 16rcaf2060,
	16rcb3bdb0, 16rcb85ab0, 16rcbcf750, 16rcc19390, 16rcc62f80, 16rccacb20, 16rccf6670, 16rcd40160, 16rcd89bf0, 16rcdd3630, 16rce1d020, 16rce669b0,
	16rceb02f0, 16rcef9bd0, 16rcf43460, 16rcf8cca0, 16rcfd6480, 16rd01fc00, 16rd069330, 16rd0b2a10, 16rd0fc090, 16rd1456b0, 16rd18ec80, 16rd1d8200,
	16rd221720, 16rd26abf0, 16rd2b4060, 16rd2fd470, 16rd346830, 16rd38fba0, 16rd3d8eb0, 16rd422160, 16rd46b3c0, 16rd4b45d0, 16rd4fd770, 16rd5468d0,
	16rd58f9c0, 16rd5d8a70, 16rd621ab0, 16rd66aaa0, 16rd6b3a40, 16rd6fc970, 16rd745860, 16rd78e6e0, 16rd7d7510, 16rd8202f0, 16rd869070, 16rd8b1d90,
	16rd8faa50, 16rd9436c0, 16rd98c2e0, 16rd9d4ea0, 16rda1da00, 16rda66500, 16rdaaefb0, 16rdaf7a00, 16rdb40400, 16rdb88da0, 16rdbd16e0, 16rdc19fc0,
	16rdc62850, 16rdcab090, 16rdcf3860, 16rdd3bfe0, 16rdd84700, 16rddccdd0, 16rde15430, 16rde5da50, 16rdea6000, 16rdeee560, 16rdf36a60, 16rdf7ef00,
	16rdfc7340, 16re00f730, 16re057ac0, 16re09fe00, 16re0e80d0, 16re130350, 16re178570, 16re1c0740, 16re2088a0, 16re2509b0, 16re298a60, 16re2e0ab0,
	16re328ab0, 16re370a50, 16re3b8990, 16re400870, 16re4486f0, 16re490520, 16re4d82f0, 16re520060, 16re567d70, 16re5afa30, 16re5f7680, 16re63f280,
	16re686e20, 16re6ce960, 16re716440, 16re75ded0, 16re7a5900, 16re7ed2c0, 16re834c30, 16re87c550, 16re8c3e00, 16re90b650, 16re952e50, 16re99a5e0,
	16re9e1d20, 16rea29400, 16rea70a80, 16reab80a0, 16reaff670, 16reb46bd0, 16reb8e0e0, 16rebd5580, 16rec1c9d0, 16rec63dc0, 16recab150, 16recf2480,
	16red39750, 16red809c0, 16redc7bd0, 16ree0ed90, 16ree55ee0, 16ree9cfe0, 16reee4070, 16ref2b0b0, 16ref72080, 16refb9000, 16reffff20, 16rf046de0,
	16rf08dc40, 16rf0d4a30, 16rf11b7d0, 16rf162510, 16rf1a91f0, 16rf1efe70, 16rf236a90, 16rf27d650, 16rf2c41b0, 16rf30acb0, 16rf351760, 16rf3981a0,
	16rf3deb80, 16rf425500, 16rf46be20, 16rf4b26e0, 16rf4f8f40, 16rf53f740, 16rf585ee0, 16rf5cc620, 16rf612d00, 16rf659380, 16rf69f9a0, 16rf6e5f50,
	16rf72c4b0, 16rf7729b0, 16rf7b8e50, 16rf7ff280, 16rf845660, 16rf88b9d0, 16rf8d1cf0, 16rf917fa0, 16rf95e200, 16rf9a43f0, 16rf9ea580, 16rfa306b0,
	16rfa76780, 16rfabc7f0, 16rfb02800, 16rfb487b0, 16rfb8e700, 16rfbd45e0, 16rfc1a470, 16rfc60290, 16rfca6050, 16rfcebdb0, 16rfd31ab0, 16rfd77750,
	16rfdbd390, 16rfe02f70, 16rfe48ae0, 16rfe8e600, 16rfed40b0, 16rff19b00, 16rff5f4f0, 16rffa4e80, 16rffea7b0, 16r10030080, 16r100758e0, 16r100bb0e0,
	16r10100880, 16r10145fc0, 16r1018b6a0, 16r101d0d20, 16r10216340, 16r1025b8e0, 16r102a0e40, 16r102e6320, 16r1032b7c0, 16r10370be0, 16r103b5fa0, 16r103fb300,
	16r10440600, 16r104858a0, 16r104caae0, 16r1050fcc0, 16r10554e40, 16r10599f40, 16r105df000, 16r10624040, 16r10669020, 16r106adfa0, 16r106f2ec0, 16r10737d80,
	16r1077cbe0, 16r107c19c0, 16r10806760, 16r1084b480, 16r10890160, 16r108d4dc0, 16r109199c0, 16r1095e560, 16r109a30a0, 16r109e7b60, 16r10a2c5e0, 16r10a70fe0,
	16r10ab59a0, 16r10afa2e0, 16r10b3ebc0, 16r10b83440, 16r10bc7c60, 16r10c0c400, 16r10c50b60, 16r10c95240, 16r10cd98e0, 16r10d1df00, 16r10d624c0, 16r10da6a00,
	16r10deaf00, 16r10e2f3a0, 16r10e737c0, 16r10eb7b80, 16r10efbee0, 16r10f401e0, 16r10f84480, 16r10fc86c0, 16r1100c880, 16r11050a00, 16r11094b00, 16r110d8ba0,
	16r1111cbe0, 16r11160ba0, 16r111a4b20, 16r111e8a20, 16r1122c8e0, 16r11270720, 16r112b4500, 16r112f8260, 16r1133bf80, 16r1137fc20, 16r113c3860, 16r11407460,
	16r1144afc0, 16r1148eae0, 16r114d25a0, 16r11515fe0, 16r115599c0, 16r1159d340, 16r115e0c60, 16r11624520, 16r11667d60, 16r116ab540, 16r116eece0, 16r11732400,
	16r11775aa0, 16r117b9100, 16r117fc6e0, 16r1183fc60, 16r11883180, 16r118c6640, 16r11909aa0, 16r1194ce80, 16r11990200, 16r119d3520, 16r11a167e0, 16r11a59a40,
	16r11a9cc20, 16r11adfdc0, 16r11b22ee0, 16r11b65fa0, 16r11ba8fe0, 16r11bebfe0, 16r11c2ef60, 16r11c71e80, 16r11cb4d40, 16r11cf7b80, 16r11d3a980, 16r11d7d700,
	16r11dc0420, 16r11e030e0, 16r11e45d20, 16r11e88920, 16r11ecb4a0, 16r11f0dfc0, 16r11f50a80, 16r11f934c0, 16r11fd5ec0, 16r12018840, 16r1205b160, 16r1209da00,
	16r120e0260, 16r12122a40, 16r121651c0, 16r121a78e0, 16r121e9f80, 16r1222c5e0, 16r1226ebc0, 16r122b1120, 16r122f3640, 16r12335b00, 16r12377f40, 16r123ba320,
	16r123fc680, 16r1243e9a0, 16r12480c40, 16r124c2e80, 16r12505060, 16r125471e0, 16r125892e0, 16r125cb380, 16r1260d3c0, 16r1264f3a0, 16r12691300, 16r126d3200,
	16r127150a0, 16r12756ee0, 16r12798ca0, 16r127daa00, 16r1281c700, 16r1285e3a0, 16r1289ffe0, 16r128e1ba0, 16r12923700, 16r12965200, 16r129a6c80, 16r129e86a0,
	16r12a2a060, 16r12a6b9c0, 16r12aad2c0, 16r12aeeb40, 16r12b30360, 16r12b71b20, 16r12bb3260, 16r12bf4940, 16r12c35fc0, 16r12c775e0, 16r12cb8b80, 16r12cfa0e0,
	16r12d3b5c0, 16r12d7ca20, 16r12dbde40, 16r12dff1e0, 16r12e40520, 16r12e81800, 16r12ec2a60, 16r12f03c60, 16r12f44e00, 16r12f85f40, 16r12fc7000, 16r13008060,
	16r13049060, 16r1308a000, 16r130caf20, 16r1310bde0, 16r1314cc40, 16r1318da20, 16r131ce7a0, 16r1320f4c0, 16r13250180, 16r13290de0, 16r132d19c0, 16r13312540,
	16r13353040, 16r13393b00, 16r133d4540, 16r13414f20, 16r13455880, 16r13496180, 16r134d6a20, 16r13517260, 16r13557a20, 16r135981a0, 16r135d88a0, 16r13618f20,
	16r13659540, 16r13699b20, 16r136da060, 16r1371a560, 16r1375a9e0, 16r1379ae00, 16r137db1c0, 16r1381b500, 16r1385b7e0, 16r1389ba60, 16r138dbc60, 16r1391be20,
	16r1395bf60, 16r1399c020, 16r139dc0a0, 16r13a1c0a0, 16r13a5c040, 16r13a9bf60, 16r13adbe40, 16r13b1bca0, 16r13b5ba80, 16r13b9b820, 16r13bdb540, 16r13c1b200,
	16r13c5ae40, 16r13c9aa20, 16r13cda5a0, 16r13d1a0c0, 16r13d59b60, 16r13d995c0, 16r13dd8f80, 16r13e18900, 16r13e58200, 16r13e97aa0, 16r13ed72e0, 16r13f16aa0,
	16r13f56200, 16r13f95900, 16r13fd4f80, 16r140145c0, 16r14053b60, 16r140930c0, 16r140d25a0, 16r14111a20, 16r14150e40, 16r141901e0, 16r141cf540, 16r1420e800,
	16r1424da80, 16r1428cc80, 16r142cbe20, 16r1430af60, 16r1434a020, 16r14389080, 16r143c8080, 16r14407000, 16r14445f20, 16r14484de0, 16r144c3c40, 16r14502a20,
	16r145417a0, 16r145804c0, 16r145bf160, 16r145fdda0, 16r1463c980, 16r1467b4e0, 16r146b9fe0, 16r146f8a80, 16r147374c0, 16r14775e80, 16r147b47e0, 16r147f30e0,
	16r14831960, 16r14870180, 16r148ae940, 16r148ed080, 16r1492b760, 16r14969de0, 16r149a8400, 16r149e69a0, 16r14a24ee0, 16r14a633a0, 16r14aa1820, 16r14adfc20,
	16r14b1dfa0, 16r14b5c2e0, 16r14b9a5a0, 16r14bd8800, 16r14c169e0, 16r14c54b60, 16r14c92c80, 16r14cd0d40, 16r14d0ed80, 16r14d4cd60, 16r14d8acc0, 16r14dc8be0,
	16r14e06a80, 16r14e448c0, 16r14e82680, 16r14ec03e0, 16r14efe0e0, 16r14f3bd60, 16r14f799a0, 16r14fb7540, 16r14ff50a0, 16r15032b80, 16r15070600, 16r150ae020,
	16r150eb9c0, 16r15129300, 16r15166be0, 16r151a4440, 16r151e1c60, 16r1521f3e0, 16r1525cb20, 16r1529a1e0, 16r152d7840, 16r15314e20, 16r153523c0, 16r1538f8e0,
	16r153ccd80, 16r1540a1e0, 16r154475c0, 16r15484920, 16r154c1c40, 16r154feee0, 16r1553c120, 16r155792e0, 16r155b6460, 16r155f3540, 16r156305e0, 16r1566d600,
	16r156aa5c0, 16r156e7520, 16r15724400, 16r15761280, 16r1579e0a0, 16r157dae40, 16r15817b80, 16r15854860, 16r158914e0, 16r158ce0e0, 16r1590ac80, 16r159477a0,
	16r15984280, 16r159c0ce0, 16r159fd6c0, 16r15a3a060, 16r15a76980, 16r15ab3220, 16r15aefa80, 16r15b2c260, 16r15b689e0, 16r15ba50e0, 16r15be1780, 16r15c1ddc0,
	16r15c5a3a0, 16r15c96900, 16r15cd2e00, 16r15d0f2a0, 16r15d4b6c0, 16r15d87a80, 16r15dc3de0, 16r15e000c0, 16r15e3c340, 16r15e78560, 16r15eb4720, 16r15ef0860,
	16r15f2c940, 16r15f689c0, 16r15fa49c0, 16r15fe0960, 16r1601c8a0, 16r16058760, 16r160945c0, 16r160d03c0, 16r1610c140, 16r16147e60, 16r16183b20, 16r161bf780,
	16r161fb360, 16r16236ee0, 16r16272a00, 16r162ae4a0, 16r162e9ee0, 16r163258c0, 16r16361220, 16r1639cb20, 16r163d83c0, 16r16413c00, 16r1644f3c0, 16r1648ab20,
	16r164c6220, 16r165018a0, 16r1653cec0, 16r16578480, 16r165b39c0, 16r165eeea0, 16r1662a320, 16r16665740, 16r166a0ae0, 16r166dbe20, 16r16717100, 16r16752360,
	16r1678d560, 16r167c8700, 16r16803820, 16r1683e8e0, 16r16879940, 16r168b4940, 16r168ef8c0, 16r1692a7e0, 16r169656a0, 16r169a04e0, 16r169db2c0, 16r16a16040,
	16r16a50d40, 16r16a8ba00, 16r16ac6620, 16r16b01200, 16r16b3bd60, 16r16b76860, 16r16bb1300, 16r16bebd40, 16r16c26700, 16r16c61060, 16r16c9b940, 16r16cd61c0,
	16r16d109e0, 16r16d4b1a0, 16r16d858e0, 16r16dbffe0, 16r16dfa640, 16r16e34c60, 16r16e6f200, 16r16ea9740, 16r16ee3c20, 16r16f1e080, 16r16f58480, 16r16f92820,
	16r16fccb60, 16r17006e20, 16r17041080, 16r1707b260, 16r170b5400, 16r170ef520, 16r171295e0, 16r17163620, 16r1719d600, 16r171d7580, 16r172114a0, 16r1724b340,
	16r17285180, 16r172bef60, 16r172f8ce0, 16r173329e0, 16r1736c680, 16r173a62c0, 16r173dfe80, 16r174199e0, 16r174534e0, 16r1748cf80, 16r174c69a0, 16r17500360,
	16r17539cc0, 16r175735a0, 16r175ace20, 16r175e6640, 16r1761fe00, 16r17659540, 16r17692c20, 16r176cc2a0, 16r177058c0, 16r1773ee60, 16r177783a0, 16r177b1880,
	16r177eace0, 16r178240e0, 16r1785d480, 16r178967c0, 16r178cfa80, 16r17908ce0, 16r17941ee0, 16r1797b080, 16r179b41a0, 16r179ed260, 16r17a262c0, 16r17a5f2a0,
	16r17a98220, 16r17ad1140, 16r17b0a000, 16r17b42e40, 16r17b7bc40, 16r17bb49c0, 16r17bed6c0, 16r17c26380, 16r17c5efc0, 16r17c97b80, 16r17cd0700, 16r17d09200,
	16r17d41ca0, 16r17d7a6e0, 16r17db30c0, 16r17deba20, 16r17e24320, 16r17e5cbc0, 16r17e953e0, 16r17ecdbc0, 16r17f06320, 16r17f3ea00, 16r17f770a0, 16r17faf6c0,
	16r17fe7c80, 16r180201e0, 16r180586c0, 16r18090b40, 16r180c8f60, 16r18101320, 16r18139680, 16r18171960, 16r181a9be0, 16r181e1e00, 16r18219fa0, 16r182520e0,
	16r1828a1c0, 16r182c2240, 16r182fa240, 16r18332200, 16r1836a140, 16r183a2000, 16r183d9e80, 16r18411c80, 16r18449a20, 16r18481760, 16r184b9440, 16r184f10a0,
	16r18528ca0, 16r18560840, 16r18598360, 16r185cfe40, 16r186078a0, 16r1863f2a0, 16r18676c20, 16r186ae560, 16r186e5e20, 16r1871d680, 16r18754e80, 16r1878c600,
	16r187c3d20, 16r187fb3e0, 16r18832a40, 16r1886a040, 16r188a15c0, 16r188d8ae0, 16r1890ffa0, 16r189473e0, 16r1897e7e0, 16r189b5b60, 16r189ece80, 16r18a24140,
	16r18a5b380, 16r18a92560, 16r18ac96e0, 16r18b00800, 16r18b378c0, 16r18b6e900, 16r18ba58e0, 16r18bdc860, 16r18c13780, 16r18c4a640, 16r18c81480, 16r18cb8260,
	16r18ceefe0, 16r18d25d00, 16r18d5c9a0, 16r18d935e0, 16r18dca1c0, 16r18e00d40, 16r18e37860, 16r18e6e300, 16r18ea4d40, 16r18edb720, 16r18f120a0, 16r18f489a0,
	16r18f7f260, 16r18fb5aa0, 16r18fec280, 16r190229e0, 16r19059100, 16r1908f7a0, 16r190c5de0, 16r190fc3c0, 16r19132940, 16r19168e40, 16r1919f2e0, 16r191d5740,
	16r1920bb00, 16r19241e80, 16r192781a0, 16r192ae440, 16r192e4680, 16r1931a860, 16r193509e0, 16r19386ae0, 16r193bcb80, 16r193f2be0, 16r19428ba0, 16r1945eb20,
	16r19494a40, 16r194ca8e0, 16r19500720, 16r19536500, 16r1956c280, 16r195a1fa0, 16r195d7c40, 16r1960d880, 16r19643460, 16r19678fe0, 16r196aeb00, 16r196e45a0,
	16r1971a000, 16r1974f9e0, 16r19785360, 16r197bac80, 16r197f0520, 16r19825d80, 16r1985b560, 16r19890ce0, 16r198c6400, 16r198fbac0, 16r19931100, 16r19966700,
	16r1999bc80, 16r199d11a0, 16r19a06660, 16r19a3bac0, 16r19a70ea0, 16r19aa6240, 16r19adb560, 16r19b10820, 16r19b45a80, 16r19b7ac60, 16r19bafe00, 16r19be4f20,
	16r19c1a000, 16r19c4f060, 16r19c84060, 16r19cb8fe0, 16r19cedf20, 16r19d22e00, 16r19d57c60, 16r19d8ca60, 16r19dc1800, 16r19df6540, 16r19e2b200, 16r19e5fe80,
	16r19e94a80, 16r19ec9640, 16r19efe180, 16r19f32c60, 16r19f676c0, 16r19f9c0e0, 16r19fd0a80, 16r1a0053e0, 16r1a039cc0, 16r1a06e540, 16r1a0a2d60, 16r1a0d7520,
	16r1a10bc60, 16r1a140360, 16r1a1749e0, 16r1a1a9000, 16r1a1dd5c0, 16r1a211b20, 16r1a246020, 16r1a27a4c0, 16r1a2ae8e0, 16r1a2e2cc0, 16r1a317020, 16r1a34b320,
	16r1a37f5c0, 16r1a3b3800, 16r1a3e79e0, 16r1a41bb40, 16r1a44fc60, 16r1a483d00, 16r1a4b7d40, 16r1a4ebd40, 16r1a51fcc0, 16r1a553bc0, 16r1a587a80, 16r1a5bb8e0,
	16r1a5ef6c0, 16r1a623460, 16r1a657180, 16r1a68ae40, 16r1a6beaa0, 16r1a6f26a0, 16r1a726240, 16r1a759d80, 16r1a78d840, 16r1a7c12c0, 16r1a7f4cc0, 16r1a828660,
	16r1a85bfc0, 16r1a88f8a0, 16r1a8c3120, 16r1a8f6920, 16r1a92a0e0, 16r1a95d840, 16r1a990f20, 16r1a9c45c0, 16r1a9f7be0, 16r1aa2b1a0, 16r1aa5e700, 16r1aa91c20,
	16r1aac50a0, 16r1aaf84e0, 16r1ab2b8c0, 16r1ab5ec40, 16r1ab91f40, 16r1abc5200, 16r1abf8440, 16r1ac2b620, 16r1ac5e7c0, 16r1ac918e0, 16r1acc49a0, 16r1acf7a00,
	16r1ad2a9e0, 16r1ad5d980, 16r1ad908c0, 16r1adc37a0, 16r1adf6600, 16r1ae29400, 16r1ae5c1c0, 16r1ae8ef00, 16r1aec1be0, 16r1aef4860, 16r1af27480, 16r1af5a040,
	16r1af8cba0, 16r1afbf6a0, 16r1aff2140, 16r1b024b80, 16r1b057540, 16r1b089ec0, 16r1b0bc7c0, 16r1b0ef080, 16r1b1218c0, 16r1b1540a0, 16r1b186840, 16r1b1b8f60,
	16r1b1eb620, 16r1b21dc80, 16r1b250280, 16r1b282820, 16r1b2b4d60, 16r1b2e7220, 16r1b3196a0, 16r1b34bac0, 16r1b37de60, 16r1b3b01c0, 16r1b3e24c0, 16r1b414740,
	16r1b446960, 16r1b478b40, 16r1b4aaca0, 16r1b4dcda0, 16r1b50ee60, 16r1b540ea0, 16r1b572e80, 16r1b5a4e00, 16r1b5d6d20, 16r1b608be0, 16r1b63aa40, 16r1b66c840,
	16r1b69e5e0, 16r1b6d0320, 16r1b702000, 16r1b733c80, 16r1b765880, 16r1b797440, 16r1b7c8fa0, 16r1b7faaa0, 16r1b82c520, 16r1b85df60, 16r1b88f940, 16r1b8c12a0,
	16r1b8f2bc0, 16r1b924460, 16r1b955cc0, 16r1b9874a0, 16r1b9b8c40, 16r1b9ea360, 16r1ba1ba20, 16r1ba4d0a0, 16r1ba7e6a0, 16r1baafc60, 16r1bae11a0, 16r1bb12680,
	16r1bb43b20, 16r1bb74f40, 16r1bba6300, 16r1bbd7680, 16r1bc08980, 16r1bc39c20, 16r1bc6ae60, 16r1bc9c060, 16r1bccd1e0, 16r1bcfe300, 16r1bd2f3e0, 16r1bd60440,
	16r1bd91440, 16r1bdc23e0, 16r1bdf3340, 16r1be24220, 16r1be550a0, 16r1be85ec0, 16r1beb6ca0, 16r1bee7a00, 16r1bf18700, 16r1bf493c0, 16r1bf7a000, 16r1bfaabe0,
	16r1bfdb780, 16r1c00c2a0, 16r1c03cd60, 16r1c06d7e0, 16r1c09e1e0, 16r1c0ceba0, 16r1c0ff4e0, 16r1c12fde0, 16r1c160660, 16r1c190ea0, 16r1c1c1660, 16r1c1f1de0,
	16r1c2224e0, 16r1c252ba0, 16r1c283200, 16r1c2b37e0, 16r1c2e3d80, 16r1c3142c0, 16r1c3447a0, 16r1c374c00, 16r1c3a5020, 16r1c3d53e0, 16r1c405740, 16r1c435a40,
	16r1c465ce0, 16r1c495f20, 16r1c4c6100, 16r1c4f6280, 16r1c5263a0, 16r1c556480, 16r1c5864e0, 16r1c5b64e0, 16r1c5e64a0, 16r1c6163e0, 16r1c6462c0, 16r1c676160,
	16r1c6a5f80, 16r1c6d5d60, 16r1c705ae0, 16r1c7357e0, 16r1c7654a0, 16r1c795100, 16r1c7c4d00, 16r1c7f48a0, 16r1c8243e0, 16r1c853ec0, 16r1c883940, 16r1c8b3360,
	16r1c8e2d40, 16r1c9126a0, 16r1c941fc0, 16r1c971860, 16r1c9a10c0, 16r1c9d08a0, 16r1ca00040, 16r1ca2f780, 16r1ca5ee60, 16r1ca8e4c0, 16r1cabdae0, 16r1caed0c0,
	16r1cb1c620, 16r1cb4bb20, 16r1cb7afc0, 16r1cbaa420, 16r1cbd9800, 16r1cc08ba0, 16r1cc37ec0, 16r1cc671a0, 16r1cc96420, 16r1ccc5640, 16r1ccf4800, 16r1cd23960,
	16r1cd52a60, 16r1cd81b20, 16r1cdb0b60, 16r1cddfb60, 16r1ce0eae0, 16r1ce3da20, 16r1ce6c900, 16r1ce9b780, 16r1ceca5a0, 16r1cef9360, 16r1cf280c0, 16r1cf56dc0,
	16r1cf85a80, 16r1cfb46c0, 16r1cfe32c0, 16r1d011e60, 16r1d040980, 16r1d06f460, 16r1d09df00, 16r1d0cc920, 16r1d0fb2e0, 16r1d129c40, 16r1d158560, 16r1d186e20,
	16r1d1b5680, 16r1d1e3e60, 16r1d212620, 16r1d240d60, 16r1d26f440, 16r1d29dac0, 16r1d2cc100, 16r1d2fa6e0, 16r1d328c40, 16r1d357160, 16r1d385620, 16r1d3b3aa0,
	16r1d3e1ea0, 16r1d410260, 16r1d43e5a0, 16r1d46c8a0, 16r1d49ab40, 16r1d4c8d80, 16r1d4f6f60, 16r1d5250e0, 16r1d553220, 16r1d5812e0, 16r1d5af360, 16r1d5dd380,
	16r1d60b340, 16r1d6392a0, 16r1d6671c0, 16r1d695060, 16r1d6c2ec0, 16r1d6f0cc0, 16r1d71ea60, 16r1d74c7a0, 16r1d77a480, 16r1d7a8120, 16r1d7d5d40, 16r1d803920,
	16r1d8314a0, 16r1d85efc0, 16r1d88ca80, 16r1d8ba500, 16r1d8e7f00, 16r1d9158c0, 16r1d943220, 16r1d970b20, 16r1d99e3e0, 16r1d9cbc20, 16r1d9f9420, 16r1da26bc0,
	16r1da54300, 16r1da819e0, 16r1daaf060, 16r1dadc6a0, 16r1db09c60, 16r1db371e0, 16r1db64700, 16r1db91be0, 16r1dbbf040, 16r1dbec460, 16r1dc19820, 16r1dc46b80,
	16r1dc73e80, 16r1dca1120, 16r1dcce380, 16r1dcfb580, 16r1dd28720, 16r1dd55860, 16r1dd82940, 16r1ddaf9e0, 16r1dddca20, 16r1de09a00, 16r1de36980, 16r1de638a0,
	16r1de90780, 16r1debd600, 16r1deea420, 16r1df171e0, 16r1df43f40, 16r1df70c60, 16r1df9d920, 16r1dfca580, 16r1dff7180, 16r1e023d40, 16r1e0508a0, 16r1e07d3a0,
	16r1e0a9e40, 16r1e0d6880, 16r1e103280, 16r1e12fc20, 16r1e15c560, 16r1e188e40, 16r1e1b56e0, 16r1e1e1f00, 16r1e20e6e0, 16r1e23ae80, 16r1e2675a0, 16r1e293c80,
	16r1e2c0300, 16r1e2ec920, 16r1e318ee0, 16r1e345460, 16r1e371980, 16r1e39de40, 16r1e3ca2a0, 16r1e3f66c0, 16r1e422a80, 16r1e44ede0, 16r1e47b0e0, 16r1e4a73a0,
	16r1e4d3600, 16r1e4ff800, 16r1e52b9a0, 16r1e557b00, 16r1e583c00, 16r1e5afca0, 16r1e5dbce0, 16r1e607ce0, 16r1e633c80, 16r1e65fbc0, 16r1e68baa0, 16r1e6b7940,
	16r1e6e3780, 16r1e70f560, 16r1e73b300, 16r1e767020, 16r1e792d00, 16r1e7be9a0, 16r1e7ea5c0, 16r1e8161a0, 16r1e841d20, 16r1e86d840, 16r1e899320, 16r1e8c4da0,
	16r1e8f07c0, 16r1e91c1a0, 16r1e947b00, 16r1e973440, 16r1e99ed00, 16r1e9ca560, 16r1e9f5d80, 16r1ea21560, 16r1ea4ccc0, 16r1ea783e0, 16r1eaa3aa0, 16r1eacf100,
	16r1eafa720, 16r1eb25ce0, 16r1eb51240, 16r1eb7c760, 16r1eba7c20, 16r1ebd3080, 16r1ebfe480, 16r1ec29840, 16r1ec54ba0, 16r1ec7fea0, 16r1ecab160, 16r1ecd63c0,
	16r1ed015c0, 16r1ed2c780, 16r1ed578e0, 16r1ed829e0, 16r1edada80, 16r1edd8ae0, 16r1ee03ae0, 16r1ee2eaa0, 16r1ee59a00, 16r1ee84900, 16r1eeaf7a0, 16r1eeda600,
	16r1ef05400, 16r1ef301a0, 16r1ef5af00, 16r1ef85c00, 16r1efb08c0, 16r1efdb500, 16r1f006100, 16r1f030cc0, 16r1f05b800, 16r1f086300, 16r1f0b0dc0, 16r1f0db820,
	16r1f106220, 16r1f130bc0, 16r1f15b520, 16r1f185e20, 16r1f1b06c0, 16r1f1daf20, 16r1f205720, 16r1f22fee0, 16r1f25a620, 16r1f284d40, 16r1f2af3e0, 16r1f2d9a40,
	16r1f304040, 16r1f32e600, 16r1f358b60, 16r1f383060, 16r1f3ad500, 16r1f3d7960, 16r1f401d80, 16r1f42c120, 16r1f4564a0, 16r1f4807a0, 16r1f4aaa60, 16r1f4d4cc0,
	16r1f4feee0, 16r1f529080, 16r1f553200, 16r1f57d300, 16r1f5a73c0, 16r1f5d1440, 16r1f5fb460, 16r1f625420, 16r1f64f380, 16r1f6792a0, 16r1f6a3160, 16r1f6ccfe0,
	16r1f6f6e00, 16r1f720be0, 16r1f74a940, 16r1f774680, 16r1f79e340, 16r1f7c7fc0, 16r1f7f1c00, 16r1f81b7c0, 16r1f845340, 16r1f86ee80, 16r1f898960, 16r1f8c23e0,
	16r1f8ebe20, 16r1f915800, 16r1f93f1a0, 16r1f968ae0, 16r1f9923c0, 16r1f9bbc60, 16r1f9e54a0, 16r1fa0ec80, 16r1fa38420, 16r1fa61b80, 16r1fa8b280, 16r1fab4920,
	16r1faddf60, 16r1fb07560, 16r1fb30b20, 16r1fb5a080, 16r1fb83580, 16r1fbaca40, 16r1fbd5ea0, 16r1fbff2a0, 16r1fc28660, 16r1fc519e0, 16r1fc7ace0, 16r1fca3fc0,
	16r1fccd220, 16r1fcf6440, 16r1fd1f620, 16r1fd487a0, 16r1fd718c0, 16r1fd9a9a0, 16r1fdc3a20, 16r1fdeca60, 16r1fe15a40, 16r1fe3e9e0, 16r1fe67920, 16r1fe90800,
	16r1feb96a0, 16r1fee24e0, 16r1ff0b2e0, 16r1ff34080, 16r1ff5cde0, 16r1ff85ae0, 16r1ffae7a0, 16r1ffd7400, 16r20000000
		};
	mobjs = array[0] of ref Mobj;
	thinkers = array[0] of ref Thinker;
	activeplats = array[0] of ref Thinker;
	buttonlist = array[MAXBUTTONS] of ref Button;
	for (bi := 0; bi < MAXBUTTONS; bi++)
		buttonlist[bi] = ref Button(-1, 0, "", 0);
	spechit = array[MAXSPECIALCROSS] of int;
	nspechit = 0;
	exited = 0;
	sexited = 0;
	# weapon ammo types (d_items.c weaponinfo order) and clip-load
	# sizes (p_inter.c clipammo); AM_NOAMMO (4) never granted
	weaponammo = array[] of {
		AM_NOAMMO, AM_CLIP, AM_SHELL, AM_CLIP, AM_MISL,
		AM_CELL, AM_CELL, AM_NOAMMO, AM_SHELL,
	};
	clipammo = array[] of { 10, 4, 20, 1 };
	switchpairs = array[] of {
		("SW1BRCOM", "SW2BRCOM"),
		("SW1BRN1", "SW2BRN1"),
		("SW1BRN2", "SW2BRN2"),
		("SW1BRNGN", "SW2BRNGN"),
		("SW1BROWN", "SW2BROWN"),
		("SW1COMM", "SW2COMM"),
		("SW1COMP", "SW2COMP"),
		("SW1DIRT", "SW2DIRT"),
		("SW1EXIT", "SW2EXIT"),
		("SW1GRAY", "SW2GRAY"),
		("SW1GRAY1", "SW2GRAY1"),
		("SW1METAL", "SW2METAL"),
		("SW1PIPE", "SW2PIPE"),
		("SW1SLAD", "SW2SLAD"),
		("SW1STARG", "SW2STARG"),
		("SW1STON1", "SW2STON1"),
		("SW1STON2", "SW2STON2"),
		("SW1STONE", "SW2STONE"),
		("SW1STRTN", "SW2STRTN"),
	};
	players = array[MAXPLAYERS] of ref Player;
	lvltime = 0;
	prndindex = 0;
	# resolve the A_Fall action index for doaction (all other A_*
	# stay no-ops until the M11/12 dispatch table)
	ACT_FALL = -1;
	for (i := 0; i < len inf->actnames; i++)
		if (inf->actnames[i] == "A_Fall")
			ACT_FALL = i;
	return nil;
}

prandom(): int
{
	prndindex = (prndindex + 1) & 255;
	return inf->rndtable[prndindex];
}

absi(a: int): int
{
	if (a < 0)
		return -a;
	return a;
}

# explicit zero-fill: array allocs in this emu come back with dirty
# heap memory (measured 1.4e9-range garbage in fresh array[6] of
# int), so anything not fully written at alloc must be zeroed
# (vanilla Z_Malloc zeroes; lock checks read cards[] raw).
zeroarr(a: array of int)
{
	for (i := 0; i < len a; i++)
		a[i] = 0;
}

approxdistance(x, y: int): int
{
	x = absi(x);
	y = absi(y);
	if (x < y)
		return x + y - (x >> 1);
	return y + x - (y >> 1);
}

# ---------------------------------------------------------------------------
# level setup / spawning
# ---------------------------------------------------------------------------

setuplevel(l: ref Map->Level, skill: int): string
{
	if (l == nil)
		return "setuplevel: nil map";
	lev = l;
	gameskill = skill;
	gamemapnum = 0;
	if (len l.name == 4 && l.name[0] == 'E' && l.name[2] == 'M') {
		# shareware ExMy: map digit at [3] (1-9)
		gamemapnum = int l.name[3] - int '0';
		if (gamemapnum < 1 || gamemapnum > 9)
			gamemapnum = 0;
	}
	lvltime = 0;
	totalkills = 0;
	totalitems = 0;
	mobjs = array[0] of ref Mobj;
	thinkers = array[0] of ref Thinker;
	activeplats = array[0] of ref Thinker;
	for (bi := 0; bi < MAXBUTTONS; bi++)
		buttonlist[bi] = ref Button(-1, 0, "", 0);
	nspechit = 0;
	exited = 0;
	sexited = 0;
	for (i := 0; i < MAXPLAYERS; i++)
		players[i] = nil;

	for (i = 0; i < len l.things; i++)
		spawnmapthing(l.things[i]);
	spawnspecialsectors();
	# vanilla P_SpawnSpecials (line-effects subset): collect scroll-
	# left lines (special 48).  Full special dispatch is milestone
	# 13; scrolling needs no thinker, just the list.
	scrolllines = array[64] of int;
	nscrolllines = 0;
	for (i = 0; i < len l.lines; i++)
		if (l.lines[i].special == 48 && nscrolllines < 64) {
			scrolllines[nscrolllines] = i;
			nscrolllines++;
		}
	return nil;
}

spawnmapthing(t: Thing)
{
	if (t.typ == 11)		# deathmatch start; ignored for now
		return;
	if (t.typ <= 0)
		return;
	# player start: vanilla R_SpawnMapThing only turns slots into
	# players when playeringame[skill slot] is set; single-player has
	# only start 1.  spawning 2-4 as mobjs put three extra doom guys
	# at the E1M1 start.
	if (t.typ <= 4) {
		if (t.typ == 1)
			spawnplayer(t);
		return;
	}

	# netgame is false: skip single-player-excluded things
	if ((t.options & MTF_NOTSINGLE) != 0)
		return;

	bit := 1 << (gameskill - 1);
	if (gameskill == SK_BABY)
		bit = MTF_EASY;
	else if (gameskill == SK_NIGHTMARE)
		bit = MTF_HARD;
	if ((t.options & bit) == 0)
		return;

	# find mobjinfo by doomednum
	i := 0;
	for (i = 0; i < inf->NUMMOBJTYPES; i++)
		if (t.typ == inf->mobjinfo[i].doomednum)
			break;
	if (i >= inf->NUMMOBJTYPES)
		return;			# unknown type: skip (vanilla I_Errors)

	z := ONFLOORZ;
	if ((inf->mobjinfo[i].flags & inf->MF_SPAWNCEILING) != 0)
		z = ONCEILINGZ;

	mo := spawnmobj(t.x, t.y, z, i);
	mo.spawnpoint = t;
	if (mo.tics > 0)
		mo.tics = 1 + (prandom() % mo.tics);
	if ((mo.flags & inf->MF_COUNTKILL) != 0)
		totalkills++;
	if ((mo.flags & inf->MF_COUNTITEM) != 0)
		totalitems++;
	mo.angle = ANG45 * (t.angle / 45);
	if ((t.options & MTF_AMBUSH) != 0)
		mo.flags = mo.flags | inf->MF_AMBUSH;
}

spawnplayer(t: Thing)
{
	i := t.typ - 1;
	if (i < 0 || i >= MAXPLAYERS)
		return;
	if (players[i] == nil) {
		np := ref Player(nil, Ticcmd(0, 0, 0, 0), PST_REBORN,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			nil, nil, nil, nil, nil,
			0, 0, nil, 0, 0, 0, nil);
		players[i] = np;
	}
	p := players[i];
	if (p.playerstate == PST_REBORN)
		playerreborn(p);

	mo := spawnmobj(t.x, t.y, ONFLOORZ, inf->MT_PLAYER);
	if (t.typ > 1)
		mo.flags = mo.flags | ((t.typ - 1) << inf->MF_TRANSSHIFT);
	mo.angle = ANG45 * (t.angle / 45);
	mo.player = p;
	mo.health = p.health;
	p.mo = mo;
	p.playerstate = PST_LIVE;
	p.viewheight = VIEWHEIGHT;
}

playerreborn(p: ref Player)
{
	# minimal: G_PlayerReborn without dehacked/frag carry-over
	p.playerstate = PST_LIVE;
	p.health = 100;
	p.readyweapon = WP_PISTOL;
	p.pendingweapon = WP_PISTOL;
	p.weaponowned = array[NUMWEAPONS] of int;
	zeroarr(p.weaponowned);
	p.weaponowned[WP_FIST] = 1;
	p.weaponowned[WP_PISTOL] = 1;
	p.ammo = array[NUMAMMO] of int;
	zeroarr(p.ammo);
	p.ammo[AM_CLIP] = 50;
	p.maxammo = array[NUMAMMO] of int;
	zeroarr(p.maxammo);
	p.maxammo[AM_CLIP] = 200;
	p.maxammo[AM_SHELL] = 50;
	p.maxammo[AM_CELL] = 300;
	p.maxammo[AM_MISL] = 50;
	p.frags = array[MAXPLAYERS] of int;
	zeroarr(p.frags);
	p.cards = array[NUMCARDS] of int;
	zeroarr(p.cards);
	p.armorpoints = 0;
	p.armortype = 0;
	p.powers = array[NUMPOWERS] of int;
	zeroarr(p.powers);
	p.backpack = 0;
	p.bonuscount = 0;
	p.damagecount = 0;
	p.attacker = nil;
	p.usedown = 1;
	p.attackdown = 1;
	p.killcount = 0;
	p.itemcount = 0;
	p.secretcount = 0;
}

spawnmobj(x, y, z, typ: int): ref Mobj
{
	mi := inf->mobjinfo[typ];
	st := inf->states[mi.spawnstate];
	rl := 0;
	if (gameskill != SK_NIGHTMARE)
		rl = mi.reactiontime;
	mo := ref Mobj(typ, mi, x, y, 0, 0,
		0, 0, 0,
		mi.radius, mi.height, mi.flags, mi.spawnhealth,
		mi.spawnstate, st.sprite, st.frame, st.tics,
		rl, prandom() % MAXPLAYERS,
		Thing(0, 0, 0, 0, 0), nil, 0, 0,
		nil, nil, 0,
		0, 0, 0);

	setthingposition(mo);
	mo.floorz = mo.subsector.sector.floorheight;
	mo.ceilingz = mo.subsector.sector.ceilingheight;
	if (z == ONFLOORZ)
		mo.z = mo.floorz;
	else if (z == ONCEILINGZ)
		mo.z = mo.ceilingz - mo.info.height;
	else
		mo.z = z;

	n := len mobjs;
	nm := array[n + 1] of ref Mobj;
	if (n > 0)
		nm[0:] = mobjs;
	nm[n] = mo;
	mobjs = nm;
	return mo;
}

setthingposition(mo: ref Mobj)
{
	ss := lev.pointsubsector(mo.x, mo.y);
	if (ss == nil)
		fail("setthingposition: no subsector");
	mo.subsector = ss;
	# milestone 5: no sector thinglist / blockmap links
}

removemobj(mo: ref Mobj)
{
	mo.removed = 1;
	mo.state = inf->S_NULL;
}

# ---------------------------------------------------------------------------
# state / thinkers
# ---------------------------------------------------------------------------

setmobjstate(mo: ref Mobj, state: int): int
{
	s := state;
	for (;;) {
		if (s == inf->S_NULL) {
			mo.state = inf->S_NULL;
			removemobj(mo);
			return 0;
		}
		st := inf->states[s];
		mo.state = s;
		mo.tics = st.tics;
		mo.sprite = st.sprite;
		mo.frame = st.frame;
		doaction(mo, st.action);
		s = st.nextstate;
		if (mo.tics != 0)
			return 1;
	}
}

doaction(mo: ref Mobj, act: int)
{
	if (act == 0)
		return;
	if (act == ACT_FALL) {
		# vanilla A_Fall (p_enemy.c): the corpse hits the ground
		# and stops blocking movement ("actor is on ground, it can
		# be walked over").  Fires mid-death-animation (zombie:
		# DIE3, 10 tics after the kill), so fresh corpses still
		# block like vanilla.  First live A_* action; the M11/12
		# dispatch table follows.
		mo.flags = mo.flags & ~inf->MF_SOLID;
		return;
	}
	# milestone 5 stub: remaining A_Look/A_Chase/weapon routines
	# come with the AI and psprite milestones; states still
	# advance by tics.
}

explodemissile(mo: ref Mobj)
{
	mo.momx = 0;
	mo.momy = 0;
	mo.momz = 0;
	setmobjstate(mo, mo.info.deathstate);
	mo.tics = mo.tics - (prandom() & 3);
	if (mo.tics < 1)
		mo.tics = 1;
	mo.flags = mo.flags & ~inf->MF_MISSILE;
}

mobjthinker(mo: ref Mobj)
{
	if (mo.momx != 0 || mo.momy != 0 || (mo.flags & inf->MF_SKULLFLY) != 0) {
		xymovement(mo);
		if (mo.removed)
			return;
	}
	if (mo.z != mo.floorz || mo.momz != 0) {
		zmovement(mo);
		if (mo.removed)
			return;
	}
	if (mo.tics != -1) {
		mo.tics = mo.tics - 1;
		if (mo.tics == 0) {
			if (!setmobjstate(mo, inf->states[mo.state].nextstate))
				return;
		}
	}
}

runthinkers()
{
	# snapshot the list: thinkers may spawn; removed are compacted
	n := len mobjs;
	if (n != 0) {
		snap := array[n] of ref Mobj;
		snap[0:] = mobjs;
		for (i := 0; i < n; i++) {
			mo := snap[i];
			if (mo.removed)
				continue;
			mobjthinker(mo);
		}
		# compact removed (lazy unlink, vanilla P_RunThinkers free).
		# thinkers spawned mid-pass live past snap (missiles, fogs,
		# gibs): vanilla's linked list keeps them, so append live
		# mobjs[n:] survivors after the filtered snapshot.
		kept := 0;
		for (i = 0; i < n; i++)
			if (!snap[i].removed)
				kept++;
		keptx := 0;
		for (i = n; i < len mobjs; i++)
			if (!mobjs[i].removed)
				keptx++;
		nm := array[kept + keptx] of ref Mobj;
		k := 0;
		for (i = 0; i < n; i++)
			if (!snap[i].removed) {
				nm[k] = snap[i];
				k++;
			}
		for (i = n; i < len mobjs; i++)
			if (!mobjs[i].removed) {
				nm[k] = mobjs[i];
				k++;
			}
		mobjs = nm;
	}

	# sector thinkers (doors for now).  No compaction here:
	# sectors hold thinker indices (specialdata), so slots must
	# stay stable; removed thinkers are just skipped (a level
	# creates only a handful).
	nt := len thinkers;
	for (i := 0; i < nt; i++) {
		th := thinkers[i];
		if (th.removed)
			continue;
		if (th.kind == THINK_DOOR)
			tverticaldoor(th);
		else if (th.kind == THINK_FLOOR)
			tmovefloor(th);
		else if (th.kind == THINK_PLAT)
			tplatraise(th);
		else if (th.kind == THINK_LIGHT)
			tlightthink(th);
	}
}

# ---------------------------------------------------------------------------
# sector movers: doors + use-lines (milestone 13 slice).
# Reference: doomgeneric p_floor.c (T_MovePlane), p_maputl.c
# (PIT_ChangeSector, P_ThingHeightClip), p_doors.c, p_spec.c
# (P_UseLines, PTR_UseTraverse, P_UseSpecialLine), p_switch.c
# (manual door cases).  Transcribed line-for-line except: thinker
# list is separate from mobjs (no unlink dance; sectors hold
# stable indices), brute-force line/sector scans (no blockmap,
# no sec->lines), damage-on-crush deferred to milestone 9
# (P_ChangeSector never damages yet), monster door-use deferred
# to AI (milestone 12), sounds are stubs.
# ---------------------------------------------------------------------------

# vanilla P_FindLowestCeilingSurrounding (p_floor.c) over all lines
findlowestceilingsurrounding(sec: ref Map->Sector): int
{
	height := ONCEILINGZ;
	for (i := 0; i < len lev.lines; i++) {
		ld := lev.lines[i];
		other := ld.frontsector;
		if (ld.frontsector == sec) {
			if (ld.backsector == sec)
				continue;	# self-referencing: getNextSector nil
			other = ld.backsector;
		} else if (ld.backsector == sec) {
			other = ld.frontsector;
		} else
			continue;		# line doesn't touch sec
		if (other == nil)
			continue;
		if (other.ceilingheight < height)
			height = other.ceilingheight;
	}
	return height;
}

# vanilla P_ThingHeightClip (p_maputl.c): refit mo to its sector
# stack after a height change; returns fit (1) or crushed (0).
# The checkposition result is discarded like vanilla (globals keep
# partial state, recomputed on revert).
thingheightclip(mo: ref Mobj): int
{
	onfloor := 0;
	if (mo.z == mo.floorz)
		onfloor = 1;
	checkposition(mo, mo.x, mo.y);
	mo.floorz = tmfloorz;
	mo.ceilingz = tmceilingz;
	if (onfloor != 0)
		mo.z = mo.floorz;
	else if (mo.z + mo.height > mo.ceilingz)
		mo.z = mo.ceilingz - mo.height;
	if (mo.ceilingz - mo.floorz >= mo.height)
		return 1;
	return 0;
}

# vanilla PIT_ChangeSector (p_maputl.c): 1 = keep scanning, 0 = nofit
pitchangesector(mo: ref Mobj): int
{
	if (thingheightclip(mo) != 0)
		return 1;
	if (mo.health <= 0) {		# gib stuck corpses (no damage yet)
		setmobjstate(mo, inf->S_GIBS);
		mo.flags = mo.flags & ~inf->MF_SOLID;
		mo.height = 0;
		mo.radius = 0;
		return 1;
	}
	if ((mo.flags & inf->MF_DROPPED) != 0) {
		removemobj(mo);		# unreachable in shareware
		return 1;
	}
	if ((mo.flags & inf->MF_SHOOTABLE) == 0)
		return 1;
	return 0;
}

# vanilla P_ChangeSector (p_floor.c): refit every thing in sec;
# returns nofit (1 = blocked/crushed)
pchangesector(sec: ref Map->Sector): int
{
	nofit := 0;
	for (i := 0; i < len mobjs; i++) {
		mo := mobjs[i];
		if (mo.removed)
			continue;
		if (mo.subsector == nil)
			continue;
		if (!(mo.subsector.sector == sec))
			continue;
		if (pitchangesector(mo) == 0)
			nofit = 1;
	}
	return nofit;
}

# vanilla T_MovePlane (p_floor.c): move sec floor (floor != 0) or
# ceiling toward dest at speed; RES_OK / RES_CRUSHED / RES_PASTDEST
tmoveplane(sec: ref Map->Sector, speed, dest: int, crush, floor, direction: int): int
{
	lastpos := 0;
	if (floor != 0) {
		if (direction == -1) {		# DOWN
			if (sec.floorheight - speed < dest) {
				lastpos = sec.floorheight;
				sec.floorheight = dest;
				if (pchangesector(sec) != 0) {
					sec.floorheight = lastpos;
					pchangesector(sec);
				}
				return RES_PASTDEST;
			}
			lastpos = sec.floorheight;
			sec.floorheight = sec.floorheight - speed;
			if (pchangesector(sec) != 0) {
				sec.floorheight = lastpos;
				pchangesector(sec);
				return RES_CRUSHED;
			}
			return RES_OK;
		}
		if (sec.floorheight + speed > dest) {	# UP
			lastpos = sec.floorheight;
			sec.floorheight = dest;
			if (pchangesector(sec) != 0) {
				sec.floorheight = lastpos;
				pchangesector(sec);
			}
			return RES_PASTDEST;
		}
		lastpos = sec.floorheight;
		sec.floorheight = sec.floorheight + speed;
		pchangesector(sec);
		return RES_OK;
	}
	if (direction == -1) {		# CEILING DOWN
		if (sec.ceilingheight - speed < dest) {
			lastpos = sec.ceilingheight;
			sec.ceilingheight = dest;
			if (pchangesector(sec) != 0) {
				sec.ceilingheight = lastpos;
				pchangesector(sec);
			}
			return RES_PASTDEST;
		}
		lastpos = sec.ceilingheight;
		sec.ceilingheight = sec.ceilingheight - speed;
		if (pchangesector(sec) != 0) {
			if (crush != 0)
				return RES_CRUSHED;	# stay crushed (milestone 9)
			sec.ceilingheight = lastpos;
			pchangesector(sec);
			return RES_CRUSHED;
		}
		return RES_OK;
	}
	if (sec.ceilingheight + speed > dest) {	# CEILING UP
		lastpos = sec.ceilingheight;
		sec.ceilingheight = dest;
		if (pchangesector(sec) != 0) {
			sec.ceilingheight = lastpos;
			pchangesector(sec);
		}
		return RES_PASTDEST;
	}
	lastpos = sec.ceilingheight;
	sec.ceilingheight = sec.ceilingheight + speed;
	pchangesector(sec);
	return RES_OK;
}

# vanilla T_VerticalDoor (p_doors.c); th carries the Door plus the
# removal flag (lazy unlink instead of P_RemoveThinker)
tverticaldoor(th: ref Thinker)
{
	d := th.door;
	sec := d.sec;
	if (d.direction == 0) {		# WAITING at top
		d.topcountdown = d.topcountdown - 1;
		if (d.topcountdown == 0) {
			if (d.dtype == VLD_BLAZERAISE) {
				d.direction = -1;
				sound->startsound(0, 0, sound->SFX_BDCLS);
			} else if (d.dtype == VLD_NORMAL) {
				d.direction = -1;
				sound->startsound(0, 0, sound->SFX_DORCLS);
			} else if (d.dtype == VLD_CLOSE30THENOPEN) {
				d.direction = 1;
				sound->startsound(0, 0, sound->SFX_DOROPN);
			}
			# open/blazeOpen/close/raiseIn5Mins: wait forever
		}
		return;
	}
	if (d.direction == 2) {		# INITIAL WAIT (raiseIn5Mins only)
		d.topcountdown = d.topcountdown - 1;
		if (d.topcountdown != 0)
			return;
		if (d.dtype == VLD_RAISEIN5MINS) {
			d.direction = 1;
			d.dtype = VLD_NORMAL;
			sound->startsound(0, 0, sound->SFX_DOROPN);
		}
		return;
	}
	if (d.direction == -1) {	# DOWN
		res := tmoveplane(sec, d.speed, sec.floorheight, 0, 0, d.direction);
		if (res == RES_PASTDEST) {
			if (d.dtype == VLD_BLAZERAISE || d.dtype == VLD_BLAZECLOSE) {
				sec.specialdata = -1;
				th.removed = 1;
				sound->startsound(0, 0, sound->SFX_BDCLS);
			} else if (d.dtype == VLD_NORMAL || d.dtype == VLD_CLOSE) {
				sec.specialdata = -1;
				th.removed = 1;
			} else if (d.dtype == VLD_CLOSE30THENOPEN) {
				d.direction = 0;
				d.topcountdown = 30 * TICRATE;
			}
		} else if (res == RES_CRUSHED) {
			if (d.dtype == VLD_BLAZECLOSE || d.dtype == VLD_CLOSE) {
			} else {
				d.direction = 1;
				sound->startsound(0, 0, sound->SFX_DOROPN);
			}
		}
		return;
	}
	res := tmoveplane(sec, d.speed, d.topheight, 0, 0, d.direction);
	if (res == RES_PASTDEST) {
		if (d.dtype == VLD_BLAZERAISE || d.dtype == VLD_NORMAL) {
			d.direction = 0;	# wait at top, then close
			d.topcountdown = d.topwait;
		} else if (d.dtype == VLD_CLOSE30THENOPEN || d.dtype == VLD_BLAZEOPEN ||
		    d.dtype == VLD_OPEN) {
			sec.specialdata = -1;
			th.removed = 1;
		}
	}
}

# vanilla EV_DoLockedDoor (p_doors.c): card/skull check for
# 26/27/28/32/33/34; 1 = may proceed
evdolockeddoor(li: int, mo: ref Mobj): int
{
	ld := lev.lines[li];
	p := mo.player;
	if (p == nil)
		return 0;
	if (ld.special == 26 || ld.special == 32) {
		if (p.cards[IT_BLUECARD] == 0 && p.cards[IT_BLUESKULL] == 0) {
			sound->startsound(mo.x, mo.y, sound->SFX_OOF);
			return 0;
		}
	}
	if (ld.special == 27 || ld.special == 34) {
		if (p.cards[IT_YELLOWCARD] == 0 && p.cards[IT_YELLOWSKULL] == 0) {
			sound->startsound(mo.x, mo.y, sound->SFX_OOF);
			return 0;
		}
	}
	if (ld.special == 28 || ld.special == 33) {
		if (p.cards[IT_REDCARD] == 0 && p.cards[IT_REDSKULL] == 0) {
			sound->startsound(mo.x, mo.y, sound->SFX_OOF);
			return 0;
		}
	}
	return 1;
}

# vanilla EV_VerticalDoor (p_doors.c): manual + retrigger use;
# side forced 0 (front), so the door sector is sides[1]
evverticaldoor(li: int, mo: ref Mobj): int
{
	ld := lev.lines[li];
	if (ld.sides[1] == nil)
		return 0;
	sec := ld.sides[1].sector;
	if (sec == nil)
		return 0;
	if (sec.specialdata != -1) {	# active thinker: flip or close
		d := thinkers[sec.specialdata].door;
		if (d.dtype == VLD_NORMAL || d.dtype == VLD_CLOSE30THENOPEN ||
		    d.dtype == VLD_BLAZERAISE || d.dtype == VLD_BLAZEOPEN ||
		    d.dtype == VLD_BLAZECLOSE ||
		    ld.special == 1 || ld.special == 26 || ld.special == 27 ||
		    ld.special == 28 || ld.special == 117) {
			if (d.direction == -1)
				d.direction = 1;	# start opening again
			else {
				if (mo.player == nil)
					return 0;	# monsters don't close
				d.direction = -1;
				sound->startsound(0, 0, sound->SFX_DORCLS);
			}
			return 1;
		}
		return 0;
	}
	if (ld.special == 26 || ld.special == 27 || ld.special == 28 ||
	    ld.special == 32 || ld.special == 33 || ld.special == 34) {
		if (evdolockeddoor(li, mo) == 0)
			return 0;
	}
	d := ref Door;
	d.sec = sec;
	d.direction = 1;
	d.topwait = VDOORWAIT;
	d.speed = VDOORSPEED;
	if (ld.special == 117 || ld.special == 118) {
		d.speed = 4 * FRACUNIT;
		sound->startsound(0, 0, sound->SFX_BDOPN);
	} else
		sound->startsound(0, 0, sound->SFX_DOROPN);
	if (ld.special == 1 || ld.special == 26 || ld.special == 27 ||
	    ld.special == 28)
		d.dtype = VLD_NORMAL;
	else if (ld.special == 31 || ld.special == 32 || ld.special == 33 ||
	    ld.special == 34) {
		d.dtype = VLD_OPEN;
		sec.special = 0;
	} else if (ld.special == 117)
		d.dtype = VLD_BLAZEOPEN;
	else					# 118
		d.dtype = VLD_BLAZEOPEN;
	if (d.dtype == VLD_OPEN || d.dtype == VLD_BLAZEOPEN)
		d.topheight = findlowestceilingsurrounding(sec);
	else
		d.topheight = findlowestceilingsurrounding(sec) - 4 * FRACUNIT;
	d.topcountdown = 0;
	th := ref Thinker(THINK_DOOR, d, nil, nil, nil, 0);
	sectorthinker(sec, th);
	return 1;
}

# vanilla EV_DoDoor (p_doors.c): tag-loop door spawner.  Only open
# (and normal, same body) this slice; other types with theirs.
# Sectors already moving are skipped, like vanilla.
evdodoor(li, dtype: int): int
{
	rtn := 0;
	secnum := findsectorfromlinetag(li, -1);
	while (secnum >= 0) {
		sec := lev.sectors[secnum];
		if (sec.specialdata == -1) {
			rtn = 1;
			d := ref Door;
			d.sec = sec;
			d.dtype = dtype;
			d.topwait = VDOORWAIT;
			d.speed = VDOORSPEED;
			d.topcountdown = 0;
			if (dtype == VLD_CLOSE30THENOPEN) {
				d.topheight = sec.ceilingheight;
				d.direction = -1;
				sound->startsound(0, 0, sound->SFX_DORCLS);
			} else {
				d.direction = 1;
				d.topheight = findlowestceilingsurrounding(sec) - 4 * FRACUNIT;
				if (d.topheight != sec.ceilingheight)
					sound->startsound(0, 0, sound->SFX_DOROPN);
			}
			th := ref Thinker(THINK_DOOR, d, nil, nil, nil, 0);
			sectorthinker(sec, th);
		}
		secnum = findsectorfromlinetag(li, secnum);
	}
	return rtn;
}

# manual door specials from p_switch.c P_UseSpecialLine
# (1/26/27/28/31-34/117/118) + S1 exit (11), S1 donut (9),
# SR plat (62), S1 open door (103), SR raise door (63),
# S1 raise-to-nearest plat (20), S1 raise floor to nearest (18),
# S1 secret exit (51), SR turbo lower (70);
# remaining switches / shoot cases later
usespecialline(mo: ref Mobj, li, side: int): int
{
	ld := lev.lines[li];
	if (side != 0)
		return 0;		# 124 only (unused); vanilla early-out
	if (mo.player == nil)
		return 0;		# monster use (1/32/33/34) with AI later
	if (ld.special == 11) {		# S1 exit (p_switch.c)
		changeswitchtexture(li, 0);
		gexitlevel();
		return 1;
	}
	if (ld.special == 9) {		# S1 donut
		if (evdodonut(li) != 0)
			changeswitchtexture(li, 0);
		return 1;
	}
	if (ld.special == 62) {		# SR plat down-wait-up-stay
		if (evdoplat(li, PL_DOWNWAITUPSTAY, 1) != 0)
			changeswitchtexture(li, 1);
		return 1;
	}
	if (ld.special == 103) {	# S1 open door (stay open)
		if (evdodoor(li, VLD_OPEN) != 0)
			changeswitchtexture(li, 0);
		return 1;
	}
	if (ld.special == 63) {		# SR raise door (keeps working)
		if (evdodoor(li, VLD_NORMAL) != 0)
			changeswitchtexture(li, 1);
		return 1;
	}
	if (ld.special == 20) {		# S1 raise-to-nearest + change
		if (evdoplat(li, PL_RAISETONEARESTANDCHANGE, 0) != 0)
			changeswitchtexture(li, 0);
		return 1;
	}
	if (ld.special == 18) {		# S1 raise floor to nearest
		if (evdofloor(li, FL_RAISEFLOORTONEAREST) != 0)
			changeswitchtexture(li, 0);
		return 1;
	}
	if (ld.special == 7) {		# S1 stairs
		if (evbuildstairs(li) != 0)
			changeswitchtexture(li, 0);
		return 1;
	}
	if (ld.special == 23) {		# S1 lower floor to lowest
		if (evdofloor(li, FL_LOWERFLOORTOWELOWEST) != 0)
			changeswitchtexture(li, 0);
		return 1;
	}
	if (ld.special == 70) {		# SR turbo lower (keeps working)
		if (evdofloor(li, FL_TURBOLOWER) != 0)
			changeswitchtexture(li, 1);
		return 1;
	}
	if (ld.special == 51) {		# S1 secret exit
		changeswitchtexture(li, 0);
		gsecretexitlevel();
		return 1;
	}
	if (ld.special == 35) {		# S1 lights very dark
		evlightturnon(li, 35);
		changeswitchtexture(li, 0);
		return 1;
	}
	if (ld.special == 1 || ld.special == 26 || ld.special == 27 ||
	    ld.special == 28 || ld.special == 31 || ld.special == 32 ||
	    ld.special == 33 || ld.special == 34 ||
	    ld.special == 117 || ld.special == 118) {
		evverticaldoor(li, mo);
		return 1;
	}
	return 0;
}

# vanilla P_UseLines (p_spec.c): 64u trace from the player; lines
# crossed nearest-first (insertion sort = P_TraverseIntercepts
# order); non-special blocking lines oof and stop, special lines
# dispatch and stop
uselines(p: ref Player)
{
	mo := p.mo;
	a := (mo.angle >> ANGLETOFINESHIFT) & FINEMASK;
	x1 := mo.x;
	y1 := mo.y;
	# vanilla: x2 = x1 + (USERANGE>>FRACBITS)*finecosine etc.
	dx := 64 * inf->finesine[(a + 2048) & FINEMASK];
	dy := 64 * inf->finesine[a];
	x2 := x1 + dx;
	y2 := y1 + dy;
	nh := 0;
	hfrac := array[len lev.lines] of int;
	hline := array[len lev.lines] of int;
	for (i := 0; i < len lev.lines; i++) {
		s1 := pointonlineside(x1, y1, i);
		s2 := pointonlineside(x2, y2, i);
		if (s1 == s2)
			continue;	# line isn't crossed
		v1 := lev.vertices[lev.lines[i].v1];
		frac := interceptvector(x1, y1, dx, dy,
			v1.x, v1.y, lev.lines[i].dx, lev.lines[i].dy);
		if (frac < 0 || frac > FRACUNIT)
			continue;
		# segment-span gate: the infinite-line crossing must
		# land on the segment itself.  Vanilla's blockmap walk
		# can order collinear neighbors (e.g. the wall pieces
		# flanking the E1M1 exit switch) ahead of the switch
		# by rounding luck and oof-stop the trace; requiring
		# the span keeps facing-a-wall oofs while letting the
		# switch behind its own wall pieces fire.  1u of slack
		# for fixed-point wobble (exact-west aims 0x7FFFFFFF,
		# one BAM unit off axis, like vanilla).
		hx := x1 + rend->fixedmul(dx, frac);
		hy := y1 + rend->fixedmul(dy, frac);
		v2 := lev.vertices[lev.lines[i].v2];
		if (v1.x < v2.x) {
			if (hx + FRACUNIT < v1.x || hx - FRACUNIT > v2.x)
				continue;
		} else {
			if (hx + FRACUNIT < v2.x || hx - FRACUNIT > v1.x)
				continue;
		}
		if (v1.y < v2.y) {
			if (hy + FRACUNIT < v1.y || hy - FRACUNIT > v2.y)
				continue;
		} else {
			if (hy + FRACUNIT < v2.y || hy - FRACUNIT > v1.y)
				continue;
		}
		j := nh;
		while (j > 0 && hfrac[j-1] > frac) {
			hfrac[j] = hfrac[j-1];
			hline[j] = hline[j-1];
			j--;
		}
		hfrac[j] = frac;
		hline[j] = i;
		nh++;
	}
	for (i = 0; i < nh; i++) {
		li := hline[i];
		if (lev.lines[li].special == 0) {
			lineopening(li);
			if (openrange <= 0) {
				sound->startsound(mo.x, mo.y, sound->SFX_OOF);
				return;
			}
		} else {
			side := 0;
			if (pointonlineside(mo.x, mo.y, li) == 1)
				side = 1;
			usespecialline(mo, li, side);
			return;
		}
	}
}

# --- attacks: hitscan traces, autoaim, missiles (milestone 10) ---
# Reference: doomgeneric p_map.c (P_AimLineAttack, PTR_AimTraverse,
# P_LineAttack, PTR_ShootTraverse), p_maputl.c (intercept math),
# p_mobj.c (P_SpawnMissile, P_SpawnPlayerMissile,
# P_CheckMissileSpawn), p_spec.c (P_ShootSpecialLine), d_items.c
# weapon info, p_pspr.c action damage values (GPL-2).
# Transcribed except: brute-force intercepts over all lines+mobjs
# (no blockmap/DDA; same side/frac math as vanilla PIT_AddLineIntercepts
# + its divline/line long/short-trace rule, plus a 1u segment-span gate
# that vanilla's block prefilter makes redundant), saturating division
# via fixeddivsat (vanilla FixedDiv can overflow on near-zero depths),
# and no P_SubstNullMobj (callers never pass nil).  Firing itself
# is milestone 11's A_ actions; the playerthink hook below fires a
# vanilla-slope pistol directly as an interim (no psprites/flash/
# ammo/refire-spread yet, documented in PLAN.done).
shootthing: ref Mobj;	# P_AimLineAttack / P_LineAttack origin
linetarget: ref Mobj;	# autoaim result (nil = none)
shootz: int;		# 16.16 muzzle height (view z + half height + 8u)
attackrange: int;	# 16.16 trace length
aimslope: int;		# 16.16 fixed shot slope (P_LineAttack input)
la_damage: int;		# damage for this shot
topslope, bottomslope: int;	# 16.16 autoaim window
ACT_FALL: int;	# inf->actnames index for A_Fall (-1 until init)
shfrac: array of int;	# intercept fracs, frac-sorted (vanilla order)
shkind: array of int;	# 0 = linedef, 1 = mobj
shidx: array of int;	# linedef # / mobjs index
shn: int;		# intercept count

# point vs divline side, vanilla P_PointOnDivlineSide exactly
# (p_maputl.c): sign-bit fast path, then FixedMul(dy>>8, dx>>8).
# collectshoot's thing-diagonal test must use this (vanilla
# PIT_AddThingIntercepts always does); the line test below picks
# this or pointonlineside by the vanilla long/short-trace rule.
pointondivside(x, y, lx, ly, ldx, ldy: int): int
{
	return pointondvlineside(x, y, lx, ly, ldx, ldy);
}

# brute-force P_PathTraverse intercept walk for shots: line
# crossings (trace endpoints on opposite sides, uselines math) plus
# thing bbox-diagonal crossings (corner-vs-trace), frac-sorted
# stable like vanilla P_TraverseIntercepts.
collectshoot(x1, y1, dx, dy: int)
{
	n := len lev.lines + len mobjs;
	shfrac = array[n] of int;
	shkind = array[n] of int;
	shidx = array[n] of int;
	shn = 0;
	x2 := x1 + dx;
	y2 := y1 + dy;
	# vanilla PIT_AddLineIntercepts long/short-trace rule (same as
	# slidetrace): long traces test line endpoints vs trace divline,
	# short traces test trace endpoints vs the line.  Shooting (2048u)
	# and use (64u) traces are always long; the branch keeps us exact
	# if a short trace ever comes through.
	longtrace := dx > 16 * FRACUNIT || dy > 16 * FRACUNIT ||
		dx < -16 * FRACUNIT || dy < -16 * FRACUNIT;
	for (i := 0; i < len lev.lines; i++) {
		v1 := lev.vertices[lev.lines[i].v1];
		v2 := lev.vertices[lev.lines[i].v2];
		if (longtrace) {
			s1 := pointondvlineside(v1.x, v1.y, x1, y1, dx, dy);
			s2 := pointondvlineside(v2.x, v2.y, x1, y1, dx, dy);
			if (s1 == s2)
				continue;	# line isn't crossed
		} else {
			s1 := pointonlineside(x1, y1, i);
			s2 := pointonlineside(x2, y2, i);
			if (s1 == s2)
				continue;	# line isn't crossed
		}
		frac := interceptvector(x1, y1, dx, dy,
			v1.x, v1.y, lev.lines[i].dx, lev.lines[i].dy);
		if (frac < 0 || frac > FRACUNIT)
			continue;
		# segment-span gate (same as uselines)
		hx := x1 + rend->fixedmul(dx, frac);
		hy := y1 + rend->fixedmul(dy, frac);
		v2 = lev.vertices[lev.lines[i].v2];
		if (v1.x < v2.x) {
			if (hx + FRACUNIT < v1.x || hx - FRACUNIT > v2.x)
				continue;
		} else {
			if (hx + FRACUNIT < v2.x || hx - FRACUNIT > v1.x)
				continue;
		}
		if (v1.y < v2.y) {
			if (hy + FRACUNIT < v1.y || hy - FRACUNIT > v2.y)
				continue;
		} else {
			if (hy + FRACUNIT < v2.y || hy - FRACUNIT > v1.y)
				continue;
		}
		j := shn;
		while (j > 0 && shfrac[j-1] > frac) {
			shfrac[j] = shfrac[j-1];
			shkind[j] = shkind[j-1];
			shidx[j] = shidx[j-1];
			j--;
		}
		shfrac[j] = frac;
		shkind[j] = 0;
		shidx[j] = i;
		shn++;
	}
	for (i = 0; i < len mobjs; i++) {
		mo := mobjs[i];
		if (mo.removed)
			continue;
		r := mo.radius;
		# corner-to-corner cross-section, diagonal picked by
		# trace direction sign (vanilla PIT_AddThingIntercepts)
		c1x, c1y, c2x, c2y: int;
		if ((dx ^ dy) > 0) {
			c1x = mo.x - r;
			c1y = mo.y + r;
			c2x = mo.x + r;
			c2y = mo.y - r;
		} else {
			c1x = mo.x - r;
			c1y = mo.y - r;
			c2x = mo.x + r;
			c2y = mo.y + r;
		}
		if (pointondivside(c1x, c1y, x1, y1, dx, dy) ==
		    pointondivside(c2x, c2y, x1, y1, dx, dy))
			continue;	# diagonal isn't crossed
		tfrac := interceptvector(x1, y1, dx, dy,
			c1x, c1y, c2x - c1x, c2y - c1y);
		if (tfrac < 0 || tfrac > FRACUNIT)
			continue;
		k := shn;
		while (k > 0 && shfrac[k-1] > tfrac) {
			shfrac[k] = shfrac[k-1];
			shkind[k] = shkind[k-1];
			shidx[k] = shidx[k-1];
			k--;
		}
		shfrac[k] = tfrac;
		shkind[k] = 1;
		shidx[k] = i;
		shn++;
	}
}

# vanilla PTR_AimTraverse over the collected intercepts; narrows
# the slope window at portals, locks linetarget/aimslope on the
# first shootable thing inside it.  Returns 1 to continue, 0 stop.
aimtraverse(k: int): int
{
	if (shkind[k] == 0) {
		li := shidx[k];
		ld := lev.lines[li];
		if ((ld.flags & ML_TWOSIDED) == 0)
			return 0;		# stop: solid wall ends sight
		lineopening(li);
		if (openbottom >= opentop)
			return 0;		# stop: closed portal
		dist := rend->fixedmul(attackrange, shfrac[k]);
		if (ld.backsector == nil ||
		    ld.frontsector.floorheight != ld.backsector.floorheight) {
			slope := fixeddivsat(openbottom - shootz, dist);
			if (slope > bottomslope)
				bottomslope = slope;
		}
		if (ld.backsector == nil ||
		    ld.frontsector.ceilingheight != ld.backsector.ceilingheight) {
			cslope := fixeddivsat(opentop - shootz, dist);
			if (cslope < topslope)
				topslope = cslope;
		}
		if (topslope <= bottomslope)
			return 0;		# stop: window closed
		return 1;
	}
	th := mobjs[shidx[k]];
	if (th == shootthing)
		return 1;			# can't shoot self
	if ((th.flags & inf->MF_SHOOTABLE) == 0)
		return 1;			# corpse or decoration
	dist := rend->fixedmul(attackrange, shfrac[k]);
	thingtopslope := fixeddivsat(th.z + th.height - shootz, dist);
	if (thingtopslope < bottomslope)
		return 1;			# shot over the thing
	thingbotslope := fixeddivsat(th.z - shootz, dist);
	if (thingbotslope > topslope)
		return 1;			# shot under the thing
	if (thingtopslope > topslope)
		thingtopslope = topslope;
	if (thingbotslope < bottomslope)
		thingbotslope = bottomslope;
	aimslope = (thingtopslope + thingbotslope) / 2;
	linetarget = th;
	return 0;				# don't go any farther
}

# vanilla P_AimLineAttack: autoaim slope to the first shootable in
# the slope window, else 0.  Angle is BAM; distance is 16.16.
paimlineattack(mo: ref Mobj, angle, distance: int): int
{
	shootthing = mo;
	a := (angle >> ANGLETOFINESHIFT) & FINEMASK;
	x2 := mo.x + (distance >> FRACBITS) * inf->finesine[(a + 2048) & FINEMASK];
	y2 := mo.y + (distance >> FRACBITS) * inf->finesine[a];
	dx := x2 - mo.x;
	dy := y2 - mo.y;
	shootz = mo.z + (mo.height >> 1) + 8 * FRACUNIT;
	topslope = 100 * FRACUNIT / 160;
	bottomslope = -100 * FRACUNIT / 160;
	attackrange = distance;
	linetarget = nil;
	aimslope = 0;
	collectshoot(mo.x, mo.y, dx, dy);
	for (k := 0; k < shn; k++)
		if (aimtraverse(k) == 0)
			break;
	if (linetarget != nil)
		return aimslope;
	return 0;
}

# vanilla P_ShootSpecialLine: gunfire impact on special lines.
# Only 46 (open door) responds to non-players; 24/47 are free.
useshootspecialline(li: int): int
{
	ld := lev.lines[li];
	if (shootthing.player == nil) {
		if (ld.special != 46)
			return 0;
	}
	if (ld.special == 24) {
		evdofloor(li, FL_RAISEFLOOR);
		changeswitchtexture(li, 0);
		return 1;
	} else if (ld.special == 46) {
		evdodoor(li, VLD_OPEN);
		changeswitchtexture(li, 1);
		return 1;
	} else if (ld.special == 47) {
		evdoplat(li, PL_RAISETONEARESTANDCHANGE, 0);
		changeswitchtexture(li, 0);
		return 1;
	}
	return 0;
}

# vanilla PTR_ShootTraverse over the collected intercepts; stop (0)
# at the first wall/thing the fixed aimslope actually reaches.
# Returns 1 to continue, 0 to stop.
shoottraverse(k: int, x1, y1, dx, dy: int): int
{
	if (shkind[k] == 0) {
		li := shidx[k];
		ld := lev.lines[li];
		if (ld.special != 0)
			useshootspecialline(li);
		if ((ld.flags & ML_TWOSIDED) == 0)
			return shootwall(li, x1, y1, dx, dy, shfrac[k]);
		lineopening(li);
		hit := 0;
		slope := 0;
		if (ld.backsector == nil) {
			slope = fixeddivsat(openbottom - shootz, rend->fixedmul(attackrange, shfrac[k]));
			if (slope > aimslope)
				hit = 1;
			else {
				slope = fixeddivsat(opentop - shootz, rend->fixedmul(attackrange, shfrac[k]));
				if (slope < aimslope)
					hit = 1;
			}
		} else {
			if (ld.frontsector.floorheight != ld.backsector.floorheight) {
				slope = fixeddivsat(openbottom - shootz, rend->fixedmul(attackrange, shfrac[k]));
				if (slope > aimslope)
					hit = 1;
			}
			if (hit == 0 && ld.frontsector.ceilingheight != ld.backsector.ceilingheight) {
				slope = fixeddivsat(opentop - shootz, rend->fixedmul(attackrange, shfrac[k]));
				if (slope < aimslope)
					hit = 1;
			}
		}
		if (hit != 0)
			return shootwall(li, x1, y1, dx, dy, shfrac[k]);
		return 1;		# shot continues past the portal
	}
	th := mobjs[shidx[k]];
	if (th == shootthing)
		return 1;			# can't shoot self
	if ((th.flags & inf->MF_SHOOTABLE) == 0)
		return 1;			# corpse or decoration
	dist := rend->fixedmul(attackrange, shfrac[k]);
	thingtopslope := fixeddivsat(th.z + th.height - shootz, dist);
	if (thingtopslope < aimslope)
		return 1;			# shot over the thing
	thingbotslope := fixeddivsat(th.z - shootz, dist);
	if (thingbotslope > aimslope)
		return 1;			# shot under the thing
	frac := shfrac[k] - fixeddivsat(10 * FRACUNIT, attackrange);
	x := x1 + rend->fixedmul(dx, frac);
	y := y1 + rend->fixedmul(dy, frac);
	z := shootz + rend->fixedmul(aimslope, rend->fixedmul(frac, attackrange));
	if ((th.flags & inf->MF_NOBLOOD) != 0)
		pspawnpuff(x, y, z);
	else
		pspawnblood(x, y, z, la_damage);
	if (la_damage != 0)
		pdamagemobj(th, shootthing, shootthing, la_damage);
	return 0;				# don't go any farther
}

# vanilla PTR_ShootTraverse hitline branch: back the hit point off
# the wall, check sky (no puff, stop), else spawn a puff and stop.
shootwall(li, x1, y1, dx, dy, frac: int): int
{
	frac = frac - fixeddivsat(4 * FRACUNIT, attackrange);
	x := x1 + rend->fixedmul(dx, frac);
	y := y1 + rend->fixedmul(dy, frac);
	z := shootz + rend->fixedmul(aimslope, rend->fixedmul(frac, attackrange));
	fsec := lev.lines[li].frontsector;
	if (fsec.ceilingtexture == SKYFLAT) {
		if (z > fsec.ceilingheight)
			return 0;		# don't shoot the sky
		bs := lev.lines[li].backsector;
		if (bs != nil && bs.ceilingtexture == SKYFLAT)
			return 0;		# sky hack wall
	}
	pspawnpuff(x, y, z);
	return 0;				# don't go any farther
}

# vanilla P_LineAttack: hitscan along angle with a fixed slope.
plineattack(mo: ref Mobj, angle, distance, slope, damage: int)
{
	shootthing = mo;
	la_damage = damage;
	a := (angle >> ANGLETOFINESHIFT) & FINEMASK;
	x2 := mo.x + (distance >> FRACBITS) * inf->finesine[(a + 2048) & FINEMASK];
	y2 := mo.y + (distance >> FRACBITS) * inf->finesine[a];
	dx := x2 - mo.x;
	dy := y2 - mo.y;
	shootz = mo.z + (mo.height >> 1) + 8 * FRACUNIT;
	attackrange = distance;
	aimslope = slope;
	linetarget = nil;
	collectshoot(mo.x, mo.y, dx, dy);
	for (k := 0; k < shn; k++)
		if (shoottraverse(k, mo.x, mo.y, dx, dy) == 0)
			break;
}

# vanilla P_SpawnPuff / P_SpawnBlood (p_mobj.c): impact markers.
# Puffs float up slowly; blood twice as fast.  Melee-range puffs use
# the S_PUFF3 frame; weak blood hits use S_BLOOD2/3.
pspawnpuff(x, y, z: int)
{
	z += (prandom() - prandom()) << 10;
	th := spawnmobj(x, y, z, inf->MT_PUFF);
	th.momz = FRACUNIT;
	th.tics -= prandom() & 3;
	if (th.tics < 1)
		th.tics = 1;
	if (attackrange == MELEERANGE)
		setmobjstate(th, inf->S_PUFF3);
}

pspawnblood(x, y, z, damage: int)
{
	z += (prandom() - prandom()) << 10;
	th := spawnmobj(x, y, z, inf->MT_BLOOD);
	th.momz = 2 * FRACUNIT;
	th.tics -= prandom() & 3;
	if (th.tics < 1)
		th.tics = 1;
	if (damage <= 12 && damage >= 9)
		setmobjstate(th, inf->S_BLOOD2);
	else if (damage < 9)
		setmobjstate(th, inf->S_BLOOD3);
}

# vanilla P_SpawnMissile (p_mobj.c): explode-outward missile aimed at
# dest (with shadow-fuzz), then CheckMissileSpawn nudges it forward.
pspawnmissile(source, dest: ref Mobj, typ: int): ref Mobj
{
	th := spawnmobj(source.x, source.y, source.z + 4 * 8 * FRACUNIT, typ);
	if (th.info.seesound != 0)
		sound->startsound(th.x, th.y, th.info.seesound);
	th.target = source;
	an := pointtoangle2(source.x, source.y, dest.x, dest.y);
	if ((dest.flags & inf->MF_SHADOW) != 0)
		an += (prandom() - prandom()) << 20;
	th.angle = an;
	a := (an >> ANGLETOFINESHIFT) & FINEMASK;
	th.momx = rend->fixedmul(th.info.speed, inf->finesine[(a + 2048) & FINEMASK]);
	th.momy = rend->fixedmul(th.info.speed, inf->finesine[a]);
	dist := approxdistance(dest.x - source.x, dest.y - source.y);
	dist = dist / th.info.speed;
	if (dist < 1)
		dist = 1;
	th.momz = (dest.z - source.z) / dist;
	pcheckmissilespawn(th);
	return th;
}

# vanilla P_SpawnPlayerMissile: triple-try autoaim, else straight.
# slope in 16.16; vanilla an adjustments are BAM (<<26 on angle_t).
pspawnplayermissile(source: ref Mobj, typ: int): ref Mobj
{
	an := source.angle;
	slope := paimlineattack(source, an, 16 * 64 * FRACUNIT);
	if (linetarget == nil) {
		an += 1 << 26;
		slope = paimlineattack(source, an, 16 * 64 * FRACUNIT);
		if (linetarget == nil) {
			an -= 2 << 26;
			slope = paimlineattack(source, an, 16 * 64 * FRACUNIT);
		}
		if (linetarget == nil) {
			an = source.angle;
			slope = 0;
		}
	}
	th := spawnmobj(source.x, source.y, source.z + 4 * 8 * FRACUNIT, typ);
	if (th.info.seesound != 0)
		sound->startsound(th.x, th.y, th.info.seesound);
	th.target = source;
	th.angle = an;
	a := (an >> ANGLETOFINESHIFT) & FINEMASK;
	th.momx = rend->fixedmul(th.info.speed, inf->finesine[(a + 2048) & FINEMASK]);
	th.momy = rend->fixedmul(th.info.speed, inf->finesine[a]);
	th.momz = rend->fixedmul(th.info.speed, slope);
	pcheckmissilespawn(th);
	return th;
}

# vanilla P_CheckMissileSpawn: tics jitter, half-step nudge, explode
# on immediate contact.
pcheckmissilespawn(th: ref Mobj)
{
	th.tics -= prandom() & 3;
	if (th.tics < 1)
		th.tics = 1;
	th.x += th.momx >> 1;
	th.y += th.momy >> 1;
	th.z += th.momz >> 1;
	if (!trymove(th, th.x, th.y))
		explodemissile(th);
}

# interim direct-fire pistol on the BT_ATTACK rising edge (vanilla
# A_FirePistol/P_BulletSlope/P_GunShot minus psprites: triple-try
# autoaim, exact first-shot aim, vanilla 5d3; flash/ammo/refire
# spread stay milestone 11's job)
firepistol(p: ref Player)
{
	an := p.mo.angle;
	slope := paimlineattack(p.mo, an, MISSILERANGE);
	if (linetarget == nil) {
		an += 1 << 26;
		slope = paimlineattack(p.mo, an, MISSILERANGE);
		if (linetarget == nil) {
			an -= 2 << 26;
			slope = paimlineattack(p.mo, an, MISSILERANGE);
		}
	}
	damage := 5 * ((prandom() % 3) + 1);
	plineattack(p.mo, p.mo.angle, MISSILERANGE, slope, damage);
	sound->startsound(p.mo.x, p.mo.y, sound->SFX_PISTOL);
}

# ---------------------------------------------------------------------------
# floors / plats / walkover lines / switches / exit (milestone 13
# second slice: exactly what E1M1 needs past doors — W1 turboLower
# 36, WR downWaitUpStay plat 88, S1 exit switch 11).
# Reference: doomgeneric p_floor.c, p_plats.c, p_spec.c
# (P_CrossSpecialLine, find helpers), p_switch.c, g_game.c
# G_ExitLevel (GPL-2).  Transcribed except: brute-force scans (no
# blockmap/sec->lines), separate thinker list (stable indices, no
# compaction), unbounded activeplats (vanilla I_Errors past 30),
# textures are name strings (no texture numbers), button flip-back
# timers later (S1 exit never flips back), crush damage in 9,
# secret counting in 14.
# ---------------------------------------------------------------------------

# vanilla P_FindSectorFromLineTag (p_spec.c): next sector whose
# tag matches the line's, after start
findsectorfromlinetag(li, start: int): int
{
	tag := lev.lines[li].tag;
	for (i := start + 1; i < len lev.sectors; i++)
		if (lev.sectors[i].tag == tag)
			return i;
	return -1;
}

# vanilla P_FindLowestFloorSurrounding (p_spec.c)
findlowestfloorsec(sec: ref Map->Sector): int
{
	height := sec.floorheight;
	for (i := 0; i < len lev.lines; i++) {
		ld := lev.lines[i];
		other := ld.frontsector;
		if (ld.frontsector == sec) {
			if (ld.backsector == sec)
				continue;
			other = ld.backsector;
		} else if (ld.backsector == sec) {
			other = ld.frontsector;
		} else
			continue;
		if (other == nil)
			continue;
		if (other.floorheight < height)
			height = other.floorheight;
	}
	return height;
}

# vanilla P_FindHighestFloorSurrounding (p_spec.c)
findhighestfloorsec(sec: ref Map->Sector): int
{
	height := -500 * FRACUNIT;
	for (i := 0; i < len lev.lines; i++) {
		ld := lev.lines[i];
		other := ld.frontsector;
		if (ld.frontsector == sec) {
			if (ld.backsector == sec)
				continue;
			other = ld.backsector;
		} else if (ld.backsector == sec) {
			other = ld.frontsector;
		} else
			continue;
		if (other == nil)
			continue;
		if (other.floorheight > height)
			height = other.floorheight;
	}
	return height;
}

# vanilla T_MoveFloor (p_floor.c): stnmov hum while moving,
# unlink + pstop at destination, donutRaise/lowerAndChange apply
# their end texture + special (needs Floor.texture/newspecial)
tmovefloor(th: ref Thinker)
{
	f := th.floor;
	res := tmoveplane(f.sec, f.speed, f.floordestheight,
		f.crush, 1, f.direction);
	if ((lvltime & 7) == 0)
		sound->startsound(0, 0, sound->SFX_STNMOV);
	if (res == RES_PASTDEST) {
		if (f.direction == 1 && f.fltype == FL_DONUTRAISE) {
			f.sec.special = f.newspecial;
			f.sec.floortexture = f.texture;
		}
		# lowerAndChange end-branches with its milestone
		f.sec.specialdata = -1;
		th.removed = 1;
		sound->startsound(0, 0, sound->SFX_PSTOP);
	}
}

# append a sector thinker and link it (stable index, no compaction;
# mirrors the repeated Z_Malloc/P_AddThinker/specialdata sequence)
sectorthinker(sec: ref Map->Sector, th: ref Thinker)
{
	n := len thinkers;
	nt := array[n + 1] of ref Thinker;
	if (n > 0)
		nt[0:] = thinkers;
	nt[n] = th;
	thinkers = nt;
	sec.specialdata = n;
}

# vanilla P_FindNextHighestFloor (p_spec.c): lowest floor above
# currentheight among touching sectors.  The >20-neighbour stack
# overflow emulation is skipped (vanilla memory quirk, OUT scope).
findnexthighestfloor(sec: ref Map->Sector, cur: int): int
{
	height := cur;
	for (i := 0; i < len lev.lines; i++) {
		ld := lev.lines[i];
		other := ld.frontsector;
		if (ld.frontsector == sec) {
			if (ld.backsector == sec)
				continue;
			other = ld.backsector;
		} else if (ld.backsector == sec) {
			other = ld.frontsector;
		} else
			continue;
		if (other == nil)
			continue;
		if (other.floorheight > height &&
		    (height == cur || other.floorheight < height))
			height = other.floorheight;
	}
	return height;
}

# vanilla EV_BuildStairs build8 (p_floor.c): step the tagged sector
# up 8u at quarter speed, then chase two-sided lines whose side 0
# is the current sector into same-pic neighbours (+8 each, skip
# movers).  fltype is raiseFloor: vanilla leaves the malloc garbage
# and T_MoveFloor defaults anything non-donut on arrival.
evbuildstairs(li: int): int
{
	rtn := 0;
	secnum := findsectorfromlinetag(li, -1);
	while (secnum >= 0) {
		sec := lev.sectors[secnum];
		if (sec.specialdata == -1) {
			rtn = 1;
			speed := FLOORSPEED / 4;
			stairsize := 8 * FRACUNIT;
			height := sec.floorheight + stairsize;
			f := ref Floor(sec, FL_RAISEFLOOR, height, speed,
				1, 0, "", 0);
			th := ref Thinker(THINK_FLOOR, nil, f, nil, nil, 0);
			sectorthinker(sec, th);
			texture := sec.floortexture;
			for (;;) {
				found := 0;
				for (i := 0; i < len lev.lines; i++) {
					ld := lev.lines[i];
					if ((ld.flags & ML_TWOSIDED) == 0)
						continue;
					if (!(ld.frontsector == sec))
						continue;
					tsec := ld.backsector;
					if (tsec == nil || tsec == sec)
						continue;
					if (tsec.floortexture != texture)
						continue;
					if (tsec.specialdata != -1)
						continue;
					height += stairsize;
					sec = tsec;
					f = ref Floor(sec, FL_RAISEFLOOR, height,
						speed, 1, 0, "", 0);
					th = ref Thinker(THINK_FLOOR, nil, f, nil, nil, 0);
					sectorthinker(sec, th);
					found = 1;
					break;
				}
				if (found == 0)
					break;
			}
		}
		secnum = findsectorfromlinetag(li, secnum);
	}
	return rtn;
}

# vanilla EV_DoFloor (p_floor.c): turboLower only this slice
# (other floor_e types with their milestones); returns 1 if any
# sector started moving
evdofloor(li, fltype: int): int
{
	rtn := 0;
	secnum := findsectorfromlinetag(li, -1);
	while (secnum >= 0) {
		sec := lev.sectors[secnum];
		if (sec.specialdata == -1) {	# not already moving
			rtn = 1;
			f := ref Floor;
			f.sec = sec;
			f.fltype = fltype;
			f.crush = 0;
			f.texture = "";
			f.newspecial = 0;
			if (fltype == FL_TURBOLOWER) {
				f.direction = -1;
				f.speed = 4 * FLOORSPEED;
				f.floordestheight = findhighestfloorsec(sec);
				if (f.floordestheight != sec.floorheight)
					f.floordestheight += 8 * FRACUNIT;
			} else if (fltype == FL_RAISEFLOOR) {
				f.direction = 1;
				f.speed = FLOORSPEED;
				f.floordestheight = findlowestceilingsurrounding(sec);
				if (f.floordestheight > sec.ceilingheight)
					f.floordestheight = sec.ceilingheight;
			} else if (fltype == FL_LOWERFLOORTOWELOWEST) {
				f.direction = -1;
				f.speed = FLOORSPEED;
				f.floordestheight = findlowestfloorsec(sec);
			} else if (fltype == FL_RAISEFLOORTONEAREST) {
				f.direction = 1;
				f.speed = FLOORSPEED;
				f.floordestheight = findnexthighestfloor(sec, sec.floorheight);
			}
			th := ref Thinker(THINK_FLOOR, nil, f, nil, nil, 0);
			n := len thinkers;
			nt := array[n + 1] of ref Thinker;
			if (n > 0)
				nt[0:] = thinkers;
			nt[n] = th;
			thinkers = nt;
			sec.specialdata = n;
		}
		secnum = findsectorfromlinetag(li, secnum);
	}
	return rtn;
}

# vanilla P_TeleportMove (p_map.c): stomp-test the destination
# (things only - lines are never consulted, floor/ceiling come
# straight from the destination subsector), then relocate.  The
# player-telefrag kill routes through P_DamageMobj in milestone 9;
# until then a shootable-blocked destination fails the teleport
# (E1 destinations are clear, so this never fires in validation).
pteleportmove(mo: ref Mobj, x, y: int): int
{
	tmthing = mo;
	tmflags = mo.flags;
	tmx = x;
	tmy = y;
	tmbbox[0] = y + mo.radius;		# BOXTOP
	tmbbox[1] = y - mo.radius;		# BOXBOTTOM
	tmbbox[2] = x + mo.radius;		# BOXRIGHT
	tmbbox[3] = x - mo.radius;		# BOXLEFT
	ss := lev.pointsubsector(x, y);
	if (ss == nil)
		return 0;
	ceilingline = -1;
	tmfloorz = ss.sector.floorheight;
	tmdropoffz = tmfloorz;
	tmceilingz = ss.sector.ceilingheight;
	nspechit = 0;
	for (i := 0; i < len mobjs; i++) {
		thing := mobjs[i];
		if (thing.removed)
			continue;
		if ((thing.flags & inf->MF_SHOOTABLE) == 0)
			continue;
		blockdist := thing.radius + mo.radius;
		if (absi(thing.x - x) >= blockdist ||
		    absi(thing.y - y) >= blockdist)
			continue;		# didn't hit it
		if (thing == mo)
			continue;		# don't clip against self
		if (mo.player == nil && gamemapnum != 30)
			return 0;		# monsters don't stomp (off boss map)
		# telefrag: 10000 damage through P_DamageMobj (milestone 9
		# hookup; previously failed closed here)
		pdamagemobj(thing, mo, mo, 10000);
	}
	mo.floorz = tmfloorz;
	mo.ceilingz = tmceilingz;
	mo.x = x;
	mo.y = y;
	setthingposition(mo);
	return 1;
}

# vanilla EV_Teleport (p_telept.c): tag-matched teleportman drags
# the caller to its x/y/floor, facing its angle.  Fog + sound at
# both ends, players freeze 18 tics.  No missiles, no back-side
# entry (lets you walk out of the pad).
evteleport(li, side: int, mo: ref Mobj): int
{
	if ((mo.flags & inf->MF_MISSILE) != 0)
		return 0;
	if (side == 1)
		return 0;
	tag := lev.lines[li].tag;
	for (i := 0; i < len lev.sectors; i++) {
		if (lev.sectors[i].tag != tag)
			continue;
		for (j := 0; j < len mobjs; j++) {
			m := mobjs[j];
			if (m.removed || m.typ != inf->MT_TELEPORTMAN)
				continue;
			if (m.subsector == nil)
				continue;
			if (!(m.subsector.sector == lev.sectors[i]))
				continue;
			oldx := mo.x;
			oldy := mo.y;
			oldz := mo.z;
			if (pteleportmove(mo, m.x, m.y) == 0)
				return 0;
			mo.z = mo.floorz;
			if (mo.player != nil)
				mo.player.viewz = mo.z + mo.player.viewheight;
			fog := spawnmobj(oldx, oldy, oldz, inf->MT_TFOG);
			sound->startsound(fog.x, fog.y, sound->SFX_TELEPT);
			an := (m.angle >> ANGLETOFINESHIFT) & FINEMASK;
			fog = spawnmobj(m.x + rend->fixedmul(20 * FRACUNIT, inf->finesine[(an + 2048) & FINEMASK]),
				m.y + rend->fixedmul(20 * FRACUNIT, inf->finesine[an]),
				mo.z, inf->MT_TFOG);
			sound->startsound(fog.x, fog.y, sound->SFX_TELEPT);
			if (mo.player != nil)
				mo.reactiontime = 18;
			mo.angle = m.angle;
			mo.momx = 0;
			mo.momy = 0;
			mo.momz = 0;
			return 1;
		}
	}
	return 0;
}

# vanilla EV_DoDonut (p_spec.c): the tagged pillar (s1) lowers to
# the outer level (s3) while the surrounding pool (s2) rises to it.
# s2 is the far side of the first line touching s1 in linedef order
# (one-sided there breaks the whole tag loop, like doomgeneric -
# vanilla reads garbage); s3 is the first other backsector found
# the same way (nil s3 stops instead of using garbage).  s2 gets no
# moving check, like vanilla (the old thinker is orphaned the same
# way in both: no compaction here).
evdodonut(li: int): int
{
	rtn := 0;
	secnum := findsectorfromlinetag(li, -1);
	while (secnum >= 0) {
		s1 := lev.sectors[secnum];
		if (s1.specialdata == -1) {
			rtn = 1;
			s2: ref Map->Sector = nil;
			for (i := 0; i < len lev.lines; i++) {
				ld := lev.lines[i];
				if (ld.frontsector == s1 && ld.backsector != s1) {
					s2 = ld.backsector;
					break;
				}
				if (ld.backsector == s1 && ld.frontsector != s1) {
					s2 = ld.frontsector;
					break;
				}
			}
			if (s2 == nil)
				break;
			s3: ref Map->Sector = nil;
			for (i = 0; i < len lev.lines; i++) {
				ld := lev.lines[i];
				if (!(ld.frontsector == s2 || ld.backsector == s2))
					continue;
				if (ld.backsector == s1)
					continue;
				if (ld.backsector == nil)
					continue;
				s3 = ld.backsector;
				break;
			}
			if (s3 == nil)
				break;
			# rising slime
			f := ref Floor(s2, FL_DONUTRAISE, s3.floorheight,
				FLOORSPEED / 2, 1, 0, s3.floortexture, 0);
			th := ref Thinker(THINK_FLOOR, nil, f, nil, nil, 0);
			sectorthinker(s2, th);
			# lowering donut-hole
			f = ref Floor(s1, FL_LOWERFLOOR, s3.floorheight,
				FLOORSPEED / 2, -1, 0, "", 0);
			th = ref Thinker(THINK_FLOOR, nil, f, nil, nil, 0);
			sectorthinker(s1, th);
		}
		secnum = findsectorfromlinetag(li, secnum);
	}
	return rtn;
}

# vanilla T_PlatRaise (p_plats.c): stnmov hums on UP for the
# raiseAndChange family; arrival unlinks the leaving types
# (downWaitUpStay + raise family) but perpetualRaise keeps cycling
tplatraise(th: ref Thinker)
{
	pl := th.plat;
	sec := pl.sec;
	if (pl.status == PLS_UP) {
		res := tmoveplane(sec, pl.speed, pl.high, pl.crush, 1, 1);
		if (pl.pltype == PL_RAISEANDCHANGE ||
		    pl.pltype == PL_RAISETONEARESTANDCHANGE) {
			if ((lvltime & 7) == 0)
				sound->startsound(0, 0, sound->SFX_STNMOV);
		}
		if (res == RES_CRUSHED && pl.crush == 0) {
			pl.count = pl.wait;
			pl.status = PLS_DOWN;
			sound->startsound(0, 0, sound->SFX_PSTART);
		} else if (res == RES_PASTDEST) {
			pl.count = pl.wait;
			pl.status = PLS_WAITING;
			sound->startsound(0, 0, sound->SFX_PSTOP);
			if (pl.pltype == PL_DOWNWAITUPSTAY ||
			    pl.pltype == PL_RAISEANDCHANGE ||
			    pl.pltype == PL_RAISETONEARESTANDCHANGE)
				premoveactiveplat(th);
		}
	} else if (pl.status == PLS_DOWN) {
		res := tmoveplane(sec, pl.speed, pl.low, 0, 1, -1);
		if (res == RES_PASTDEST) {
			pl.count = pl.wait;
			pl.status = PLS_WAITING;
			sound->startsound(0, 0, sound->SFX_PSTOP);
		}
	} else if (pl.status == PLS_WAITING) {
		pl.count = pl.count - 1;
		if (pl.count == 0) {
			if (sec.floorheight == pl.low)
				pl.status = PLS_UP;
			else
				pl.status = PLS_DOWN;
			sound->startsound(0, 0, sound->SFX_PSTART);
		}
	}
	# PLS_STASIS: nothing (stasis resume with EV_StopPlat later)
}

# vanilla P_AddActivePlat (p_plats.c), minus the I_Error: the
# array just grows (a level holds a handful of plats)
paddactiveplat(th: ref Thinker)
{
	n := len activeplats;
	na := array[n + 1] of ref Thinker;
	if (n > 0)
		na[0:] = activeplats;
	na[n] = th;
	activeplats = na;
}

# vanilla P_RemoveActivePlat (p_plats.c), minus the I_Error
premoveactiveplat(th: ref Thinker)
{
	th.plat.sec.specialdata = -1;
	th.removed = 1;
	n := len activeplats;
	for (i := 0; i < n; i++) {
		if (activeplats[i] == th) {
			if (i != n - 1)
				activeplats[i] = activeplats[n - 1];
			na := array[n - 1] of ref Thinker;
			if (n - 1 > 0)
				na[0:] = activeplats[0:n - 1];
			activeplats = na;
			return;
		}
	}
}

# vanilla EV_DoPlat (p_plats.c): downWaitUpStay only this slice
evdoplat(li, pltype, amount: int): int
{
	rtn := 0;
	secnum := findsectorfromlinetag(li, -1);
	while (secnum >= 0) {
		sec := lev.sectors[secnum];
		if (sec.specialdata == -1) {	# not already moving
			rtn = 1;
			pl := ref Plat;
			pl.sec = sec;
			pl.pltype = pltype;
			pl.crush = 0;
			pl.count = 0;
			pl.tag = lev.lines[li].tag;
			if (pltype == PL_RAISETONEARESTANDCHANGE) {
				pl.speed = PLATSPEED / 2;
				pl.sec.floortexture = lev.lines[li].sides[0].sector.floortexture;
				pl.high = findnexthighestfloor(sec, sec.floorheight);
				pl.wait = 0;
				pl.status = PLS_UP;
				sec.special = 0;
				sound->startsound(0, 0, sound->SFX_STNMOV);
			} else if (pltype == PL_DOWNWAITUPSTAY) {
				pl.speed = 4 * PLATSPEED;
				pl.low = findlowestfloorsec(sec);
				if (pl.low > sec.floorheight)
					pl.low = sec.floorheight;
				pl.high = sec.floorheight;
				pl.wait = TICRATE * PLATWAIT;
				pl.status = PLS_DOWN;
				sound->startsound(0, 0, sound->SFX_PSTART);
			}
			th := ref Thinker(THINK_PLAT, nil, nil, pl, nil, 0);
			n := len thinkers;
			nt := array[n + 1] of ref Thinker;
			if (n > 0)
				nt[0:] = thinkers;
			nt[n] = th;
			thinkers = nt;
			sec.specialdata = n;
			paddactiveplat(th);
		}
		secnum = findsectorfromlinetag(li, secnum);
	}
	amount = amount;	# raiseAndChange only; kept for signature
	return rtn;
}

# ---------------------------------------------------------------------------
# lights (milestone 13, E1 slice).  Reference: doomgeneric p_lights.c,
# p_spec.c P_SpawnSpecials/EV_LightTurnOn, p_doors.c door spawners.
# Transcribed line-for-line except brute-force neighbour scans (no
# sec->lines) and the separate thinker list.  Sector special 9
# (secret count) belongs to milestone 14; 7/11/16 spawn nothing.
# ---------------------------------------------------------------------------

# vanilla P_FindMinSurroundingLight (p_spec.c): min neighbour light,
# floored at max (i.e. never above the sector's own level)
findminlightsec(sec: ref Map->Sector, max: int): int
{
	height := max;
	for (i := 0; i < len lev.lines; i++) {
		ld := lev.lines[i];
		other := ld.frontsector;
		if (ld.frontsector == sec) {
			if (ld.backsector == sec)
				continue;
			other = ld.backsector;
		} else if (ld.backsector == sec) {
			other = ld.frontsector;
		} else
			continue;
		if (other == nil)
			continue;
		if (other.lightlevel < height)
			height = other.lightlevel;
	}
	return height;
}

# one light thinker pass (p_lights.c T_*, switched on ltype since the
# families share one adt here instead of four structs)
tlightthink(th: ref Thinker)
{
	l := th.light;
	sec := l.sec;
	if (l.ltype == LT_FIRE) {		# T_FireFlicker
		l.count = l.count - 1;
		if (l.count != 0)
			return;
		amount := (prandom() & 3) * 16;
		if (sec.lightlevel - amount < l.minlight)
			sec.lightlevel = l.minlight;
		else
			sec.lightlevel = l.maxlight - amount;
		l.count = 4;
	} else if (l.ltype == LT_FLASH) {	# T_LightFlash
		l.count = l.count - 1;
		if (l.count != 0)
			return;
		if (sec.lightlevel == l.maxlight) {
			sec.lightlevel = l.minlight;
			l.count = (prandom() & l.mintime) + 1;
		} else {
			sec.lightlevel = l.maxlight;
			l.count = (prandom() & l.maxtime) + 1;
		}
	} else if (l.ltype == LT_STROBE) {	# T_StrobeFlash
		l.count = l.count - 1;
		if (l.count != 0)
			return;
		if (sec.lightlevel == l.minlight) {
			sec.lightlevel = l.maxlight;
			l.count = l.brighttime;
		} else {
			sec.lightlevel = l.minlight;
			l.count = l.darktime;
		}
	} else if (l.ltype == LT_GLOW) {	# T_Glow
		if (l.direction == -1) {
			sec.lightlevel = sec.lightlevel - GLOWSPEED;
			if (sec.lightlevel <= l.minlight) {
				sec.lightlevel = sec.lightlevel + GLOWSPEED;
				l.direction = 1;
			}
		} else if (l.direction == 1) {
			sec.lightlevel = sec.lightlevel + GLOWSPEED;
			if (sec.lightlevel >= l.maxlight) {
				sec.lightlevel = sec.lightlevel - GLOWSPEED;
				l.direction = -1;
			}
		}
	}
}

# append a light thinker (all fields set: dirty heap)
addlightthinker(sec: ref Map->Sector, ltype, count, minlight, maxlight,
	darktime, brighttime, direction, maxtime, mintime: int)
{
	l := ref Light(sec, ltype, count, minlight, maxlight,
		darktime, brighttime, direction, maxtime, mintime);
	th := ref Thinker(THINK_LIGHT, nil, nil, nil, l, 0);
	n := len thinkers;
	nt := array[n + 1] of ref Thinker;
	if (n > 0)
		nt[0:] = thinkers;
	nt[n] = th;
	thinkers = nt;
	sec.specialdata = n;
}

# vanilla P_SpawnFireFlicker (p_lights.c)
spawnfireflicker(sec: ref Map->Sector)
{
	lc := sec;
	lc.special = 0;
	addlightthinker(sec, LT_FIRE, 4,
		findminlightsec(sec, sec.lightlevel) + 16, sec.lightlevel,
		0, 0, 0, 0, 0);
}

# vanilla P_SpawnLightFlash (p_lights.c)
spawnlightflash(sec: ref Map->Sector)
{
	lc := sec;
	lc.special = 0;
	addlightthinker(sec, LT_FLASH, (prandom() & 64) + 1,
		findminlightsec(sec, sec.lightlevel), sec.lightlevel,
		0, 0, 0, 64, 7);
}

# vanilla P_SpawnStrobeFlash (p_lights.c)
spawnstrobeflash(sec: ref Map->Sector, fastorslow, insync: int)
{
	maxlight := sec.lightlevel;
	minlight := findminlightsec(sec, maxlight);
	if (minlight == maxlight)
		minlight = 0;
	lc := sec;
	lc.special = 0;
	count := 1;
	if (insync == 0)
		count = (prandom() & 7) + 1;
	addlightthinker(sec, LT_STROBE, count, minlight, maxlight,
		fastorslow, STROBEBRIGHT, 0, 0, 0);
}

# vanilla P_SpawnGlowingLight (p_lights.c)
spawnglowinglight(sec: ref Map->Sector)
{
	addlightthinker(sec, LT_GLOW, 0,
		findminlightsec(sec, sec.lightlevel), sec.lightlevel,
		0, 0, -1, 0, 0);
	lc := sec;
	lc.special = 0;
}

# vanilla P_SpawnDoorCloseIn30 (p_doors.c): shut 30s after load
spawndoorclosein30(sec: ref Map->Sector)
{
	lc := sec;
	lc.special = 0;
	d := ref Door(sec, VLD_NORMAL, sec.ceilingheight, VDOORSPEED,
		0, VDOORWAIT, 30 * TICRATE);
	th := ref Thinker(THINK_DOOR, d, nil, nil, nil, 0);
	sectorthinker(sec, th);
}

# vanilla P_SpawnDoorRaiseIn5Mins (p_doors.c): open 5min after load
spawndoorraisein5mins(sec: ref Map->Sector)
{
	lc := sec;
	lc.special = 0;
	d := ref Door(sec, VLD_RAISEIN5MINS,
		findlowestceilingsurrounding(sec) - 4 * FRACUNIT,
		VDOORSPEED, 2, VDOORWAIT, 5 * 60 * TICRATE);
	th := ref Thinker(THINK_DOOR, d, nil, nil, nil, 0);
	sectorthinker(sec, th);
}

# vanilla P_SpawnSpecials sector scan, E1 slice (p_spec.c): light
# thinkers + timed doors.  Case 9 (secret count) is milestone 14;
# 7/11/16 spawn nothing.  Scroll-48 collection stays where it is.
spawnspecialsectors()
{
	for (i := 0; i < len lev.sectors; i++) {
		sec := lev.sectors[i];
		if (sec.special == 0)
			continue;
		if (sec.special == 1)
			spawnlightflash(sec);
		else if (sec.special == 2)
			spawnstrobeflash(sec, FASTDARK, 0);
		else if (sec.special == 3)
			spawnstrobeflash(sec, SLOWDARK, 0);
		else if (sec.special == 4) {
			spawnstrobeflash(sec, FASTDARK, 0);
			sec.special = 4;
		} else if (sec.special == 8)
			spawnglowinglight(sec);
		else if (sec.special == 10)
			spawndoorclosein30(sec);
		else if (sec.special == 12)
			spawnstrobeflash(sec, SLOWDARK, 1);
		else if (sec.special == 13)
			spawnstrobeflash(sec, FASTDARK, 1);
		else if (sec.special == 14)
			spawndoorraisein5mins(sec);
		else if (sec.special == 17)
			spawnfireflicker(sec);
	}
}

# vanilla EV_LightTurnOn (p_spec.c): set tagged sectors to bright
# (0 = brightest surrounding).  S1-35 passes 35.
evlightturnon(li, bright: int): int
{
	rtn := 0;
	for (i := 0; i < len lev.sectors; i++) {
		if (lev.sectors[i].tag != lev.lines[li].tag)
			continue;
		rtn = 1;
		if (bright == 0) {
			bright = 0;
			for (j := 0; j < len lev.lines; j++) {
				ld := lev.lines[j];
				other := ld.frontsector;
				if (ld.frontsector == lev.sectors[i]) {
					if (ld.backsector == lev.sectors[i])
						continue;
					other = ld.backsector;
				} else if (ld.backsector == lev.sectors[i]) {
					other = ld.frontsector;
				} else
					continue;
				if (other == nil)
					continue;
				if (other.lightlevel > bright)
					bright = other.lightlevel;
			}
		}
		lev.sectors[i].lightlevel = bright;
	}
	return rtn;
}

# vanilla P_CrossSpecialLine walkover subset (p_spec.c): W1 36/2/8/5/22/16/39/125
# (clear), WR 90/86/91/98/88/76/82/97/126 (retrigger).  The non-player gate allows
# only teleport/door/plat specials (the missile-type inner gate comes
# with weapons, milestone 9); secrets count in milestone 14.
crossspecialline(mo: ref Mobj, li, side: int)
{
	ld := lev.lines[li];
	if (mo.player == nil) {
		if (ld.special != 39 && ld.special != 97 &&
		    ld.special != 125 && ld.special != 126 &&
		    ld.special != 4 && ld.special != 10 &&
		    ld.special != 88)
			return;
	}
	if (ld.special == 36) {
		evdofloor(li, FL_TURBOLOWER);
		lc := lev.lines[li];	# Lines are values: copy back
		lc.special = 0;
		lev.lines[li] = lc;
	} else if (ld.special == 2) {		# W1 open door (stay open)
		evdodoor(li, VLD_OPEN);
		lc := lev.lines[li];
		lc.special = 0;
		lev.lines[li] = lc;
	} else if (ld.special == 90) {		# WR raise door (retrigger)
		evdodoor(li, VLD_NORMAL);
	} else if (ld.special == 8) {		# W1 stairs
		evbuildstairs(li);
		lc := lev.lines[li];
		lc.special = 0;
		lev.lines[li] = lc;
	} else if (ld.special == 5) {		# W1 raise floor
		evdofloor(li, FL_RAISEFLOOR);
		lc := lev.lines[li];
		lc.special = 0;
		lev.lines[li] = lc;
	} else if (ld.special == 16) {		# W1 close door 30
		evdodoor(li, VLD_CLOSE30THENOPEN);
		lc := lev.lines[li];
		lc.special = 0;
		lev.lines[li] = lc;
	} else if (ld.special == 76) {		# WR close door 30 (retrigger)
		evdodoor(li, VLD_CLOSE30THENOPEN);
	} else if (ld.special == 82) {		# WR lower floor to lowest
		evdofloor(li, FL_LOWERFLOORTOWELOWEST);
	} else if (ld.special == 39 || ld.special == 125) {	# W1 teleport
		evteleport(li, side, mo);
		lc := lev.lines[li];
		lc.special = 0;
		lev.lines[li] = lc;
	} else if (ld.special == 97 || ld.special == 126) {	# WR teleport
		evteleport(li, side, mo);
	} else if (ld.special == 86) {		# WR open door (retrigger)
		evdodoor(li, VLD_OPEN);
	} else if (ld.special == 22) {		# W1 raise-to-nearest plat
		evdoplat(li, PL_RAISETONEARESTANDCHANGE, 0);
		lc := lev.lines[li];
		lc.special = 0;
		lev.lines[li] = lc;
	} else if (ld.special == 91) {		# WR raise floor (retrigger)
		evdofloor(li, FL_RAISEFLOOR);
	} else if (ld.special == 98) {		# WR turbo lower (retrigger)
		evdofloor(li, FL_TURBOLOWER);
	} else if (ld.special == 88) {
		evdoplat(li, PL_DOWNWAITUPSTAY, 0);
	}
	# side feeds teleport/donut only (later milestones)
}

# vanilla P_StartButton (p_switch.c): arm a flip-back timer unless
# the line already has one; silently skip when full (vanilla I_Error)
pstartbutton(li, where: int, texture: string, time: int)
{
	for (i := 0; i < MAXBUTTONS; i++)
		if (buttonlist[i].btimer != 0 && buttonlist[i].li == li)
			return;
	for (i = 0; i < MAXBUTTONS; i++) {
		if (buttonlist[i].btimer == 0) {
			buttonlist[i].li = li;
			buttonlist[i].where = where;
			buttonlist[i].btexture = texture;
			buttonlist[i].btimer = time;
			return;
		}
	}
}

# vanilla P_ChangeSwitchTexture (p_switch.c): texture swap on side 0
# by switch-name pairs.  The == 11 sound check sits after the special
# clear exactly like vanilla (dead for useAgain == 0 - faithfully
# dead).  useAgain arms the flip-back button timer (SR switches).
changeswitchtexture(li, useAgain: int)
{
	if (useAgain == 0) {
		lc := lev.lines[li];
		lc.special = 0;
		lev.lines[li] = lc;
	}
	ld := lev.lines[li];
	if (ld.sides[0] == nil)
		return;
	soundnum := sound->SFX_SWTCHN;
	if (ld.special == 11)
		soundnum = sound->SFX_SWTCHX;
	for (i := 0; i < len switchpairs; i++) {
		(a, b) := switchpairs[i];
		if (a == ld.sides[0].toptexture) {
			sound->startsound(0, 0, soundnum);
			ld.sides[0].toptexture = b;
			if (useAgain != 0)
				pstartbutton(li, BW_TOP, a, BUTTONTIME);
			return;
		}
		if (a == ld.sides[0].midtexture) {
			sound->startsound(0, 0, soundnum);
			ld.sides[0].midtexture = b;
			if (useAgain != 0)
				pstartbutton(li, BW_MIDDLE, a, BUTTONTIME);
			return;
		}
		if (a == ld.sides[0].bottomtexture) {
			sound->startsound(0, 0, soundnum);
			ld.sides[0].bottomtexture = b;
			if (useAgain != 0)
				pstartbutton(li, BW_BOTTOM, a, BUTTONTIME);
			return;
		}
	}
}

# vanilla G_ExitLevel (g_game.c), flag only: the intermission
# (milestone 16) consumes it
gexitlevel()
{
	exited = 1;
}

levexit(): int
{
	return exited;
}

# vanilla G_SecretExitLevel (g_game.c): shareware has no MAP31 so
# the commercial-only guard never fires here; flag only like above
gsecretexitlevel()
{
	sexited = 1;
}

secretexit(): int
{
	return sexited;
}

# ---------------------------------------------------------------------------
# movement
# ---------------------------------------------------------------------------

thrust(p: ref Player, angle, move: int)
{
	a := (angle >> ANGLETOFINESHIFT) & FINEMASK;
	p.mo.momx = p.mo.momx + rend->fixedmul(move, inf->finesine[a + 2048]);
	p.mo.momy = p.mo.momy + rend->fixedmul(move, inf->finesine[a]);
}

moveplayer(p: ref Player)
{
	cmd := p.cmd;
	p.mo.angle = p.mo.angle + (cmd.angleturn << 16);

	onground := p.mo.z <= p.mo.floorz;
	if (cmd.forwardmove != 0 && onground)
		thrust(p, p.mo.angle, cmd.forwardmove * 2048);
	if (cmd.sidemove != 0 && onground)
		thrust(p, p.mo.angle - ANG90, cmd.sidemove * 2048);

	if ((cmd.forwardmove != 0 || cmd.sidemove != 0) &&
	    p.mo.state == inf->S_PLAY)
		setmobjstate(p.mo, inf->S_PLAY_RUN1);
}

calcheight(p: ref Player)
{
	bob := rend->fixedmul(p.mo.momx, p.mo.momx) +
		rend->fixedmul(p.mo.momy, p.mo.momy);
	bob = bob >> 2;
	if (bob > MAXBOB)
		bob = MAXBOB;
	p.bob = bob;

	onground := p.mo.z <= p.mo.floorz;
	if ((p.cheats & CF_NOMOMENTUM) != 0 || !onground) {
		p.viewz = p.mo.z + VIEWHEIGHT;
		if (p.viewz > p.mo.ceilingz - 4 * FRACUNIT)
			p.viewz = p.mo.ceilingz - 4 * FRACUNIT;
		p.viewz = p.mo.z + p.viewheight;
		return;
	}

	angle := ((FINEANGLES / 20) * lvltime) & FINEMASK;
	bob = rend->fixedmul(p.bob / 2, inf->finesine[angle]);

	if (p.playerstate == PST_LIVE) {
		p.viewheight = p.viewheight + p.deltaviewheight;
		if (p.viewheight > VIEWHEIGHT) {
			p.viewheight = VIEWHEIGHT;
			p.deltaviewheight = 0;
		}
		if (p.viewheight < VIEWHEIGHT / 2) {
			p.viewheight = VIEWHEIGHT / 2;
			if (p.deltaviewheight <= 0)
				p.deltaviewheight = 1;
		}
		if (p.deltaviewheight != 0) {
			p.deltaviewheight = p.deltaviewheight + FRACUNIT / 4;
			if (p.deltaviewheight == 0)
				p.deltaviewheight = 1;
		}
	}
	p.viewz = p.mo.z + p.viewheight + bob;
	if (p.viewz > p.mo.ceilingz - 4 * FRACUNIT)
		p.viewz = p.mo.ceilingz - 4 * FRACUNIT;
}

deaththink(p: ref Player)
{
	if (p.viewheight > 6 * FRACUNIT)
		p.viewheight = p.viewheight - FRACUNIT;
	if (p.viewheight < 6 * FRACUNIT)
		p.viewheight = 6 * FRACUNIT;
	p.deltaviewheight = 0;
	calcheight(p);
	# use-button respawn / messaging later
}

playerthink(p: ref Player)
{
	if ((p.cheats & CF_NOCLIP) != 0)
		p.mo.flags = p.mo.flags | inf->MF_NOCLIP;
	else
		p.mo.flags = p.mo.flags & ~inf->MF_NOCLIP;

	if ((p.mo.flags & inf->MF_JUSTATTACKED) != 0) {
		p.cmd.angleturn = 0;
		p.cmd.forwardmove = 16rc800 / 512;
		p.cmd.sidemove = 0;
		p.mo.flags = p.mo.flags & ~inf->MF_JUSTATTACKED;
	}

	if (p.playerstate == PST_DEAD) {
		deaththink(p);
		return;
	}

	# power durations (vanilla P_PlayerThink: strength counts up to
	# diminish fade; invisibility drops its shadow flag at zero)
	if (p.powers[PW_STRENGTH] != 0)
		p.powers[PW_STRENGTH]++;
	if (p.powers[PW_INVULNERABILITY] != 0)
		p.powers[PW_INVULNERABILITY]--;
	if (p.powers[PW_INVISIBILITY] != 0) {
		p.powers[PW_INVISIBILITY]--;
		if (p.powers[PW_INVISIBILITY] == 0)
			p.mo.flags = p.mo.flags & ~inf->MF_SHADOW;
	}
	if (p.powers[PW_INFRARED] != 0)
		p.powers[PW_INFRARED]--;
	if (p.powers[PW_IRONFEET] != 0)
		p.powers[PW_IRONFEET]--;

	if (p.mo.reactiontime != 0)
		p.mo.reactiontime = p.mo.reactiontime - 1;
	else
		moveplayer(p);

	calcheight(p);

	# weapon change requests (vanilla P_PlayerThink order: change,
	# then use, then psprites; validation + switch animation land
	# with milestone 11, which consumes pendingweapon)
	if ((p.cmd.buttons & BT_CHANGE) != 0) {
		newweapon := (p.cmd.buttons & BT_WEAPONMASK) >> BT_WEAPONSHIFT;
		if (newweapon == WP_CHAINSAW && p.weaponowned[WP_CHAINSAW] != 0 &&
		    !(p.readyweapon == WP_CHAINSAW && p.powers[PW_STRENGTH] != 0))
			newweapon = WP_FIST;
		if (p.weaponowned[newweapon] != 0 && newweapon != p.readyweapon)
			p.pendingweapon = newweapon;
	}

	# use-lines on the BT_USE rising edge (vanilla P_PlayerThink);
	# weapon change / specials damage later
	if ((p.cmd.buttons & BT_USE) != 0) {
		if (p.usedown == 0) {
			uselines(p);
			p.usedown = 1;
		}
	} else
		p.usedown = 0;

	# attack on the BT_ATTACK rising edge; interim direct-fire pistol
	# (milestone 11 wires A_FirePistol psprite states instead)
	if ((p.cmd.buttons & BT_ATTACK) != 0) {
		if (p.attackdown == 0) {
			p.attackdown = 1;
			firepistol(p);
		}
	} else
		p.attackdown = 0;

	# P_PlayerInSpecialSector: later
}

xymovement(mo: ref Mobj)
{
	if (mo.momx == 0 && mo.momy == 0) {
		if ((mo.flags & inf->MF_SKULLFLY) != 0) {
			mo.flags = mo.flags & ~inf->MF_SKULLFLY;
			mo.momx = 0;
			mo.momy = 0;
			mo.momz = 0;
			setmobjstate(mo, mo.info.spawnstate);
		}
		return;
	}

	if (mo.momx > MAXMOVE)
		mo.momx = MAXMOVE;
	else if (mo.momx < -MAXMOVE)
		mo.momx = -MAXMOVE;
	if (mo.momy > MAXMOVE)
		mo.momy = MAXMOVE;
	else if (mo.momy < -MAXMOVE)
		mo.momy = -MAXMOVE;

	xmove := mo.momx;
	ymove := mo.momy;
	for (;;) {
		ptryx := 0;
		ptryy := 0;
		if (xmove > MAXMOVE / 2 || ymove > MAXMOVE / 2) {
			ptryx = mo.x + xmove / 2;
			ptryy = mo.y + ymove / 2;
			xmove = xmove >> 1;
			ymove = ymove >> 1;
		} else {
			ptryx = mo.x + xmove;
			ptryy = mo.y + ymove;
			xmove = 0;
			ymove = 0;
		}
		if (!trymove(mo, ptryx, ptryy)) {
			if (mo.player != nil) {
				slidemove(mo);
			} else if ((mo.flags & inf->MF_MISSILE) != 0) {
				# vanilla sky hack (p_mobj.c): missiles hitting
				# sky ceilings vanish silently (no explosion)
				if (ceilingline >= 0 && ceilingline < len lev.lines &&
				    lev.lines[ceilingline].backsector != nil &&
				    lev.lines[ceilingline].backsector.ceilingtexture == SKYFLAT) {
					removemobj(mo);
					return;
				}
				explodemissile(mo);
				return;
			} else {
				mo.momx = 0;
				mo.momy = 0;
			}
		}
		if (xmove == 0 && ymove == 0)
			break;
	}

	if (mo.player != nil && (mo.player.cheats & CF_NOMOMENTUM) != 0) {
		mo.momx = 0;
		mo.momy = 0;
		return;
	}
	if ((mo.flags & (inf->MF_MISSILE | inf->MF_SKULLFLY)) != 0)
		return;
	if (mo.z > mo.floorz)
		return;
	if ((mo.flags & inf->MF_CORPSE) != 0) {
		if (mo.momx > FRACUNIT / 4 || mo.momx < -FRACUNIT / 4 ||
		    mo.momy > FRACUNIT / 4 || mo.momy < -FRACUNIT / 4) {
			if (mo.floorz != mo.subsector.sector.floorheight)
				return;
		}
	}
	if (mo.momx > -STOPSPEED && mo.momx < STOPSPEED &&
	    mo.momy > -STOPSPEED && mo.momy < STOPSPEED &&
	    (mo.player == nil ||
	     (mo.player.cmd.forwardmove == 0 && mo.player.cmd.sidemove == 0))) {
		if (mo.player != nil) {
			st := mo.player.mo.state;
			if (st >= inf->S_PLAY_RUN1 && st < inf->S_PLAY_RUN1 + 4)
				setmobjstate(mo.player.mo, inf->S_PLAY);
		}
		mo.momx = 0;
		mo.momy = 0;
	} else {
		mo.momx = rend->fixedmul(mo.momx, FRICTION);
		mo.momy = rend->fixedmul(mo.momy, FRICTION);
	}
}

zmovement(mo: ref Mobj)
{
	if (mo.player != nil && mo.z < mo.floorz) {
		mo.player.viewheight = mo.player.viewheight - (mo.floorz - mo.z);
		mo.player.deltaviewheight = (VIEWHEIGHT - mo.player.viewheight) >> 3;
	}

	mo.z = mo.z + mo.momz;

	# float-to-target skipped (no floaters with targets yet)

	if (mo.z <= mo.floorz) {
		if (mo.momz < 0) {
			if (mo.player != nil && mo.momz < -GRAVITY * 8)
				mo.player.deltaviewheight = mo.momz >> 3;
			mo.momz = 0;
		}
		mo.z = mo.floorz;
		if ((mo.flags & inf->MF_MISSILE) != 0 &&
		    (mo.flags & inf->MF_NOCLIP) == 0) {
			explodemissile(mo);
			return;
		}
	} else if ((mo.flags & inf->MF_NOGRAVITY) == 0) {
		if (mo.momz == 0)
			mo.momz = -GRAVITY * 2;
		else
			mo.momz = mo.momz - GRAVITY;
	}

	if (mo.z + mo.height > mo.ceilingz) {
		if (mo.momz > 0)
			mo.momz = 0;
		mo.z = mo.ceilingz - mo.height;
		if ((mo.flags & inf->MF_MISSILE) != 0 &&
		    (mo.flags & inf->MF_NOCLIP) == 0) {
			explodemissile(mo);
			return;
		}
	}
}

# ---------------------------------------------------------------------------
# collision (brute force over all lines / mobjs)
# ---------------------------------------------------------------------------

pointonlineside(x, y, n: int): int
{
	ld := lev.lines[n];
	v1 := lev.vertices[ld.v1];
	if (ld.dx == 0) {
		if (x <= v1.x)
			return ld.dy > 0;
		return ld.dy < 0;
	}
	if (ld.dy == 0) {
		if (y <= v1.y)
			return ld.dx < 0;
		return ld.dx > 0;
	}
	dx := x - v1.x;
	dy := y - v1.y;
	left := rend->fixedmul(ld.dy >> 16, dx);
	right := rend->fixedmul(dy, ld.dx >> 16);
	if (right < left)
		return 0;
	return 1;
}

boxonlineside(box: array of int, n: int): int
{
	ld := lev.lines[n];
	v1 := lev.vertices[ld.v1];
	p1 := 0;
	p2 := 0;
	st := ld.slopetype;
	if (st == map->ST_HORIZONTAL) {
		p1 = box[0] > v1.y;
		p2 = box[1] > v1.y;
		if (ld.dx < 0) {
			p1 = p1 ^ 1;
			p2 = p2 ^ 1;
		}
	} else if (st == map->ST_VERTICAL) {
		p1 = box[2] < v1.x;
		p2 = box[3] < v1.x;
		if (ld.dy < 0) {
			p1 = p1 ^ 1;
			p2 = p2 ^ 1;
		}
	} else if (st == map->ST_POSITIVE) {
		p1 = pointonlineside(box[3], box[0], n);	# LEFT, TOP
		p2 = pointonlineside(box[2], box[1], n);	# RIGHT, BOTTOM
	} else {
		p1 = pointonlineside(box[2], box[0], n);	# RIGHT, TOP
		p2 = pointonlineside(box[3], box[1], n);	# LEFT, BOTTOM
	}
	if (p1 == p2)
		return p1;
	return -1;
}

lineopening(n: int)
{
	ld := lev.lines[n];
	if (ld.sides[1] == nil) {		# single sided
		openrange = 0;
		return;
	}
	front := ld.frontsector;
	back := ld.backsector;
	if (front.ceilingheight < back.ceilingheight)
		opentop = front.ceilingheight;
	else
		opentop = back.ceilingheight;
	if (front.floorheight > back.floorheight) {
		openbottom = front.floorheight;
		lowfloor = back.floorheight;
	} else {
		openbottom = back.floorheight;
		lowfloor = front.floorheight;
	}
	openrange = opentop - openbottom;
}

pitcheckline(n: int): int
{
	ld := lev.lines[n];
	if (tmbbox[2] <= ld.bbox[2] ||		# RIGHT <= LEFT
	    tmbbox[3] >= ld.bbox[3] ||		# LEFT >= RIGHT
	    tmbbox[0] <= ld.bbox[1] ||		# TOP <= BOTTOM
	    tmbbox[1] >= ld.bbox[0])		# BOTTOM >= TOP
		return 1;
	if (boxonlineside(tmbbox, n) != -1)
		return 1;

	if (ld.backsector == nil)
		return 0;			# one sided

	if ((tmflags & inf->MF_MISSILE) == 0) {
		if ((ld.flags & ML_BLOCKING) != 0)
			return 0;
		if (tmthing.player == nil && (ld.flags & ML_BLOCKMONSTERS) != 0)
			return 0;
	}

	lineopening(n);
	if (opentop < tmceilingz) {
		tmceilingz = opentop;
		ceilingline = n;
	}
	if (openbottom > tmfloorz)
		tmfloorz = openbottom;
	if (lowfloor < tmdropoffz)
		tmdropoffz = lowfloor;
	# spechit capture (vanilla PIT_CheckLine tail): contacted
	# special lines drain in trymove.  No overrun emulation:
	# contacts past MAXSPECIALCROSS are dropped instead of
	# smashing the stack for -spechit demo compat.
	if (ld.special != 0 && nspechit < MAXSPECIALCROSS) {
		spechit[nspechit] = n;
		nspechit++;
	}
	return 1;
}

# ---------------------------------------------------------------------------
# interaction: pickups, damage, death (milestone 9, p_inter.c).
# Reference: doomgeneric p_inter.c (GPL-2).  Transcribed mechanically
# except: player->message assignments skipped (no message field until
# HUD milestone 19); netgame branches omitted (single-player only);
# I_Error on unknown sprites becomes a silent skip (shareware
# touchables are all cased); P_DropWeapon is a no-op stub here (lowers
# the psprite, owned by weapons milestone 11).
# ---------------------------------------------------------------------------

# ammo per weapon (d_items.c weaponinfo ammo column, WP_* order)
# and clip-load sizes (p_inter.c clipammo, AM_* order)

pgiveammo(p: ref Player, ammo, num: int): int
{
	if (ammo == AM_NOAMMO)
		return 0;
	if (ammo < 0 || ammo >= NUMAMMO)
		fail("pgiveammo: bad type");
	if (p.ammo[ammo] == p.maxammo[ammo])
		return 0;
	if (num != 0)
		num *= clipammo[ammo];
	else
		num = clipammo[ammo] / 2;
	if (gameskill == SK_BABY || gameskill == SK_NIGHTMARE)
		num <<= 1;		# double ammo in trainer/nightmare
	oldammo := p.ammo[ammo];
	p.ammo[ammo] += num;
	if (p.ammo[ammo] > p.maxammo[ammo])
		p.ammo[ammo] = p.maxammo[ammo];
	if (oldammo != 0)
		return 1;		# was already armed, no weapon switch
	if (ammo == AM_CLIP && p.readyweapon == WP_FIST) {
		if (p.weaponowned[WP_CHAINGUN] != 0)
			p.pendingweapon = WP_CHAINGUN;
		else
			p.pendingweapon = WP_PISTOL;
	} else if (ammo == AM_SHELL &&
	    (p.readyweapon == WP_FIST || p.readyweapon == WP_PISTOL)) {
		if (p.weaponowned[WP_SHOTGUN] != 0)
			p.pendingweapon = WP_SHOTGUN;
	} else if (ammo == AM_CELL &&
	    (p.readyweapon == WP_FIST || p.readyweapon == WP_PISTOL)) {
		if (p.weaponowned[WP_PLASMA] != 0)
			p.pendingweapon = WP_PLASMA;
	} else if (ammo == AM_MISL && p.readyweapon == WP_FIST) {
		if (p.weaponowned[WP_MISSILE] != 0)
			p.pendingweapon = WP_MISSILE;
	}
	return 1;
}

pgiveweapon(p: ref Player, weapon, dropped: int): int
{
	# netgame placed-weapon branch omitted (single-player only)
	ammo := weaponammo[weapon];
	gaveammo := 0;
	if (ammo != AM_NOAMMO) {
		if (dropped != 0)
			gaveammo = pgiveammo(p, ammo, 1);
		else
			gaveammo = pgiveammo(p, ammo, 2);
	}
	gaveweapon := 0;
	if (p.weaponowned[weapon] == 0) {
		gaveweapon = 1;
		p.weaponowned[weapon] = 1;
		p.pendingweapon = weapon;
	}
	if (gaveweapon != 0 || gaveammo != 0)
		return 1;
	return 0;
}

pgivebody(p: ref Player, num: int): int
{
	if (p.health >= MAXHEALTH)
		return 0;
	p.health += num;
	if (p.health > MAXHEALTH)
		p.health = MAXHEALTH;
	p.mo.health = p.health;
	return 1;
}

pgivearmor(p: ref Player, armortype: int): int
{
	hits := armortype * 100;
	if (p.armorpoints >= hits)
		return 0;		# don't pick up
	p.armortype = armortype;
	p.armorpoints = hits;
	return 1;
}

pgivecard(p: ref Player, card: int)
{
	if (p.cards[card] != 0)
		return;
	p.bonuscount = BONUSADD;
	p.cards[card] = 1;
}

pgivepower(p: ref Player, power: int): int
{
	if (power == PW_INVULNERABILITY) {
		p.powers[power] = INVULNTICS;
		return 1;
	}
	if (power == PW_INVISIBILITY) {
		p.powers[power] = INVISTICS;
		p.mo.flags = p.mo.flags | inf->MF_SHADOW;
		return 1;
	}
	if (power == PW_INFRARED) {
		p.powers[power] = INFRATICS;
		return 1;
	}
	if (power == PW_IRONFEET) {
		p.powers[power] = IRONTICS;
		return 1;
	}
	if (power == PW_STRENGTH) {
		pgivebody(p, 100);
		p.powers[power] = 1;
		return 1;
	}
	if (p.powers[power] != 0)
		return 0;		# already got it
	p.powers[power] = 1;
	return 1;
}

# vanilla P_TouchSpecialThing (p_inter.c): sprite-dispatched pickup.
# Messages skipped (HUD milestone 19); megasphere untouchable in
# shareware (commercial guard transcribed as bare return).
ptouchspecialthing(special, toucher: ref Mobj)
{
	player := toucher.player;
	if (player == nil)
		return;		# vanilla would crash; only MF_PICKUP calls
	delta := special.z - toucher.z;
	if (delta > toucher.height || delta < -8 * FRACUNIT)
		return;			# out of reach
	if (toucher.health <= 0)
		return;			# sliding corpse touches nothing
	soundnum := sound->SFX_ITEMUP;
	spr := special.sprite;
	matched := 0;
	if (spr == inf->SPR_ARM1) {
		matched = 1;
		if (pgivearmor(player, 1) == 0)
			return;
	}
	if (spr == inf->SPR_ARM2) {
		matched = 1;
		if (pgivearmor(player, 2) == 0)
			return;
	}
	if (spr == inf->SPR_BON1) {
		matched = 1;
		player.health++;
		if (player.health > 200)
			player.health = 200;
		player.mo.health = player.health;
	}
	if (spr == inf->SPR_BON2) {
		matched = 1;
		player.armorpoints++;
		if (player.armorpoints > 200)
			player.armorpoints = 200;
		if (player.armortype == 0)
			player.armortype = 1;
	}
	if (spr == inf->SPR_SOUL) {
		matched = 1;
		player.health += 100;
		if (player.health > 200)
			player.health = 200;
		player.mo.health = player.health;
		soundnum = sound->SFX_GETPOW;
	}
	if (spr == inf->SPR_MEGA) {
		matched = 1;
		return;			# commercial only; not in shareware
	}
	if (spr == inf->SPR_BKEY) {
		matched = 1;
		pgivecard(player, IT_BLUECARD);
	}
	if (spr == inf->SPR_YKEY) {
		matched = 1;
		pgivecard(player, IT_YELLOWCARD);
	}
	if (spr == inf->SPR_RKEY) {
		matched = 1;
		pgivecard(player, IT_REDCARD);
	}
	if (spr == inf->SPR_BSKU) {
		matched = 1;
		pgivecard(player, IT_BLUESKULL);
	}
	if (spr == inf->SPR_YSKU) {
		matched = 1;
		pgivecard(player, IT_YELLOWSKULL);
	}
	if (spr == inf->SPR_RSKU) {
		matched = 1;
		pgivecard(player, IT_REDSKULL);
	}
	if (spr == inf->SPR_STIM) {
		matched = 1;
		if (pgivebody(player, 10) == 0)
			return;
	}
	if (spr == inf->SPR_MEDI) {
		matched = 1;
		if (pgivebody(player, 25) == 0)
			return;
	}
	if (spr == inf->SPR_PINV) {
		matched = 1;
		if (pgivepower(player, PW_INVULNERABILITY) == 0)
			return;
		soundnum = sound->SFX_GETPOW;
	}
	if (spr == inf->SPR_PSTR) {
		matched = 1;
		if (pgivepower(player, PW_STRENGTH) == 0)
			return;
		if (player.readyweapon != WP_FIST)
			player.pendingweapon = WP_FIST;
		soundnum = sound->SFX_GETPOW;
	}
	if (spr == inf->SPR_PINS) {
		matched = 1;
		if (pgivepower(player, PW_INVISIBILITY) == 0)
			return;
		soundnum = sound->SFX_GETPOW;
	}
	if (spr == inf->SPR_SUIT) {
		matched = 1;
		if (pgivepower(player, PW_IRONFEET) == 0)
			return;
		soundnum = sound->SFX_GETPOW;
	}
	if (spr == inf->SPR_PMAP) {
		matched = 1;
		if (pgivepower(player, PW_ALLMAP) == 0)
			return;
		soundnum = sound->SFX_GETPOW;
	}
	if (spr == inf->SPR_PVIS) {
		matched = 1;
		if (pgivepower(player, PW_INFRARED) == 0)
			return;
		soundnum = sound->SFX_GETPOW;
	}
	if (spr == inf->SPR_CLIP) {
		matched = 1;
		if ((special.flags & inf->MF_DROPPED) != 0) {
			if (pgiveammo(player, AM_CLIP, 0) == 0)
				return;
		} else if (pgiveammo(player, AM_CLIP, 1) == 0)
			return;
	}
	if (spr == inf->SPR_AMMO) {
		matched = 1;
		if (pgiveammo(player, AM_CLIP, 5) == 0)
			return;
	}
	if (spr == inf->SPR_ROCK) {
		matched = 1;
		if (pgiveammo(player, AM_MISL, 1) == 0)
			return;
	}
	if (spr == inf->SPR_BROK) {
		matched = 1;
		if (pgiveammo(player, AM_MISL, 5) == 0)
			return;
	}
	if (spr == inf->SPR_CELL) {
		matched = 1;
		if (pgiveammo(player, AM_CELL, 1) == 0)
			return;
	}
	if (spr == inf->SPR_CELP) {
		matched = 1;
		if (pgiveammo(player, AM_CELL, 5) == 0)
			return;
	}
	if (spr == inf->SPR_SHEL) {
		matched = 1;
		if (pgiveammo(player, AM_SHELL, 1) == 0)
			return;
	}
	if (spr == inf->SPR_SBOX) {
		matched = 1;
		if (pgiveammo(player, AM_SHELL, 5) == 0)
			return;
	}
	if (spr == inf->SPR_BPAK) {
		matched = 1;
		if (player.backpack == 0) {
			for (i := 0; i < NUMAMMO; i++)
				player.maxammo[i] *= 2;
			player.backpack = 1;
		}
		for (i := 0; i < NUMAMMO; i++)
			pgiveammo(player, i, 1);
	}
	if (spr == inf->SPR_BFUG) {
		matched = 1;
		if (pgiveweapon(player, WP_BFG, 0) == 0)
			return;
		soundnum = sound->SFX_WPNUP;
	}
	if (spr == inf->SPR_MGUN) {
		matched = 1;
		dropped := 0;
		if ((special.flags & inf->MF_DROPPED) != 0)
			dropped = 1;
		if (pgiveweapon(player, WP_CHAINGUN, dropped) == 0)
			return;
		soundnum = sound->SFX_WPNUP;
	}
	if (spr == inf->SPR_CSAW) {
		matched = 1;
		if (pgiveweapon(player, WP_CHAINSAW, 0) == 0)
			return;
		soundnum = sound->SFX_WPNUP;
	}
	if (spr == inf->SPR_LAUN) {
		matched = 1;
		if (pgiveweapon(player, WP_MISSILE, 0) == 0)
			return;
		soundnum = sound->SFX_WPNUP;
	}
	if (spr == inf->SPR_PLAS) {
		matched = 1;
		if (pgiveweapon(player, WP_PLASMA, 0) == 0)
			return;
		soundnum = sound->SFX_WPNUP;
	}
	if (spr == inf->SPR_SHOT) {
		matched = 1;
		dropped := 0;
		if ((special.flags & inf->MF_DROPPED) != 0)
			dropped = 1;
		if (pgiveweapon(player, WP_SHOTGUN, dropped) == 0)
			return;
		soundnum = sound->SFX_WPNUP;
	}
	if (spr == inf->SPR_SGN2) {
		matched = 1;
		dropped := 0;
		if ((special.flags & inf->MF_DROPPED) != 0)
			dropped = 1;
		if (pgiveweapon(player, WP_SUPERSHOTGUN, dropped) == 0)
			return;
		soundnum = sound->SFX_WPNUP;
	}
	if (matched == 0)
		return;			# vanilla I_Errors; not a shareware pickup
	if ((special.flags & inf->MF_COUNTITEM) != 0)
		player.itemcount++;
	removemobj(special);
	player.bonuscount += BONUSADD;
	if (player == players[0])
		sound->startsound(0, 0, soundnum);
}

# vanilla P_DropWeapon hook: puts the weapon away on death by
# lowering the psprite (owned by weapons milestone 11); no-op here.
psprdropweapon(p: ref Player)
{
	p = p;
}

# vanilla P_KillMobj (p_inter.c): corpse flags, counts, player
# death, gib check, shareware item drops.  Pain/death sounds play
# through A_ actions (milestones 11/12), not here.
pkillmobj(source, target: ref Mobj)
{
	target.flags = target.flags & ~(inf->MF_SHOOTABLE | inf->MF_FLOAT | inf->MF_SKULLFLY);
	if (target.typ != inf->MT_SKULL)
		target.flags = target.flags & ~inf->MF_NOGRAVITY;
	target.flags = target.flags | inf->MF_CORPSE | inf->MF_DROPOFF;
	target.height >>= 2;
	if (source != nil && source.player != nil) {
		if ((target.flags & inf->MF_COUNTKILL) != 0)
			source.player.killcount++;
		if (target.player != nil) {
			for (i := 0; i < MAXPLAYERS; i++)
				if (players[i] == target.player)
					source.player.frags[i]++;
		}
	} else if ((target.flags & inf->MF_COUNTKILL) != 0) {
		# single-player (no netgame): count monster infights too
		if (players[0] != nil)
			players[0].killcount++;
	}
	if (target.player != nil) {
		p := target.player;
		if (source == nil) {
			for (i := 0; i < MAXPLAYERS; i++)
				if (players[i] == p)
					p.frags[i]++;
		}
		target.flags = target.flags & ~inf->MF_SOLID;
		p.playerstate = PST_DEAD;
		psprdropweapon(p);
	}
	if (target.health < -target.info.spawnhealth &&
	    target.info.xdeathstate != inf->S_NULL)
		setmobjstate(target, target.info.xdeathstate);
	else
		setmobjstate(target, target.info.deathstate);
	target.tics -= prandom() & 3;
	if (target.tics < 1)
		target.tics = 1;
	# shareware drops (chex guard omitted: never chex here)
	item := -1;
	if (target.typ == inf->MT_WOLFSS || target.typ == inf->MT_POSSESSED)
		item = inf->MT_CLIP;
	else if (target.typ == inf->MT_SHOTGUY)
		item = inf->MT_SHOTGUN;
	else if (target.typ == inf->MT_CHAINGUY)
		item = inf->MT_CHAINGUN;
	if (item >= 0) {
		drop := spawnmobj(target.x, target.y, ONFLOORZ, item);
		drop.flags = drop.flags | inf->MF_DROPPED;
	}
}

# vanilla P_DamageMobj (p_inter.c): thrust, armor, death, pain,
# retaliation.  Pain/death SOUNDS play through A_ actions
# (milestones 11/12); I_Tactile has no Inferno equivalent.
pdamagemobj(target, inflictor, source: ref Mobj, damage: int)
{
	if ((target.flags & inf->MF_SHOOTABLE) == 0)
		return;
	if (target.health <= 0)
		return;
	if ((target.flags & inf->MF_SKULLFLY) != 0) {
		target.momx = 0;
		target.momy = 0;
		target.momz = 0;
	}
	player := target.player;
	if (player != nil && gameskill == SK_BABY)
		damage >>= 1;
	if (inflictor != nil && (target.flags & inf->MF_NOCLIP) == 0 &&
	    (source == nil || source.player == nil ||
	     source.player.readyweapon != WP_CHAINSAW)) {
		ang := pointtoangle2(inflictor.x, inflictor.y,
			target.x, target.y);
		thrust := damage * (FRACUNIT >> 3) * 100 / target.info.mass;
		if (damage < 40 && damage > target.health &&
		    target.z - inflictor.z > 64 * FRACUNIT &&
		    (prandom() & 1) != 0) {
			ang += ANG180;
			thrust *= 4;
		}
		a := (ang >> ANGLETOFINESHIFT) & FINEMASK;
		target.momx += rend->fixedmul(thrust, inf->finesine[(a + 2048) & FINEMASK]);
		target.momy += rend->fixedmul(thrust, inf->finesine[a]);
	}
	if (player != nil) {
		# E1M8 finale hell-hack: exit instead of dying
		if (target.subsector.sector.special == 11 && damage >= target.health)
			damage = target.health - 1;
		if (damage < 1000 && ((player.cheats & CF_GODMODE) != 0 ||
		    player.powers[PW_INVULNERABILITY] != 0))
			return;
		if (player.armortype != 0) {
			if (player.armortype == 1)
				saved := damage / 3;
			else
				saved = damage / 2;
			if (player.armorpoints <= saved) {
				saved = player.armorpoints;
				player.armortype = 0;
			}
			player.armorpoints -= saved;
			damage -= saved;
		}
		player.health -= damage; 	# mirror mobj health here for Dave
		if (player.health < 0)
			player.health = 0;
		player.attacker = source;
		player.damagecount += damage;
		if (player.damagecount > 100)
			player.damagecount = 100;
	}
	target.health -= damage;
	if (target.health <= 0) {
		pkillmobj(source, target);
		return;
	}
	if (prandom() < target.info.painchance &&
	    (target.flags & inf->MF_SKULLFLY) == 0) {
		target.flags = target.flags | inf->MF_JUSTHIT;
		setmobjstate(target, target.info.painstate);
	}
	target.reactiontime = 0;
	if ((target.threshold == 0 || target.typ == inf->MT_VILE) &&
	    source != nil && source != target &&
	    source.typ != inf->MT_VILE) {
		target.target = source;
		target.threshold = BASETHRESHOLD;
		if (target.state == target.info.spawnstate &&
		    target.info.seestate != inf->S_NULL)
			setmobjstate(target, target.info.seestate);
	}
}

# sight gate for radius attacks (vanilla P_CheckSight, owned by AI
# milestone 12); permissive until then (no callers exist yet)
pchecksight(a, b: ref Mobj): int
{
	a = a;
	b = b;
	return 1;
}

# vanilla PIT_RadiusAttack (p_map.c): concussion damage with linear
# falloff over map-unit distance; bosses immune.  Brute-forces the
# mobj list (no blockmap); caller sets bombspot/bombsource/bombdamage.
pitradiusattack(mo: ref Mobj): int
{
	if ((mo.flags & inf->MF_SHOOTABLE) == 0)
		return 1;
	if (mo.typ == inf->MT_CYBORG || mo.typ == inf->MT_SPIDER)
		return 1;
	dx := absi(mo.x - bombspot.x);
	dy := absi(mo.y - bombspot.y);
	dist := dx;
	if (dy > dx)
		dist = dy;
	dist = (dist - mo.radius) >> FRACBITS;
	if (dist < 0)
		dist = 0;
	if (dist >= bombdamage)
		return 1;
	if (pchecksight(mo, bombspot) != 0)
		pdamagemobj(mo, bombspot, bombsource, bombdamage - dist);
	return 1;
}

# vanilla P_RadiusAttack (p_map.c)
pradiusattack(spot, source: ref Mobj, damage: int)
{
	bombspot = spot;
	bombsource = source;
	bombdamage = damage;
	for (i := 0; i < len mobjs; i++) {
		mo := mobjs[i];
		if (mo.removed)
			continue;
		pitradiusattack(mo);
	}
}

pitcheckthing(thing: ref Mobj): int
{
	if (thing.removed)
		return 1;		# vanilla P_RemoveMobj unlinks at once;
				# lazy removal must skip everywhere instead
	if ((thing.flags & (inf->MF_SOLID | inf->MF_SPECIAL | inf->MF_SHOOTABLE)) == 0)
		return 1;
	blockdist := thing.radius + tmthing.radius;
	if (absi(thing.x - tmx) >= blockdist ||
	    absi(thing.y - tmy) >= blockdist)
		return 1;
	if (thing == tmthing)
		return 1;
	# skull slam (vanilla PIT_CheckThing): fixed damage + stop
	if ((tmthing.flags & inf->MF_SKULLFLY) != 0) {
		damage := ((prandom() % 8) + 1) * tmthing.info.damage;
		pdamagemobj(thing, tmthing, tmthing, damage);
		tmthing.flags = tmthing.flags & ~inf->MF_SKULLFLY;
		tmthing.momx = 0;
		tmthing.momy = 0;
		tmthing.momz = 0;
		setmobjstate(tmthing, tmthing.info.spawnstate);
		return 0;
	}
	# missiles can hit other things (vanilla PIT_CheckThing):
	# z over/under pass through, same-species non-players explode
	# without damage (the false return explodes via xymovement),
	# non-shootables don't block unless solid, else damage + stop.
	# (deh_species_infighting is OUT of scope: always the default.)
	if ((tmthing.flags & inf->MF_MISSILE) != 0) {
		if (tmthing.z > thing.z + thing.height)
			return 1;		# overhead
		if (tmthing.z + tmthing.height < thing.z)
			return 1;		# underneath
		tgt := tmthing.target;
		if (tgt != nil && (tgt.typ == thing.typ ||
		    (tgt.typ == inf->MT_KNIGHT && thing.typ == inf->MT_BRUISER) ||
		    (tgt.typ == inf->MT_BRUISER && thing.typ == inf->MT_KNIGHT))) {
			if (thing == tgt)
				return 1;
			if (thing.typ != inf->MT_PLAYER)
				return 0;	# explode, but do no damage
		}
		if ((thing.flags & inf->MF_SHOOTABLE) == 0)
			return (thing.flags & inf->MF_SOLID) == 0;
		damage := ((prandom() % 8) + 1) * tmthing.info.damage;
		pdamagemobj(thing, tmthing, tgt, damage);
		return 0;			# don't traverse any more
	}
	# special pickup (vanilla: MF_PICKUP toucher consumes)
	if ((thing.flags & inf->MF_SPECIAL) != 0) {
		solid := thing.flags & inf->MF_SOLID;
		if ((tmflags & inf->MF_PICKUP) != 0)
			ptouchspecialthing(thing, tmthing);
		return solid == 0;
	}
	return (thing.flags & inf->MF_SOLID) == 0;
}

checkposition(thing: ref Mobj, x, y: int): int
{
	tmthing = thing;
	tmflags = thing.flags;
	tmx = x;
	tmy = y;
	nspechit = 0;			# vanilla P_CheckPosition reset
	tmbbox[0] = y + thing.radius;		# BOXTOP
	tmbbox[1] = y - thing.radius;		# BOXBOTTOM
	tmbbox[2] = x + thing.radius;		# BOXRIGHT
	tmbbox[3] = x - thing.radius;		# BOXLEFT

	ss := lev.pointsubsector(x, y);
	if (ss == nil)
		fail("checkposition: no subsector");
	ceilingline = -1;
	tmfloorz = ss.sector.floorheight;
	tmdropoffz = tmfloorz;
	tmceilingz = ss.sector.ceilingheight;

	if ((tmflags & inf->MF_NOCLIP) != 0)
		return 1;

	# newest-first: vanilla block links prepend, so fresh drops are
	# touched before the corpse underneath blocks (drop-on-corpse
	# pickup needs this order)
	for (i := len mobjs - 1; i >= 0; i--)
		if (!pitcheckthing(mobjs[i]))
			return 0;
	for (i = 0; i < len lev.lines; i++)
		if (!pitcheckline(i))
			return 0;
	return 1;
}

trymove(mo: ref Mobj, x, y: int): int
{
	oldx := mo.x;
	oldy := mo.y;
	floatok = 0;
	nspechit = 0;			# vanilla P_TryMove reset
	if (!checkposition(mo, x, y))
		return 0;
	if ((mo.flags & inf->MF_NOCLIP) == 0) {
		if (tmceilingz - tmfloorz < mo.height)
			return 0;
		floatok = 1;
		if ((mo.flags & inf->MF_TELEPORT) == 0 &&
		    tmceilingz - mo.z < mo.height)
			return 0;
		if ((mo.flags & inf->MF_TELEPORT) == 0 &&
		    tmfloorz - mo.z > 24 * FRACUNIT)
			return 0;
		if ((mo.flags & (inf->MF_DROPOFF | inf->MF_FLOAT)) == 0 &&
		    tmfloorz - tmdropoffz > 24 * FRACUNIT)
			return 0;
	}
	mo.floorz = tmfloorz;
	mo.ceilingz = tmceilingz;
	mo.x = x;
	mo.y = y;
	setthingposition(mo);
	# spechit drain (vanilla P_TryMove tail): newest first,
	# crossing test old-vs-new side, special rechecked (W1
	# clears).  Skipped with TELEPORT/NOCLIP like vanilla.
	if ((mo.flags & (inf->MF_TELEPORT | inf->MF_NOCLIP)) == 0) {
		for (nspechit = nspechit - 1; nspechit >= 0; nspechit--) {
			li := spechit[nspechit];
			side := pointonlineside(mo.x, mo.y, li);
			oldside := pointonlineside(oldx, oldy, li);
			if (side != oldside && lev.lines[li].special != 0)
				crossspecialline(mo, li, oldside);
		}
	}
	return 1;
}

# ---------------------------------------------------------------------------
# P_SlideMove (vanilla p_map.c): the xy move was blocked, so move flush
# to the wall and continue along it.  No blockmap: PIT_AddLineIntercepts'
# crossing test + P_InterceptVector frac run against every line; frac >
# FRACUNIT is dropped where vanilla P_TraverseIntercepts stops at
# maxfrac = FRACUNIT.  PT_ADDLINES only (slide never considers things).
# ---------------------------------------------------------------------------

# vanilla tables.c SlopeDiv (unsigned semantics; den < 512 includes any
# negative den, which only octant callers pass as >= 0 anyway)
slopediv(num, den: int): int
{
	if (den < 512)
		return SLOPERANGE;
	# (num << 3) wraps mod 2^32 in C; do the wrap in big
	u := big(num);
	if (u < big(0))
		u = u + 16r100000000;
	u = (u * big(8)) % 16r100000000;
	ans := u / big(den >> 8);
	if (ans > big(SLOPERANGE))
		return SLOPERANGE;
	return int ans;
}

# vanilla R_PointToAngle (r_main.c) relative to (x1,y1); result is the
# angle_t bit pattern in an int (wraps like C unsigned arithmetic).
pointtoangle2(x1, y1, x2, y2: int): int
{
	x := x2 - x1;
	y := y2 - y1;
	if (x == 0 && y == 0)
		return 0;
	if (x >= 0) {
		if (y >= 0) {
			if (x > y)
				return tantoangle[slopediv(y, x)];
			return ANG90 - 1 - tantoangle[slopediv(x, y)];
		}
		y = -y;
		if (x > y)
			return -tantoangle[slopediv(y, x)];
		return ANG270 + tantoangle[slopediv(x, y)];
	}
	x = -x;
	if (y >= 0) {
		if (x > y)
			return ANG180 - 1 - tantoangle[slopediv(y, x)];
		return ANG90 + tantoangle[slopediv(x, y)];
	}
	y = -y;
	if (x > y)
		return ANG180 + tantoangle[slopediv(y, x)];
	return ANG270 - 1 - tantoangle[slopediv(x, y)];
}

# vanilla P_PointOnDivlineSide (p_maputl.c): side of (x,y) wrt a divline
# through (lxx,lyy) with delta (ddx,ddy)
pointondvlineside(x, y, lxx, lyy, ddx, ddy: int): int
{
	if (ddx == 0) {
		if (x <= lxx)
			return ddy > 0;
		return ddy < 0;
	}
	if (ddy == 0) {
		if (y <= lyy)
			return ddx < 0;
		return ddx > 0;
	}
	dx := x - lxx;
	dy := y - lyy;
	# quick sign-bit test: (line->dy ^ line->dx ^ dx ^ dy) & 0x80000000
	if ((ddy ^ ddx ^ dx ^ dy) < 0) {
		if ((ddy ^ dx) < 0)
			return 1;
		return 0;
	}
	left := rend->fixedmul(ddy >> 8, dx >> 8);
	right := rend->fixedmul(dy >> 8, ddx >> 8);
	if (right < left)
		return 0;
	return 1;
}

# vanilla FixedDiv with the C saturation earlyout (m_fixed.c); rend's
# fixeddiv has none and raises when the quotient leaves int32
fixeddivsat(a, b: int): int
{
	aa := big(a);
	if (aa < big(0))
		aa = -aa;
	bb := big(b);
	if (bb < big(0))
		bb = -bb;
	if ((aa >> 14) >= bb) {
		if ((a ^ b) < 0)
			return ~2147483647;
		return 2147483647;
	}
	return int((big(a) << 16) / big(b));
}

# vanilla P_InterceptVector(v2 = trace, v1 = line) (p_maputl.c): frac
# along the trace where it crosses the line's divline
interceptvector(t2x, t2y, t2dx, t2dy, v1x, v1y, v1dx, v1dy: int): int
{
	den := rend->fixedmul(v1dy >> 8, t2dx) - rend->fixedmul(v1dx >> 8, t2dy);
	if (den == 0)
		return 0;
	num := rend->fixedmul((v1x - t2x) >> 8, v1dy)
		+ rend->fixedmul((t2y - v1y) >> 8, v1dx);
	return fixeddivsat(num, den);
}

# vanilla PTR_SlideTraverse (p_map.c) for one line at intercept frac:
# 0 = stop this ray, 1 = keep going
slidetraverse(n, frac: int): int
{
	ld := lev.lines[n];
	block := 0;
	if ((ld.flags & ML_TWOSIDED) == 0) {
		# one-sided: only blocks from the front side
		if (pointonlineside(slidemo.x, slidemo.y, n) == 0)
			block = 1;
	} else {
		lineopening(n);
		if (openrange < slidemo.height)
			block = 1;
		else if (opentop - slidemo.z < slidemo.height)
			block = 1;
		else if (openbottom - slidemo.z > 24 * FRACUNIT)
			block = 1;
	}
	if (block) {
		if (frac < bestslidefrac) {
			secondslidefrac = bestslidefrac;
			secondslideline = bestslideline;
			bestslidefrac = frac;
			bestslideline = n;
		}
		return 0;
	}
	return 1;
}

# one slide ray: brute-force P_PathTraverse(PT_ADDLINES) +
# PIT_AddLineIntercepts + P_TraverseIntercepts (vanilla p_maputl.c) over
# every line, invoking slidetraverse as each intercept comes up
slidetrace(cx, cy: int)
{
	tdx := slidemo.momx;
	tdy := slidemo.momy;
	# "avoid precision problems with two routines"
	longtrace := tdx > 16 * FRACUNIT || tdy > 16 * FRACUNIT || tdx < -16 * FRACUNIT || tdy < -16 * FRACUNIT;
	for (n := 0; n < len lev.lines; n++) {
		ld := lev.lines[n];
		v1 := lev.vertices[ld.v1];
		v2 := lev.vertices[ld.v2];
		s1: int;
		s2: int;
		if (longtrace) {
			s1 = pointondvlineside(v1.x, v1.y, cx, cy, tdx, tdy);
			s2 = pointondvlineside(v2.x, v2.y, cx, cy, tdx, tdy);
		} else {
			s1 = pointonlineside(cx, cy, n);
			s2 = pointonlineside(cx + tdx, cy + tdy, n);
		}
		if (s1 == s2)
			continue;		# line isn't crossed
		frac := interceptvector(cx, cy, tdx, tdy, v1.x, v1.y, ld.dx, ld.dy);
		if (frac < 0)
			continue;		# behind source
		if (frac > FRACUNIT)
			continue;		# P_TraverseIntercepts maxfrac = FRACUNIT
		if (!slidetraverse(n, frac))
			return;
	}
}

# vanilla P_HitSlideLine (p_map.c): project the remainder move onto the
# wall direction so the next TryMove slides along it
hitslidelined(n: int)
{
	ld := lev.lines[n];
	if (ld.slopetype == map->ST_HORIZONTAL) {
		tmymove = 0;
		return;
	}
	if (ld.slopetype == map->ST_VERTICAL) {
		tmxmove = 0;
		return;
	}
	side := pointonlineside(slidemo.x, slidemo.y, n);
	lineangle := pointtoangle2(0, 0, ld.dx, ld.dy);
	if (side == 1)
		lineangle = lineangle + ANG180;
	moveangle := pointtoangle2(0, 0, tmxmove, tmymove);
	deltaangle := moveangle - lineangle;
	# vanilla tests angle_t (unsigned) deltaangle > ANG180, i.e. as s32
	# negative but not exactly ANG180, then adds ANG180 (wrap)
	if (deltaangle < 0 && deltaangle != ANG180)
		deltaangle = deltaangle + ANG180;
	# u32 >> ANGLETOFINESHIFT then index; & FINEMASK yields the same low
	# 13 bits as a logical shift for any sign
	la := (lineangle >> ANGLETOFINESHIFT) & FINEMASK;
	da := (deltaangle >> ANGLETOFINESHIFT) & FINEMASK;
	movelen := approxdistance(tmxmove, tmymove);
	# vanilla finecosine[k] = finesine[k + 2048]
	newlen := rend->fixedmul(movelen, inf->finesine[da + 2048]);
	tmxmove = rend->fixedmul(newlen, inf->finesine[la + 2048]);
	tmymove = rend->fixedmul(newlen, inf->finesine[la]);
}

# vanilla P_SlideMove (p_map.c): trace the three leading corners, move
# flush to the first blocking line, slide the remainder along it; retry
# at most twice, else stairstep (try each axis alone)
slidemove(mo: ref Mobj)
{
	slidemo = mo;
	hitcount := 0;
	for (;;) {
		hitcount += 1;
		if (hitcount == 3)
			break;			# vanilla goto stairstep

		# trace along the three leading corners
		leadx, trailx, leady, traily: int;
		if (mo.momx > 0) {
			leadx = mo.x + mo.radius;
			trailx = mo.x - mo.radius;
		} else {
			leadx = mo.x - mo.radius;
			trailx = mo.x + mo.radius;
		}
		if (mo.momy > 0) {
			leady = mo.y + mo.radius;
			traily = mo.y - mo.radius;
		} else {
			leady = mo.y - mo.radius;
			traily = mo.y + mo.radius;
		}

		bestslidefrac = FRACUNIT + 1;
		slidetrace(leadx, leady);
		slidetrace(trailx, leady);
		slidetrace(leadx, traily);

		# move up to the wall
		if (bestslidefrac == FRACUNIT + 1)
			break;			# vanilla goto stairstep

		# fudge a bit to make sure it doesn't hit
		bestslidefrac = bestslidefrac - 16r800;
		if (bestslidefrac > 0) {
			newx := rend->fixedmul(mo.momx, bestslidefrac);
			newy := rend->fixedmul(mo.momy, bestslidefrac);
			if (!trymove(mo, mo.x + newx, mo.y + newy))
				break;		# vanilla goto stairstep
		}

		# now continue along the wall; remainder of the move first
		bestslidefrac = FRACUNIT - (bestslidefrac + 16r800);
		if (bestslidefrac > FRACUNIT)
			bestslidefrac = FRACUNIT;
		if (bestslidefrac <= 0)
			return;

		tmxmove = rend->fixedmul(mo.momx, bestslidefrac);
		tmymove = rend->fixedmul(mo.momy, bestslidefrac);
		hitslidelined(bestslideline);
		mo.momx = tmxmove;
		mo.momy = tmymove;
		if (trymove(mo, mo.x + tmxmove, mo.y + tmymove))
			return;
		# vanilla goto retry
	}
	# stairstep: try each axis alone
	if (!trymove(mo, mo.x, mo.y + mo.momy))
		trymove(mo, mo.x + mo.momx, mo.y);
}

# ---------------------------------------------------------------------------
# tic loop
# ---------------------------------------------------------------------------

ticker()
{
	for (i := 0; i < MAXPLAYERS; i++) {
		p := players[i];
		if (p != nil && p.mo != nil)
			playerthink(p);
	}
	runthinkers();
	# P_UpdateSpecials / P_RespawnSpecials: later (milestone 13).
	# Animated textures/flats advance here (vanilla P_UpdateSpecials
	# animate block); full specials come with 13.
	lvltime = lvltime + 1;
	# animated flats/textures advance in doom.b after the tic
	# (rend->animtic needs the shared Renderer adt, which the
	# game sim never holds — module loads are per-instance).
	# vanilla P_UpdateSpecials line-effects subset: scroll-left
	# textureoffset advances 1 texel/tic on side 0 (E1M1 armor
	# pedestal etc.).  Full dispatch is milestone 13.
	for (i = 0; i < nscrolllines; i++) {
		ld := lev.lines[scrolllines[i]];
		if (len ld.sides > 0 && ld.sides[0] != nil)
			ld.sides[0].textureoffset += FRACUNIT;
	}
	# vanilla P_UpdateSpecials button timers (p_spec.c): count down
	# repeatable-switch flip-backs and restore the pre-switch texture
	for (i = 0; i < MAXBUTTONS; i++) {
		b := buttonlist[i];
		if (b.btimer != 0) {
			b.btimer = b.btimer - 1;
			if (b.btimer == 0) {
				sd := lev.lines[b.li].sides[0];
				if (sd != nil) {
					if (b.where == BW_TOP)
						sd.toptexture = b.btexture;
					else if (b.where == BW_MIDDLE)
						sd.midtexture = b.btexture;
					else if (b.where == BW_BOTTOM)
						sd.bottomtexture = b.btexture;
				}
			}
		}
	}
}

runtics(n: int)
{
	for (i := 0; i < n; i++)
		ticker();
}

setcmd(forwardmove, sidemove, angleturn, buttons: int)
{
	if (players[0] == nil)
		fail("setcmd: no player 0");
	players[0].cmd = Ticcmd(forwardmove, sidemove, angleturn, buttons);
}

setview()
{
	p := players[0];
	if (p == nil || p.mo == nil)
		return;
	viewx = p.mo.x;
	viewy = p.mo.y;
	viewz = p.viewz;
	viewangle = p.mo.angle;
	# viewcos = cos(viewangle) = sin(viewangle + ANG90);
	# viewsin = sin(viewangle)
	a := (viewangle >> ANGLETOFINESHIFT) & FINEMASK;
	viewsin = inf->finesine[a];
	viewcos = inf->finesine[(a + 2048) & FINEMASK];
	validcount++;
}

nummobjs(): int
{
	return len mobjs;
}

consoleplayer(): ref Player
{
	return players[0];
}

getleveltime(): int
{
	return lvltime;
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "game: %s\n", s);
	raise "fail:error";
}
