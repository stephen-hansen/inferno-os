# Episode finale (milestone 22): f_finale.c, shareware path.
# Reference: doomgeneric f_finale.c (GPL-2).

implement Finale;

include "sys.m";
include "wad.m";
	File: import wad;
include "rend.m";
	Renderer: import rend;
include "finale.m";

sys: Sys;
wad: Wad;
rend: Rend;

Patch: adt {
	d: array of byte;
};

FONTSTART:	con '!';
FONTSIZE:	con 63;
TEXTSPEED:	con 3;
TEXTWAIT:	con 250;
SCREENWIDTH:	con 320;
SCREENHEIGHT:	con 200;
F_STAGE_TEXT:	con 0;
F_STAGE_ART:	con 1;

font:	array of Patch;
flat:	array of byte;		# FLOOR4_8 64x64
art:	array of byte;		# HELP2 (E1 shareware art screen)
text:	string;
finalecount:	int;
stage:	int;
changed:	int;

# vanilla E1TEXT (d_englsh.h)
E1TEXT: con "Once you beat the big badasses and\n"+
"clean out the moon base you're supposed\n"+
"to win, aren't you? Aren't you? Where's\n"+
"your fat reward and ticket home? What\n"+
"the hell is this? It's not supposed to\n"+
"end this way!\n"+
"\n"+
"It stinks like rotten meat, but looks\n"+
"like the lost Deimos base.  Looks like\n"+
"you're stuck on The Shores of Hell.\n"+
"The only way out is through.\n"+
"\n"+
"To continue the DOOM experience, play\n"+
"The Shores of Hell and its amazing\n"+
"sequel, Inferno!\n";

getpatch(w: ref Wad->File, name: string): array of byte
{
	i := w.find(name);
	if (i < 0)
		return nil;
	(b, err) := w.read(i);
	if (b == nil)
		return nil;
	return b;
}

init(w: ref Wad->File): string
{
	sys = load Sys Sys->PATH;
	wad = load Wad Wad->PATH;
	if (wad == nil)
		return "can't load Wad module";
	rend = load Rend Rend->PATH;
	if (rend == nil)
		rend = load Rend "rend.dis";
	if (rend == nil)
		return "can't load Rend module";
	font = array[FONTSIZE] of Patch;
	for (i := 0; i < FONTSIZE; i++) {
		font[i].d = getpatch(w, sys->sprint("STCFN%.3d",
			int FONTSTART + i));
		if (font[i].d == nil)
			return "missing finale font patch";
	}
	flat = getpatch(w, "FLOOR4_8");
	if (flat == nil || len flat != 4096)
		return "missing finale flat FLOOR4_8";
	art = getpatch(w, "HELP2");
	if (art == nil)
		return "missing finale art HELP2";
	text = "";
	finalecount = 0;
	stage = F_STAGE_TEXT;
	changed = 0;
	return nil;
}

start(episode, map: int): string
{
	if (episode != 1 || map != 8)
		return sys->sprint("finale: no ending for E%dM%d",
			episode, map);
	text = E1TEXT;
	finalecount = 0;
	stage = F_STAGE_TEXT;
	changed = 0;
	return nil;
}

ticker()
{
	finalecount++;
	if (stage == F_STAGE_TEXT &&
	    finalecount > len text * TEXTSPEED + TEXTWAIT) {
		finalecount = 0;
		stage = F_STAGE_ART;
		changed = 1;
	}
}

stagechanged(): int
{
	c := changed;
	changed = 0;
	return c;
}

upper(c: int): int
{
	if (c >= 'a' && c <= 'z')
		return c - ('a' - 'A');
	return c;
}

drawer(r: ref Renderer)
{
	if (stage == F_STAGE_ART) {
		rend->rdrawpatch(r, 0, 0, art);
		return;
	}
	# erase to the tiled background (F_TextWrite)
	fb := r.fb8;
	for (y := 0; y < SCREENHEIGHT; y++) {
		row := (y & 63) * 64;
		for (x := 0; x < SCREENWIDTH; x += 64)
			for (k := 0; k < 64; k++)
				fb[y*SCREENWIDTH + x + k] = flat[row + k];
	}
	# typewriter text: 'count' characters shown, newline resets x
	count := (finalecount - 10) / TEXTSPEED;
	if (count < 0)
		count = 0;
	cx := 10;
	cy := 10;
	idx := 0;
	while (count > 0 && idx < len text) {
		c := int text[idx];
		idx++;
		count--;
		if (c == '\n') {
			cx = 10;
			cy += 11;
			continue;
		}
		ch := upper(c) - int FONTSTART;
		if (ch < 0 || ch >= FONTSIZE) {
			cx += 4;
			continue;
		}
		pd := font[ch].d;
		w := rend->rpatchwidth(pd);
		if (cx + w > SCREENWIDTH)
			break;
		rend->rdrawpatch(r, cx, cy, pd);
		cx += w;
	}
}
