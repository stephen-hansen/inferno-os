implement Doom;

include "sys.m";
	sys: Sys;
include "draw.m";
include "wad.m";
	wad: Wad;
	File: import wad;
include "video.m";
	video: Video;
	Context: import video;
include "rend.m";
	rend: Rend;
	Renderer: import rend;

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
	rt := 0;
	for (;;) {
		if (args == nil ||
		    (hd args != "-d" && hd args != "-t" && hd args != "-r"))
			break;
		if (hd args == "-d")
			dump = 1;
		else if (hd args == "-t")
			test = 1;
		else
			rt = 1;
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

	if (rt) {
		rendertest(path);
		return;
	}

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
	sys->print("videotest: screen image rect %d,%d - %d,%d\n",
		v.display.image.r.min.x, v.display.image.r.min.y,
		v.display.image.r.max.x, v.display.image.r.max.y);

	w := v.width;
	h := v.height;
	fb := v.fb;
	pitch := w * 4;

	sys->print("videotest: %dx%d XRGB32, running %d ms...\n", w, h, vid_ms);

	start := sys->millisec();
	frames := 0;
	elapsed := 0;
	for (;;) {
		elapsed = sys->millisec() - start;
		if (elapsed >= vid_ms)
			break;

		# animated xor-plasma test pattern (BGRX byte order)
		t := elapsed / 40;
		for (y := 0; y < h; y++) {
			off := y * pitch;
			for (x := 0; x < w; x++) {
				vb := (x ^ y) + t;
				fb[off] = byte vb;
				fb[off+1] = byte (vb * 2);
				fb[off+2] = byte (vb * 3);
				fb[off+3] = byte 0;
				off += 4;
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

rendertest(path: string)
{
	rend = load Rend Rend->PATH;
	if (rend == nil)
		rend = load Rend "rend.dis";
	if (rend == nil)
		fail(sys->sprint("can't load Rend module: %r"));
	video = load Video Video->PATH;
	if (video == nil)
		video = load Video "video.dis";
	if (video == nil)
		fail(sys->sprint("can't load Video module: %r"));

	(w, err) := wad->open(path);
	if (w == nil)
		fail(err);

	r := ref Renderer;
	err = r.init(w, vid_w, vid_h);
	if (err != nil)
		fail(err);

	sys->print("rendertest: %d flats, %d textures\n",
		len r.flats, len r.textures);
	sys->print("  PLAYPAL[0] RGB %d,%d,%d  COLORMAP %d bytes\n",
		int r.palr[0], int r.palg[0], int r.palb[0], len r.colormap);
	idn := 0;
	for (i := 0; i < 256; i++)
		if (r.colormap[i] == byte i)
			idn++;
	# vanilla row 0 is identity except 7 remapped colors
	sys->print("  colormap light0: %d/256 identity\n", idn);
	fmok := "yes";
	if (rend->fixedmul(1<<16, 1<<16) != 1<<16 ||
	    rend->fixedmul(2<<16, 3<<16) != 6<<16 ||
	    rend->fixedmul(-(1<<16), 2<<16) != -(2<<16) ||
	    rend->fixedmul(65535, 65535) != 65534 ||
	    rend->fixedmul(16r12345678, 16r10000) != 16r12345678)
		fmok = "no";
	sys->print("  fixedmul self-test: %s\n", fmok);

	tex := r.texture("STARTAN3");
	if (tex == nil)
		fail("texture STARTAN3 not found");
	fl := r.flat("FLOOR4_8");
	if (fl == nil)
		fail("flat FLOOR4_8 not found");
	sys->print("  %s %dx%d, %s 64x64\n",
		tex.name, tex.width, tex.height, fl.name);

	(v, verr) := video->open(vid_w, vid_h);
	if (v == nil)
		fail(verr);

	wallh := vid_h / 2;
	iscale := (tex.height << 16) / wallh;
	texturemid := r.centery * iscale;	# frac 0 at row yl=0

	sys->print("rendertest: wall %s + floor %s, running %d ms...\n",
		tex.name, fl.name, vid_ms);

	start := sys->millisec();
	frames := 0;
	elapsed := 0;
	for (;;) {
		elapsed = sys->millisec() - start;
		if (elapsed >= vid_ms)
			break;
		t := elapsed / 40;

		r.clear(0);
		for (x := 0; x < vid_w; x++) {
			light := 4 + (x * 24) / vid_w;
			r.drawcolumn(x, 0, wallh-1, light, tex,
				x + t, texturemid, iscale);
		}
		for (y := wallh; y < vid_h; y++) {
			light := 8 + ((y - wallh) * 20) / vid_h;
			r.drawspan(y, 0, vid_w-1, light, fl,
				t << 16, y << 16, 1 << 16, 0);
		}
		r.convert(v.fb);
		v.present();
		frames++;
	}

	if (elapsed <= 0)
		elapsed = 1;
	sys->print("rendertest: %d frames in %d ms = %d fps\n",
		frames, elapsed, frames * 1000 / elapsed);
	v.close();
	w.close();
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: doom [-d] [-t] [-r] [doom.wad]\n");
	raise "fail:usage";
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "doom: %s\n", s);
	raise "fail:error";
}
