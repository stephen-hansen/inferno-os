implement Doom;

include "sys.m";
	sys: Sys;
include "draw.m";
include "tk.m";
include "wad.m";
	wad: Wad;
	File: import wad;
include "video.m";
	video: Video;
	Context: import video;

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
	test := 0;
	for (;;) {
		if (args == nil || (hd args != "-d" && hd args != "-t"))
			break;
		if (hd args == "-d")
			dump = 1;
		else
			test = 1;
		args = tl args;
	}
	path := WADPATH;
	if (args != nil) {
		path = hd args;
		args = tl args;
	}
	if (args != nil)
		usage();

	if (test) {
		videotest();
		return;
	}

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

vid_w := 320;
vid_h := 200;
vid_ms := 5000;

videotest()
{
	video = load Video Video->PATH;
	if (video == nil)
		video = load Video "video.dis";
	if (video == nil)
		fail(sys->sprint("can't load Video module: %r"));

	(v, err) := video->open(vid_w, vid_h);
	if (v == nil)
		fail(err);

	w := v.width;
	h := v.height;
	fb := v.fb;
	pitch := w * 3;

	sys->print("videotest: %dx%d RGB24, running %d ms...\n", w, h, vid_ms);

	start := sys->millisec();
	frames := 0;
	elapsed := 0;
	for (;;) {
		elapsed = sys->millisec() - start;
		if (elapsed >= vid_ms)
			break;

		# animated xor-plasma test pattern (BGR byte order)
		t := elapsed / 40;
		for (y := 0; y < h; y++) {
			off := y * pitch;
			for (x := 0; x < w; x++) {
				vb := (x ^ y) + t;
				fb[off] = byte vb;
				fb[off+1] = byte (vb * 2);
				fb[off+2] = byte (vb * 3);
				off += 3;
			}
		}

		v.present();
		frames++;
	}

	if (elapsed <= 0)
		elapsed = 1;
	sys->print("videotest: %d frames in %d ms = %d fps\n",
		frames, elapsed, frames * 1000 / elapsed);
	v.close();
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: doom [-d] [-t] [doom.wad]\n");
	raise "fail:usage";
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "doom: %s\n", s);
	raise "fail:error";
}
