# Screen wipe (milestone 22): f_wipe.c melt.
# Reference: doomgeneric f_wipe.c (GPL-2).
#
# Vanilla wipes in place on a column-major 16-bit copy of the two
# screens; the transform/inverse cancel for the pixels it moves, so
# the same effect is a direct copy of two adjacent pixels per
# half-column (see wipe_doMelt).
implement Wipe;

include "sys.m";
include "wipe.m";

sys: Sys;

w, h:	int;
scr_start, scr_end:	array of byte;
y:	array of int;
rnd:	array of int;
ri:	int;
saved:	int;

init(width, height: int, rt: array of int): string
{
	sys = load Sys Sys->PATH;
	w = width;
	h = height;
	if (w < 2 || w % 2 != 0 || h < 1)
		return "wipe: bad dimensions";
	scr_start = array[w * h] of byte;
	scr_end = array[w * h] of byte;
	y = array[w / 2] of int;
	rnd = rt;
	ri = 0;
	saved = 0;
	return nil;
}

mirnd(): int
{
	if (rnd == nil || len rnd < 256)
		return (ri * 37 + 11) & 255;
	ri = (ri + 1) & 255;
	return rnd[ri] & 255;
}

copy(dst, src: array of byte, n: int)
{
	for (i := 0; i < n; i++)
		dst[i] = src[i];
}

start(fb: array of byte)
{
	if (len fb < w * h)
		return;
	copy(scr_start, fb, w * h);
	saved = 1;
}

begin(fb: array of byte)
{
	if (saved == 0 || len fb < w * h)
		return;
	copy(scr_end, fb, w * h);
	copy(fb, scr_start, w * h);
	# initial column offsets (vanilla wipe_initMelt)
	y[0] = -(mirnd() % 16);
	for (i := 1; i < w / 2; i++) {
		dr := (mirnd() % 3) - 1;
		y[i] = y[i-1] + dr;
		if (y[i] > 0)
			y[i] = 0;
		else if (y[i] == -16)
			y[i] = -15;
	}
}

step(fb: array of byte): int
{
	if (len fb < w * h)
		return 1;
	done := 1;
	hw := w / 2;
	for (i := 0; i < hw; i++) {
		if (y[i] < 0) {
			y[i]++;
			done = 0;
		} else if (y[i] < h) {
			dy := 8;
			if (y[i] < 16)
				dy = y[i] + 1;
			if (y[i] + dy >= h)
				dy = h - y[i];
			# new screen melts in from the top of the column
			for (r2 := 0; r2 < dy; r2++) {
				o := (y[i] + r2) * w + 2*i;
				fb[o] = scr_end[o];
				fb[o+1] = scr_end[o+1];
			}
			yy := y[i] + dy;
			# old screen shows below (vanilla copies the start
			# column from row 0, so it appears to scroll up)
			n := h - yy;
			for (r3 := 0; r3 < n; r3++) {
				d := (yy + r3) * w + 2*i;
				s := r3 * w + 2*i;
				fb[d] = scr_start[s];
				fb[d+1] = scr_start[s+1];
			}
			y[i] = yy;
			done = 0;
		}
	}
	return done;
}
