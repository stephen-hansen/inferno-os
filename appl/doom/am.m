# Automap (milestone 20): am_map.c, single-player path.  Vanilla
# draws the map itself with clipped Bresenham lines straight into the
# 320x168 view area (f_w/f_h of the full-screen frame buffer); the
# status bar and HUD messages keep drawing on top.  M20 covers
# geometry, follow/pan/zoom/grid/marks, explored-line tracking and the
# all-map power; the iddt cheat is exposed for M25 to drive.
# Reference: doomgeneric am_map.c (GPL-2).

Am: module {

	PATH:	con "/dis/doom/am.dis";

	# load AMMNUM0..9 mark patches; g is doom.b's live Game handle
	init:	fn(w: ref Wad->File, g: Game): string;

	# level load: AM_LevelInit (bounds, initial scale, clear marks)
	setlevel:	fn(l: ref Map->Level);

	# TAB in/out (AM_Start / AM_Stop)
	start:	fn();
	stop:	fn();
	active:	fn(): int;
	following:	fn(): int;

	# one tic (vanilla order: P_Ticker, ST_Ticker, AM_Ticker, HU_Ticker)
	ticker:	fn();

	# draw the map in place of the world (fb8 rows 0..167)
	drawer:	fn(r: ref Rend->Renderer);

	# keyboard: our port delivers edge events.  k uses the doom.b
	# encoding: ASCII for characters, KUp/... for arrows.  Returns 1
	# when the automap consumed it (vanilla AM_Responder rc).
	keydown:	fn(k: int): int;
	keyup:	fn(k: int): int;

	# M25 iddt hook: cycle all-lines (1) / all-lines+things (2)
	cheatcycle:	fn();

	# arrow key codes, same encoding as doom.b's keyboard constants
	# (module/keyboard.m: View = Spec|16r10, Up = View|2)
	KU:	con 16rE012;
	KD:	con 16rE013;
	KL:	con 16rE014;
	KR:	con 16rE015;
	Tab:	con 9;
};
