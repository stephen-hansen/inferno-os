# Episode finale (milestone 22): f_finale.c, shareware path.  E1's
# ending after E1M8: the FLOOR4_8 background with the E1TEXT typed a
# character at a time, then the HELP2 art screen (the cast sequence is
# Doom 2 / commercial only).  Music is milestone 27.
#
# Reference: doomgeneric f_finale.c (GPL-2).

Finale: module {

	PATH:	con "/dis/doom/finale.dis";

	# load the HU font, the FLOOR4_8 flat and the HELP2 art screen
	init:	fn(w: ref Wad->File): string;

	# F_StartFinale: select the (episode, map) ending; only E1M8
	# exists in shareware
	start:	fn(episode, map: int): string;

	# F_Ticker: finalecount, text -> art screen transition
	ticker:	fn();

	# one-shot: the stage just changed (host forces a wipe)
	stagechanged:	fn(): int;

	# F_Drawer: full 320x200 finale frame
	drawer:	fn(r: ref Rend->Renderer);
};
