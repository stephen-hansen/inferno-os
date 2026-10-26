# Demo playback (milestone 23): demo lump parser.
# Reference: doomgeneric g_game.c G_DoPlayDemo/G_ReadDemoTiccmd
# (GPL-2).

implement Demo;

include "sys.m";
include "wad.m";
	File: import wad;
include "demo.m";

sys: Sys;
wad: Wad;
f: ref File;

data:	array of byte;
pos:	int;
finished:	int;
dskill, depisode, dmap: int;

DEMOMARKER:	con 16r80;
VERSION:	con 109;

init(w: ref Wad->File): string
{
	sys = load Sys Sys->PATH;
	wad = load Wad Wad->PATH;
	if (wad == nil)
		return "can't load Wad module";
	f = w;
	data = nil;
	pos = 0;
	finished = 1;
	dskill = depisode = dmap = 0;
	return nil;
}

upper(s: string): string
{
	r := "";
	for (i := 0; i < len s; i++) {
		c := int s[i];
		if (c >= 'a' && c <= 'z')
			c -= 'a' - 'A';
		r[len r] = c;
	}
	return r;
}

open(name: string): string
{
	if (f == nil)
		return "demo: no WAD";
	i := f.find(upper(name));
	if (i < 0)
		return "demo: lump not found: " + name;
	(b, err) := f.read(i);
	if (b == nil)
		return "demo: " + err;
	if (len b < 15)
		return "demo: short lump";
	if (int b[0] != VERSION)
		return sys->sprint("demo: version %d (want %d)",
			int b[0], VERSION);
	# single player only (shareware demos): players 2..4 must be out
	for (j := 1; j < 4; j++)
		if (int b[9+j] != 0)
			return "demo: net demos are not supported";
	dskill = int b[1];
	depisode = int b[2];
	dmap = int b[3];
	data = b;
	pos = 13;
	finished = 0;
	return nil;
}

skill(): int
{
	return dskill;
}

episode(): int
{
	return depisode;
}

map(): int
{
	return dmap;
}

done(): int
{
	return finished;
}

next(): (int, int, int, int)
{
	if (finished != 0 || data == nil)
		return (0, 0, 0, 0);
	if (pos >= len data || int data[pos] == DEMOMARKER) {
		finished = 1;
		return (0, 0, 0, 0);
	}
	if (pos + 4 > len data) {
		finished = 1;
		return (0, 0, 0, 0);
	}
	fwd := int data[pos];
	if (fwd >= 128)
		fwd -= 256;
	side := int data[pos+1];
	if (side >= 128)
		side -= 256;
	turn := int data[pos+2] << 8;	# low byte dropped (vanilla)
	if (turn >= 32768)
		turn -= 65536;
	buttons := int data[pos+3];
	pos += 4;
	return (fwd, side, turn, buttons);
}
