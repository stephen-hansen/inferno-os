# Intermission screens (single-player shareware E1): stats count-up
# with animated map background, then the entering title.
# Reference: doomgeneric wi_stuff.c (GPL-2), single-player path only
# (no deathmatch/netgame states, no commercial MAP33 branches).
#
# Callers (doom.b): start once per completed level, ticker per tic
# with the live buttons, drawer per frame, then load nextmap when
# done() is true.

Wi: module
{
	PATH:	con "/dis/doom/wi.dis";

	# load shared graphics (WIMAP0, WILV*, WINUM*, WIA*, ...) once;
	# w stays open for the run (lump views are read in place)
	init:	fn(w: ref Wad->File): string;

	# capture the finished level (wbs subset) and reset the count
	# state machine; g supplies the player button latches
	start:	fn(s: ref Game->Wistat, g: Game);

	# advance counts/transitions (vanilla WI_Ticker); buttons is the
	# live ticcmd set (BT_ATTACK/BT_USE accelerate like vanilla)
	ticker:	fn(buttons: int);

	# draw the current state to fb8 (vanilla WI_Drawer)
	drawer:	fn(r: ref Rend->Renderer);

	# 1 once the ShowNextLoc delay has run out (load nextmap next)
	done:	fn(): int;

	# 1-based next map number (valid once done)
	nextmap:	fn(): int;
};
