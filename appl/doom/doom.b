implement Doom;

include "sys.m";
	sys: Sys;
include "draw.m";
include "wad.m";
	wad: Wad;
	File: import wad;

Doom: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

WADPATH:	con "doom1.wad";	# shareware IWAD, expected in cwd or via arg

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	# lumps every complete IWAD must have; checked at open
	checks: list of string =
		"PLAYPAL" ::		# 14 palettes x 768 bytes
		"S_START" ::		# sprites (between S_START and S_END)
		"S_END" ::
		"F_START" ::		# flats: 64x64 floor/ceiling textures
		"F_END" ::
		"E1M1" ::		# shareware episode 1 map 1 (marker lump)
		"DEMO1" ::		# built-in demo playback
		nil;

	args = tl args;
	dump := 0;
	if (args != nil && hd args == "-d") {
		dump = 1;
		args = tl args;
	}
	path := WADPATH;
	if (args != nil) {
		path = hd args;
		args = tl args;
	}
	if (args != nil)
		usage();

	wad = load Wad Wad->PATH;
	if (wad == nil)		# not installed yet: look next to this .dis
		wad = load Wad "wad.dis";
	if (wad == nil)
		fail(sys->sprint("can't load Wad module: %r"));

	(w, err) := wad->open(path);
	if (w == nil)
		fail(err);
	sys->print("%s: %s, %d lumps, directory at %d\n",
		path, w.wtype, w.numlumps, w.infotableofs);

	for (l := checks; l != nil; l = tl l) {
		name := hd l;
		j := w.find(name);
		if (j < 0)
			sys->print("missing lump: %s\n", name);
		else
			sys->print("  %-8s lump %5d, %8d bytes\n",
				name, j, w.lumps[j].size);
	}

	if (dump)
		for (j := 0; j < w.numlumps; j++)
			sys->print("%5d %8d  %s\n", j, w.lumps[j].size, w.lumps[j].name);

	# exercise read on a small and a medium lump
	checkread(w, "PLAYPAL", 768*14);
	checkread(w, "E1M1", -1);
	w.close();
}

checkread(w: ref Wad->File, name: string, expect: int)
{
	i := w.find(name);
	if (i < 0)
		return;
	(b, err) := w.read(i);
	if (b == nil)
		fail(err);
	if (expect >= 0 && len b != expect)
		sys->print("%s: unexpected size %d (want %d)\n", name, len b, expect);
	else if (name == "PLAYPAL")
		sys->print("%s: read ok, %d bytes, first palette RGB %d,%d,%d\n",
			name, len b, int b[0], int b[1], int b[2]);
	else
		sys->print("%s: read ok, %d bytes\n", name, len b);
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: doom [-d] [doom.wad]\n");
	raise "fail:usage";
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "doom: %s\n", s);
	raise "fail:error";
}
