# Play simulation: mobj thinkers, player movement, collision
# clipping, and the 35Hz tic loop.  Brute-force line/thing checks
# replace the blockmap (475 lines on E1M1 is cheap at 35Hz);
# P_SlideMove is ported (flush-to-wall + along-wall redirect over
# brute-force intercepts).  Item pickup, weapons/psprites, line
# specials and AI actions are left for later milestones; action
# routines from the state table are dispatched as no-op stubs.
#
# Reference: doomgeneric p_mobj.c p_map.c p_maputl.c p_user.c
# p_tick.c g_game.c (GPL-2).

Game: module {

	PATH:	con "/dis/doom/game.dis";

		# timing / fixed point
	TICRATE:	con 35;	FRACUNIT:	con 16r10000;
	FRACBITS:	con 16;
	ANGLETOFINESHIFT:	con 19;
	FINEANGLES:	con 8192;
	FINEMASK:	con 8191;

	# BAM angles (high bit set values stay int via ~INT_MAX form)
	ANG45:	con 16r20000000;
	ANG90:	con 16r40000000;
	ANG180:	con ~2147483647;	# 16r80000000
	ANG270:	con ~1073741823;	# 16rc0000000

	# movement (p_local.h / p_mobj.c)
	FRICTION:	con 16re800;
	STOPSPEED:	con 16r1000;
	GRAVITY:	con FRACUNIT;
	MAXMOVE:	con 30*FRACUNIT;
	SKULLSPEED:	con 20 * FRACUNIT;	# lost-soul charge speed
	FLOATSPEED:	con 4*FRACUNIT;
	VIEWHEIGHT:	con 41*FRACUNIT;
	MAXBOB:	con 16r100000;
	ONFLOORZ:	con ~2147483647;	# INT_MIN
	ONCEILINGZ:	con 2147483647;		# INT_MAX
	MAXPLAYERS:	con 4;

	# skill (doomdef.h gameskill_t): thing spawn bit is 1<<(skill-1)
	SK_BABY, SK_EASY, SK_MEDIUM, SK_HARD, SK_NIGHTMARE: con iota;

	# player states (d_player.h)
	PST_LIVE, PST_DEAD, PST_REBORN: con iota;

	# gameaction (g_game.h subset: only what single-player E1 uses)
	GA_NOTHING, GA_COMPLETED, GA_VICTORY: con iota;

	# cheats
	CF_NOCLIP:	con 1;
	CF_GODMODE:	con 2;
	CF_NOMOMENTUM:	con 4;

	# buttons (d_event.h)
	BT_ATTACK:	con 1;
	BT_USE:	con 2;
	BT_CHANGE:	con 4;
	BT_WEAPONMASK:	con 8+16+32;
	BT_WEAPONSHIFT:	con 3;
	BT_SPECIAL:	con 128;

	# map thing options (doomdef.h MTF_*)
	MTF_EASY:	con 1;
	MTF_NORMAL:	con 2;
	MTF_HARD:	con 4;
	MTF_AMBUSH:	con 8;
	MTF_NOTSINGLE:	con 16;

	# linedef flags (doomdata.h ML_*)
	ML_BLOCKING:	con 1;
	ML_BLOCKMONSTERS:	con 2;
	ML_TWOSIDED:	con 4;
	ML_SECRET:	con 32;	# monsters never open secret doors
	ML_SOUNDBLOCK:	con 64;	# sound does not cross (p_sight.c)

	# weapon/ammo (doomdef.h); minimal for G_PlayerReborn
	WP_FIST, WP_PISTOL, WP_SHOTGUN, WP_CHAINGUN, WP_MISSILE,
	WP_PLASMA, WP_BFG, WP_CHAINSAW, WP_SUPERSHOTGUN: con iota;
	NUMWEAPONS:	con 9;
	WP_NOCHANGE:	con 9;	# no pending weapon (vanilla wp_nochange)
	AM_CLIP, AM_SHELL, AM_CELL, AM_MISL: con iota;
	AM_NOAMMO:	con 4;
	NUMAMMO:	con 4;

	# keycards/skulls (d_items.h card_t order)
	IT_BLUECARD, IT_YELLOWCARD, IT_REDCARD,
	IT_BLUESKULL, IT_YELLOWSKULL, IT_REDSKULL: con iota;
	NUMCARDS:	con 6;

	# player powers (d_player.h power_type_t order)
	PW_INVULNERABILITY, PW_STRENGTH, PW_INVISIBILITY,
	PW_IRONFEET, PW_ALLMAP, PW_INFRARED: con iota;
	NUMPOWERS:	con 6;

	# interaction (p_inter.c / p_local.h)
	MAXHEALTH:	con 100;
	BONUSADD:	con 6;
	BASETHRESHOLD:	con 100;
	INVULNTICS:	con 30*TICRATE;
	INVISTICS:	con 60*TICRATE;
	INFRATICS:	con 120*TICRATE;
	IRONTICS:	con 60*TICRATE;

	# vertical door types (p_spec.h vldoor_e order)
	VLD_NORMAL, VLD_CLOSE30THENOPEN, VLD_CLOSE, VLD_OPEN,
	VLD_RAISEIN5MINS, VLD_BLAZERAISE, VLD_BLAZEOPEN,
	VLD_BLAZECLOSE: con iota;

	# floor mover types (p_spec.h floor_e positions)
	FL_LOWERFLOOR, FL_LOWERFLOORTOWELOWEST, FL_TURBOLOWER: con iota;
	FL_RAISEFLOOR:	con 3;
	FL_RAISEFLOORTONEAREST:	con 4;
	FL_DONUTRAISE:	con 11;

	# switch-button positions (p_spec.h bwhere_e order) and timing
	BW_TOP, BW_MIDDLE, BW_BOTTOM: con iota;
	BUTTONTIME:	con 35;
	MAXBUTTONS:	con 16;

	# plat types (p_spec.h plattype_e positions)
	PL_PERPETUALRAISE:	con 0;
	PL_DOWNWAITUPSTAY:	con 1;
	PL_RAISEANDCHANGE:	con 2;
	PL_RAISETONEARESTANDCHANGE:	con 3;

	# plat status (p_spec.h plat_e order)
	PLS_UP, PLS_DOWN, PLS_WAITING, PLS_STASIS: con iota;

	# ceiling mover types (p_spec.h ceiling_e order)
	CEIL_LOWERTOFLOOR, CEIL_RAISETOHIGHEST, CEIL_LOWERANDCRUSH,
	CEIL_CRUSHANDRAISE, CEIL_FASTCRUSHANDRAISE,
	CEIL_SILENTCRUSHANDRAISE: con iota;

	# ceiling speed (p_spec.h)
	CEILSPEED:	con FRACUNIT;

	# light thinker types (p_lights.c families)
	LT_FIRE, LT_FLASH, LT_STROBE, LT_GLOW: con iota;

	# light timing (p_spec.h)
	GLOWSPEED:	con 8;
	STROBEBRIGHT:	con 5;
	FASTDARK:	con 15;
	SLOWDARK:	con 35;

	# per-tic player command (d_ticcmd.h)
	Ticcmd: adt {
		forwardmove, sidemove:	int;	# signed char, *2048 for thrust
		angleturn:	int;		# <<16 for BAM delta
		buttons:	int;
	};

	# psprite slots (p_pspr.h psprnum_t)
	PS_WEAPON, PS_FLASH: con iota;
	NUMPSPRITES:	con 2;

	# chase directions (p_enemy.c dirtype_t + LUTs, verbatim order:
	# east, northeast, north, northwest, west, southwest, south,
	# southeast, no direction)
	DI_EAST, DI_NORTHEAST, DI_NORTH, DI_NORTHWEST,
	DI_WEST, DI_SOUTHWEST, DI_SOUTH, DI_SOUTHEAST,
	DI_NODIR, NUMDIRS: con iota;

	# overlay psprite (p_pspr.h pspdef_t): state is an S_ index,
	# S_NULL when inactive
	Psp: adt {
		state, tics:	int;
		sx, sy:	int;		# 16.16 screen offset
	};

	# moving object (p_mobj.h mobj_t).  state/sprite/frame are
	# table indices; typ not type (Limbo keyword).  info is a
	# copy of the (immutable) mobjinfo row.  No sector/block
	# list links: collision brute-forces the mobj array.
	Mobj: adt {
		typ:	int;		# MT_*
		info:	MobjInfo;
		x, y, z, angle:	int;	# 16.16 / BAM
		momx, momy, momz:	int;
		radius, height:	int;
		flags:	int;
		health:	int;
		state:	int;		# S_ index; S_NULL once removed
		sprite, frame:	int;
		tics:	int;		# -1 = never advances
		reactiontime:	int;
		lastlook:	int;
		spawnpoint:	Map->Thing;
		subsector:	ref Map->Subsector;
		floorz, ceilingz:	int;
		player:	ref Player;	# nil unless a player
		target:	ref Mobj;	# AI later
		removed:	int;		# lazy thinker removal
		movecount, movedir, threshold:	int;	# AI later
	};

	Player: adt {
		mo:	ref Mobj;
		cmd:	Ticcmd;
		playerstate:	int;
		viewz, viewheight, deltaviewheight, bob:	int;
		health:	int;
		cheats:	int;
		attackdown, usedown:	int;
		killcount, itemcount, secretcount:	int;
		readyweapon, pendingweapon:	int;
		weaponowned:	array of int;	# [NUMWEAPONS]
		ammo, maxammo:	array of int;	# [NUMAMMO]
		frags:	array of int;		# [MAXPLAYERS]
		cards:	array of int;		# [NUMCARDS] keycards/skulls
		armorpoints, armortype:	int;
		powers:	array of int;		# [NUMPOWERS]
		backpack:	int;
		bonuscount, damagecount:	int;	# HUD flashes (M15/18)
		message:	string;		# pending HUD message (M19, hu_stuff)
		attacker:	ref Mobj;	# last damager (M12 retaliation)
		psp:	array of ref Psp;	# [NUMPSPRITES] weapon + flash
		extralight:	int;	# muzzle-flash light boost (A_Light*)
		refire:	int;		# held-trigger refire count
	};

 	# --- world state (one level; set by setuplevel) ---
 	lev:	ref Map->Level;		# current map geometry
 	mobjs:	array of ref Mobj;	# thinker list
 	players:	array of ref Player;
 	lvltime:	int;			# leveltime
 	prndindex:	int;			# P_Random index
 	gameskill:	int;
 	gamemapnum:	int;		# ExMy map number (teleport boss rule)
 	totalkills, totalitems:	int;
 	totalsecret:	int;		# secret sectors (P_SpawnSpecials 9)
 	action:	int;			# gameaction (GA_* subset)
 	secretseen:	int;		# exited map 9 (splat on node 8)
 	scrolllines:	array of int;	# scroll-left linedefs (special 48)
 	nscrolllines:	int;

	# intermission snapshot (vanilla wbstartstruct_t subset,
	# single player): filled by docompleted, consumed by WI
	Wistat: adt {
		last, next:	int;	# 0-based map indices
		epsd:	int;		# 0-based episode (shareware: always 0)
		maxkills, maxitems, maxsecret:	int;
		kills, items, secrets:	int;
		stime, partime:	int;	# tics
		didsecret:	int;
	};

	# --- view state (updated each frame by the renderer caller) ---
	viewx, viewy, viewz:	int;	# 16.16 camera position
	viewangle:	int;		# BAM
	viewcos, viewsin:	int;	# 16.16, derived from viewangle
	validcount:	int;		# wall mark counter
	centerx, centery:	int;	# screen center, set by renderer
	projection:	int;	# 16.16 focal length (= centerx for 90deg)
	solid:	array of int;	# occlusion: top/bottom clip per column [w*2]

	# build Info tables and reset world state; call once at startup.
	# snd is doom.b's shared SFX instance (single mixer/output).
	init:	fn(snd: Sound): string;

	# load geometry into the world: spawn things matching skill's
	# MTF_ bit (netgame off) and the player 1 start
	setuplevel:	fn(l: ref Map->Level, skill: int): string;

	# run n game tics at the caller's pace (no wall-clock sleep)
	runtics:	fn(n: int);

	# one tic
	ticker:	fn();

	# set the console player's ticcmd (signed char / short ranges)
	setcmd:	fn(forwardmove, sidemove, angleturn, buttons: int);

	# copy console player's mobj pos/angle into viewx/viewy/viewz/
	# viewangle and recompute viewcos/viewsin; call once per frame
	# before rendering
	setview:	fn();

	# level-exit flag (G_ExitLevel): set by the exit switch (S1
	# special 11); consumed by docompleted (16)
	levexit:	fn(): int;

	# secret-exit flag (G_SecretExitLevel, S1 special 51)
	secretexit:	fn(): int;

	# gameaction machine (g_game.h subset)
	gameaction:	fn(): int;
	setaction:	fn(a: int);

	# G_DoCompleted: finish the player (strip cards/powers),
	# fill the intermission snapshot; returns the next 1-based map
	# number, or -1 for the E1M8 victory (finale lands in 22)
	docompleted:	fn(): int;

	# intermission snapshot filled by docompleted
	getwistat:	fn(): ref Wistat;

	# clear the map-9 exit mark (vanilla clears didsecret in the
	# G_PlayerReborn memset; called on the death-reload path)
	setsecretseen:	fn(v: int);

	# introspection for tests
	nummobjs:	fn(): int;
	consoleplayer:	fn(): ref Player;
	getleveltime:	fn(): int;
	prandom:	fn(): int;

	# vanilla R_PointToAngle relative to (x1,y1) in BAM; used by the
	# renderer to pick sprite rotations
	pointtoangle2:	fn(x1, y1, x2, y2: int): int;

};
