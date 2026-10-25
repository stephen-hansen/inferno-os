# Screen wipe (milestone 22): f_wipe.c melt, the only wipe Doom uses
# (wipe_ScreenWipe(wipe_Melt,...)).  The host captures the current
# screen with start(), hands over the freshly drawn new screen with
# begin(), then calls step() once per tic and presents the result
# until step() returns 1.
#
# Reference: doomgeneric f_wipe.c (GPL-2).

Wipe: module {

	PATH:	con "/dis/doom/wipe.dis";

	# width/height are the full 320x200 frame; rnd is the 256-entry
	# M_Random table (m_random.c) used for the initial column offsets
	init:	fn(width, height: int, rnd: array of int): string;

	# capture the currently displayed screen as the melt start
	start:	fn(fb: array of byte);

	# the frame buffer now holds the new screen: save it as the melt
	# end, restore the start screen into it, and initialise columns
	begin:	fn(fb: array of byte);

	# advance the melt by one tic, updating fb; returns 1 when done
	step:	fn(fb: array of byte): int;
};
