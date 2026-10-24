# First-person world view renderer: walks the BSP tree front-to-
# back from the camera, projects segs into screen columns, draws
# textured walls with vanilla R_DrawColumn, fills floor/ceiling
# planes with vanilla R_DrawSpan, then projects thing sprites and
# masked two-sided midtextures through the drawseg clip pool.
# Occlusion uses the classic solid[] array (top/bottom clip per
# screen column) for walls; sprites clip against drawseg snapshots.
#
# Reference: doomgeneric r_bsp.c r_segs.c r_plane.c r_main.c
# r_things.c (GPL-2).

View: module {

	PATH:	con "/dis/doom/view.dis";

	# allocate solid[] clip arrays for width w; call once after
	# Renderer.init.  wf is the open WAD (sprite lumps); g is the
	# loaded Game module (sprite rotations use its pointtoangle2);
	# w,h are the render resolution.
	init:	fn(w: ref Rend->Renderer, l: ref Map->Level,
				wf: ref Wad->File, g: Game,
				width, height: int): string;

	# swap the rendered map (level transitions reload geometry;
	# clip tables are sized by w/h so only the level changes)
	setlevel:	fn(l: ref Map->Level);

	# render one frame from the given camera state (all 16.16
	# fixed point; viewangle is BAM).  Clears fb8, walks BSP,
	# draws walls, then projects mobs (game mobjs) as sprites and
	# flushes masked midtextures.  Caller does convert() + present().
	render:	fn(viewx, viewy, viewz, viewangle, viewcos, viewsin: int,
				mobs: array of ref Game->Mobj);

	# debug stats from the last render
	nsegs, ncolumns, nspans:	int;
	nsprites, ndrawsegs:	int;
	nmasked:			int;	# masked mid segs flushed last frame
	dbgprints:			int;	# TEMP: 1 enables sprite diagnostics
	ringenable:			int;	# 1 = capture F2 review ring
	setperf:			fn(v: int);	# 1 = per-phase render timing (stdout)
						# (per-frame fb+clip copy; off = real
						# play pays nothing, F1 snapshot still
						# works — it reads the live frame)

	# user-triggered frame snapshot (F1): dump camera, mobjs,
	# vissprites, drawsegs, clip arrays and fb8 to path for
	# offline replay.  tic is recorded in the log header.
	snapshot:	fn(path: string, tic: int): string;

	# frame-history ring (F2 review): the last ~35 rendered frames
	# are retained; step through them frozen and snapshot any one.
	# Indices are logical (0 = oldest).  tic is dbgframes at capture.
	ringlen:	fn(): int;
	ringtic:	fn(i: int): int;
	ringrestore:	fn(i: int): string;	# copy ring fb to renderer fb8
	ringsnap:	fn(path: string, htic: int, i: int): string;
};
