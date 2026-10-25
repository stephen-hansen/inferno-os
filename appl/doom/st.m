# Status bar (milestone 18): st_stuff.c + st_lib.c, single-player
# shareware path.  Reference: doomgeneric st_stuff.c/st_lib.c
# (GPL-2).  Full redraw each frame (no vanilla backing-screen diff
# blits: with the JIT a complete bar redraw is cheaper than tracking
# diffs, and the pixels are identical).
#
# Bar occupies rows 168..199; the world view above it is 320x168
# (R_SetViewSize screenblocks 10: viewheight = 200 - SBARHEIGHT 32).

St: module {

	PATH:	con "/dis/doom/st.dis";

	# load the ST* patches once; g is doom.b's live Game handle
	# (module constants AND initialized tables: pointtoangle2 uses them)
	init:	fn(w: ref Wad->File, g: Game): string;

	# level start / player reborn: reset face + weapon-watch state
	start:	fn(p: ref Game->Player);

	# one game tic: face state machine (vanilla ST_Ticker)
	ticker:	fn(p: ref Game->Player);

	# draw the bar into r.fb8 rows 168..199
	drawer:	fn(r: ref Rend->Renderer, p: ref Game->Player);

	# palette shifts only (ST_doPaletteStuff) when the bar is hidden
	# (full-screen view without the automap)
	palette:	fn(r: ref Rend->Renderer, p: ref Game->Player);
};
