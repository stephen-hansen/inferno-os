# Demo playback (milestone 23): d_main.c / g_game.c demo lump format.
# A demo lump starts with a 13-byte header (version 109, skill,
# episode, map, deathmatch, respawn, fast, nomonsters, consoleplayer,
# playeringame[4]) followed by 4-byte ticcmds (forwardmove, sidemove,
# angleturn high byte, buttons) and ends with a 0x80 marker.
#
# Reference: doomgeneric g_game.c G_DoPlayDemo/G_ReadDemoTiccmd
# (GPL-2).

Demo: module {

	PATH:	con "/dis/doom/demo.dis";

	# load the WAD (lump lookups)
	init:	fn(w: ref Wad->File): string;

	# read and validate a demo lump; returns nil or an error
	open:	fn(name: string): string;

	# header fields (valid after load)
	skill:	fn(): int;
	episode:	fn(): int;
	map:	fn(): int;

	# next ticcmd: (forwardmove, sidemove, angleturn, buttons).
	# At the end marker the values are 0 and done() becomes 1.
	next:	fn(): (int, int, int, int);
	done:	fn(): int;
};
