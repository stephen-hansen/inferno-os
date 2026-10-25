# HUD messages (milestone 19): hu_stuff.c + hu_lib.c, single-player
# path (no chat/netgame).  Messages are one line at the top of the
# screen, each replacing the previous, timed out after 4*TICRATE
# like vanilla (HU_MSGHEIGHT 1, HU_MSGTIMEOUT).  The level title
# widget is built at level start but only drawn while the automap is
# active (vanilla HU_Drawer guard); the automap arrives in M20.
# Reference: doomgeneric hu_stuff.c/hu_lib.c (GPL-2).

Hu: module {

	PATH:	con "/dis/doom/hu.dis";

	# load the HUD font (STCFN033..STCFN095) once
	init:	fn(w: ref Wad->File): string;

	# level start: build the title string from the map lump name
	start:	fn(mapname: string);

	# one tic: message queue (vanilla HU_Ticker subset)
	ticker:	fn(p: ref Game->Player);

	# draw messages (always) and the title (automap only)
	drawer:	fn(r: ref Rend->Renderer);

	# M20: the title line shows while the automap is up
	setautomap:	fn(on: int);

	# M21: menu Messages option gates showMessages (vanilla HU_Ticker);
	# forcemsg marks the next message as one-shot "dontfuckwithme"
	setmessages:	fn(on: int);
	forcemsg:	fn();
};
