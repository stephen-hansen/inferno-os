implement Doom;

	include "sys.m";
	sys: Sys;
	include "draw.m";
	include "wad.m";
	wad: Wad;
	File: import wad;
	include "tk.m";
include "video.m";
	video: Video;
	Context: import video;
include "rend.m";
	rend: Rend;
	Renderer: import rend;
include "map.m";
	map: Map;
	Level: import map;
include "info.m";
	inf: Info;
	MobjInfo: import inf;
include "game.m";
	game: Game;
	Player: import game;
	Mobj: import game;
include "view.m";
	view: View;

Doom: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

WADPATH:	con "doom1.wad";	# shareware IWAD, expected in cwd or via arg

init(ctxt: ref Draw->Context, args: list of string)
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
	mt := 0;
	gt := 0;
	pt := 0;
	demo1 := 0;
	for (;;) {
		if (args == nil ||
		    (hd args != "-d" && hd args != "-t" &&
		     hd args != "-r" && hd args != "-m" &&
		     hd args != "-g" && hd args != "-p" &&
		     hd args != "-v" && hd args != "-demo1"))
			break;
		if (hd args == "-d")
			dump = 1;
		else if (hd args == "-t")
			test = 1;
		else if (hd args == "-r")
			rt = 1;
		else if (hd args == "-m")
			mt = 1;
		else if (hd args == "-p")
			pt = 1;
		else if (hd args == "-v")
			verbose = 1;
		else if (hd args == "-demo1")
			demo1 = 1;
		else
			gt = 1;
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
	if (mt) {
		maptest(path);
		return;
	}
	if (gt) {
		gametest(path);
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

	# no flags: interactive play; -p: wall-hug autopilot (screenshot test)
	# -demo1: play the built-in DEMO1 lump (deterministic repro path)
	# -v: sprite diagnostics (PDROP/PROJ/CMISS/POFF) on stdout
	play(path, pt, ctxt, demo1);
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

maptest(path: string)
{
	map = load Map Map->PATH;
	if (map == nil)
		map = load Map "map.dis";
	if (map == nil)
		fail(sys->sprint("can't load Map module: %r"));

	(w, err) := wad->open(path);
	if (w == nil)
		fail(err);

	(l, merr) := map->open(w, "E1M1");
	if (l == nil)
		fail(merr);

	sys->print("maptest: %s: %d vertices, %d linedefs, %d sidedefs, %d sectors, %d things\n",
		l.name, len l.vertices, len l.lines, len l.sides,
		len l.sectors, len l.things);

	v0 := l.vertices[0];
	sys->print("  vertex 0: %d,%d\n", v0.x >> 16, v0.y >> 16);

	s0 := l.sectors[0];
	sys->print("  sector 0: floor %d ceil %d, %s/%s, light %d\n",
		s0.floorheight >> 16, s0.ceilingheight >> 16,
		s0.floortexture, s0.ceilingtexture, s0.lightlevel);

	sd0 := l.sides[0];
	sys->print("  side 0: mid %s, sector light %d\n",
		sd0.midtexture, sd0.sector.lightlevel);

	ln0 := l.lines[0];
	back := "none";
	if (ln0.sides[1] != nil)
		back = "yes";
	sys->print("  line 0: v%d->v%d dx %d dy %d, flags 0x%x, back side %s\n",
		ln0.v1, ln0.v2, ln0.dx >> 16, ln0.dy >> 16, ln0.flags, back);

	two := 0;
	for (i := 0; i < len l.lines; i++)
		if (l.lines[i].sides[1] != nil)
			two++;
	sys->print("  two-sided lines: %d\n", two);

	for (i = 0; i < len l.things; i++) {
		t := l.things[i];
		if (t.typ == 1)
			sys->print("  player 1 start: %d,%d angle %d\n",
				t.x >> 16, t.y >> 16, t.angle);
	}

	w.close();
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: doom [-d] [-t] [-r] [-m] [-g] [-p] [-v] [-demo1] [doom.wad]\n");
	raise "fail:usage";
}

# BAM angle to whole degrees (unsigned 32-bit interpretation)
bamdegrees(angle: int): int
{
	ua := big angle;
	if (ua < big 0)
		ua = ua + big 16r100000000;
	return int (ua * big 360 / big 16r100000000);
}

# signed byte from the demo stream (vanilla *demo_p++ as signed char)
demobyte(ofs: int): int
{
	v := int demosrc[ofs];
	if (v >= 128)
		v -= 256;
	return v;
}

gametest(path: string)
{
	game = load Game Game->PATH;
	if (game == nil)
		game = load Game "game.dis";
	if (game == nil)
		fail(sys->sprint("can't load Game module: %r"));
	err := game->init();
	if (err != nil)
		fail(err);

	# game->init already built the Info tables; grab the same instance
	inf = load Info Info->PATH;
	if (inf == nil)
		inf = load Info "info.dis";
	if (inf == nil)
		fail(sys->sprint("can't load Info module: %r"));

	(w, werr) := wad->open(path);
	if (w == nil)
		fail(werr);

	map = load Map Map->PATH;
	if (map == nil)
		map = load Map "map.dis";
	if (map == nil)
		fail(sys->sprint("can't load Map module: %r"));

	(l, merr) := map->open(w, "E1M1");
	if (l == nil)
		fail(merr);

	err = game->setuplevel(l, game->SK_MEDIUM);
	if (err != nil)
		fail(err);

	p := game->consoleplayer();
	if (p == nil || p.mo == nil)
		fail("no player 1 after setuplevel");
	mo := p.mo;
	sys->print("gametest: E1M1 skill medium: %d mobjs, %d kills, %d items\n",
		game->nummobjs(), game->totalkills, game->totalitems);
	sys->print("  player: %d,%d,%d angle %d deg, health %d, state %d, z %d\n",
		mo.x >> 16, mo.y >> 16, mo.z >> 16, bamdegrees(mo.angle),
		mo.health, mo.state, mo.z >> 16);
	sys->print("  viewz %d, floorz %d, ceilingz %d\n",
		p.viewz >> 16, mo.floorz >> 16, mo.ceilingz >> 16);

	# scripted tics: 1s run north, 0.5s turn left 90 deg in place,
	# 1s run west, 0.5s stop
	total := 105;
	start := sys->millisec();
	for (t := 0; t < total; t++) {
		fm := 0;
		sm := 0;
		at := 0;
		if (t < 35) {
			fm = 50;		# run forward (max)
		} else if (t < 51) {
			at = 1024;		# 16 * (1024<<16) = ANG90 left
		} else if (t < 86) {
			fm = 50;
		}
		game->setcmd(fm, sm, at, 0);
		game->ticker();

		# pace to 35Hz from t0
		deadline := start + (t + 1) * 1000 / 35;
		now := sys->millisec();
		if (deadline > now)
			sys->sleep(deadline - now);

		if ((t + 1) % 35 == 0) {
			sys->print("  t=%d pos %d,%d,%d angle %d deg, mom %d,%d, state %s\n",
				t + 1, mo.x >> 16, mo.y >> 16, mo.z >> 16,
				bamdegrees(mo.angle), mo.momx >> 16, mo.momy >> 16,
				inf->statename(mo.state));
		}
	}
	elapsed := sys->millisec() - start;
	if (elapsed <= 0)
		elapsed = 1;
	sys->print("gametest: %d tics in %d ms = %d tics/sec (want ~35)\n",
		total, elapsed, total * 1000 / elapsed);
	sys->print("  final pos %d,%d angle %d deg, health %d, mobjs %d\n",
		mo.x >> 16, mo.y >> 16, bamdegrees(mo.angle), mo.health,
		game->nummobjs());
	w.close();
}

# key-state bits indexed by kbdm-> constants / ASCII
NKEYS:	con 16rE100;	# enough for Spec|0x10+8 View keys

# keyboard key constants (from module/keyboard.m, header-only)
Spec:	con 16rE000;
KShift:	con Spec|16r00;
KView:	con Spec|16r10;
Esc:	con 16r1b;
Up:	con KView|2;
Down:	con KView|3;
Left:	con KView|4;
Right:	con KView|5;
Snap:	con KView|6;	# F1: dump a frame snapshot log for offline replay
Rev:	con KView|7;	# F2: toggle frame-history review (step with Left/Right)
LCtrl:	con KShift|2;
RCtrl:	con KShift|3;

# X11 evdev keycodes (/dev/scancode, +8: press=code, release=code|0x80)
XK_Esc:	con 9;
XK_Q:	con 24;
XK_W:	con 25;
XK_E:	con 26;
XK_LCtrl:	con 37;
XK_A:	con 38;
XK_S:	con 39;
XK_D:	con 40;
XK_Space:	con 65;
XK_RCtrl:	con 105;
XK_Up:	con 111;
XK_Left:	con 113;
XK_Right:	con 114;
XK_Down:	con 116;
XK_F1:	con 67;	# evdev 59 + 8
XK_F2:	con 68;	# evdev 60 + 8

keystate:	array of int;
keych:		chan of int;
snapreq:	int;		# F1 pressed: dump a frame snapshot after present
snapno:		int;		# snapshot file sequence number
revreq:		int;		# F2 pressed: toggle frame-history review
review:		int;		# -1 = live; else logical ring index under review
revshow:	int;		# review frame needs presenting
prevleft, prevright:	int;	# nav edge state in review
navhold:	int;		# held-nav repeat counter in review
demosrc:	array of byte;	# TEMP demo playback stream (DEMO1 lump)
demoofs:	int;
verbose:	int;		# TEMP: -v enables view sprite diagnostics

play(path: string, autopilot: int, wmctxt: ref Draw->Context, demo1: int)
{
	game = load Game Game->PATH;
	if (game == nil)
		game = load Game "game.dis";
	if (game == nil)
		fail(sys->sprint("can't load Game module: %r"));
	err := game->init();
	if (err != nil)
		fail(err);

	inf = load Info Info->PATH;
	if (inf == nil)
		inf = load Info "info.dis";
	if (inf == nil)
		fail(sys->sprint("can't load Info module: %r"));

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

	map = load Map Map->PATH;
	if (map == nil)
		map = load Map "map.dis";
	if (map == nil)
		fail(sys->sprint("can't load Map module: %r"));

	(w, werr) := wad->open(path);
	if (w == nil)
		fail(werr);

	rr := ref Renderer;
	err = rr.init(w, vid_w, vid_h);
	if (err != nil)
		fail(err);

	demomap := "E1M1";
	demoskill := game->SK_MEDIUM;
	if (demo1) {
		i := w.find("DEMO1");
		if (i < 0)
			fail("no DEMO1 lump");
		(dbytes, derr) := w.read(i);
		if (dbytes == nil || len dbytes < 13)
			fail("bad DEMO1 lump");
		if (int dbytes[0] != 109)
			fail("unsupported demo version");
		demoskill = int dbytes[1];
		demomap = sys->sprint("E%dM%d", int dbytes[2], int dbytes[3]);
		demosrc = dbytes;
		demoofs = 13;		# ver+skill+ep+map+dm+respawn+fast+nomon+cons
					# +playeringame[4]
	}

	(l, merr) := map->open(w, demomap);
	if (l == nil)
		fail(merr);

	# load world view renderer
	view = load View View->PATH;
	if (view == nil)
		view = load View "view.dis";
	if (view == nil)
		fail(sys->sprint("can't load View module: %r"));
	err = view->init(rr, l, w, game, vid_w, vid_h);
	if (err != nil)
		fail(err);
	if (verbose)
		view->dbgprints = 1;

	err = game->setuplevel(l, demoskill);
	if (err != nil)
		fail(err);
	if (demo1)
		sys->print("play: DEMO1 on %s skill %d (esc quits)\n",
			demomap, demoskill);

	v: ref Context;
	wmkeys: chan of string;
	verr: string;
	if (wmctxt != nil) {
		(v, wmkeys, verr) = video->openwm(wmctxt, vid_w, vid_h, "Doom");
		if (v == nil)
			fail(verr);
	} else {
		(v, verr) = video->open(vid_w, vid_h);
		if (v == nil)
			fail(verr);
	}

	keystate = array[NKEYS] of int;
	# buffered: kbdreader must keep draining emu's gkscanq even while
	# the game loop is rendering.  gkscanq is a 256-byte queue and
	# qproduce SILENTLY DROPS events when full (emu/port/qio.c), so
	# with an unbuffered channel kbdreader stalled on every frame and
	# a long hold (X auto-repeat) could fill the queue and lose the
	# release event entirely.  128 events >> anything one frame can
	# generate; sends only block if the game stops consuming entirely.
	keych = chan [128] of int;
	# in both modes read /dev/scancode: it reports true press/release
	# (code, code|0x80).  the wm kbd channel only ever delivers press
	# runes with no key-up, so keys stick and coalesce wrongly.
	spawn kbdreader(keych);
	if (wmctxt != nil)
		spawn wmquitshim(wmkeys, keych);

	p := game->consoleplayer();
	if (p == nil || p.mo == nil)
		fail("no player 1 after setuplevel");
	mo := p.mo;
	sys->print("play: E1M1 skill medium: arrows/wasd move, space=use, esc=quit, F1=snapshot, F2=review\n");
	sys->print("  player at %d,%d angle %d deg\n",
		mo.x >> 16, mo.y >> 16, bamdegrees(mo.angle));

	if (autopilot) {
		walltest(rr, v, mo);
		v.close();
		w.close();
		return;
	}

	TICMS := 1000 / 35;
	tick := chan of int;
	spawn timerproc(tick, TICMS);
	tic := 0;
	quit := 0;
	dotic := 0;
	for (; !quit;) {
		# key events only update keystate; tics come SOLELY from the
		# tick timer (key-driven tics made the game surge at
		# auto-repeat rate and stutter between repeats).
		#
		# drain ALL pending key events before considering the tick.
		# libinterp's xecalt picks among simultaneously-ready alt
		# cases at random (LCG % nready), and after a render both
		# keych and tick are usually ready (render >= TICMS): the old
		# single alt drained a key backlog at ~1 event per render
		# cycle, while holding a key (X auto-repeat) kept adding to
		# it - so a release at the tail of the backlog only applied
		# seconds later, the longer the key had been held.  the `*`
		# default runs only when keych is empty, so this loop exits
		# exactly when input is drained, and a tic can only run right
		# after a full drain: a release lands in keystate before the
		# next frame is drawn and stops the motion on the next tic.
		# (break inside an alt case exits the ALT, not the for — alt
		# pushes its own break target, com.c — so signal with a flag
		# and break AFTER the alt, where the for is innermost.)
		drain := 1;
		for (;;) {
			alt {
			k := <-keych =>
				if (handlekey(k))
					quit = 1;
			* =>
				drain = 0;
			}
			if (!drain || quit)
				break;
		}
		if (quit) {
			if (review != -1) {
				# Esc in review exits review instead of quitting
				quit = 0;
				review = -1;
				keystate[Esc] = 0;
				sys->print("review: resumed live\n");
			} else
				break;
		}
		# idle: block for the next key or tic; keys arriving while
		# waiting are handled immediately, exactly as before
		alt {
		k := <-keych =>
			quit = handlekey(k);
		<-tick =>
			dotic = 1;
		}
		if (quit) {
			if (review != -1) {
				# Esc in review exits review instead of quitting
				quit = 0;
				review = -1;
				keystate[Esc] = 0;
				sys->print("review: resumed live\n");
			} else
				break;
		}
		if (!dotic)
			continue;
		dotic = 0;

		# frame-history review (F2): sim frozen, step through the
		# ring with Left/Right (tap = step, hold = scroll), F1
		# snapshots the shown frame, F2/Esc resumes live play.
		if (revreq) {
			revreq = 0;
			if (review != -1) {
				review = -1;
				sys->print("review: resumed live\n");
			} else {
				rn := view->ringlen();
				if (rn > 0) {
					review = rn - 1;
					revshow = 1;
				} else
					sys->print("review: no frames yet\n");
			}
		}
		if (review != -1) {
			rvn := view->ringlen();
			if (rvn <= 0) {
				review = -1;
			} else {
				if (review >= rvn)
					review = rvn - 1;
				rvni := review;
				rvstep := 0;
				if (keystate[Left] && !prevleft) {
					rvni--;
					rvstep = 1;
				}
				if (keystate[Right] && !prevright) {
					rvni++;
					rvstep = 1;
				}
				if (!rvstep) {
					if (keystate[Left] || keystate[Right])
						navhold++;
					else
						navhold = 0;
					if (navhold >= 5) {
						if (keystate[Left])
							rvni--;
						if (keystate[Right])
							rvni++;
						navhold = 0;
					}
				} else
					navhold = 0;
				prevleft = keystate[Left];
				prevright = keystate[Right];
				if (rvni < 0)
					rvni = 0;
				if (rvni >= rvn)
					rvni = rvn - 1;
				if (snapreq) {
					snapreq = 0;
					rpath := sys->sprint("doomsnap%d.log", snapno);
					snapno++;
					rerr := view->ringsnap(rpath, tic, rvni);
					if (rerr != nil)
						sys->print("snapshot FAILED: %s\n", rerr);
					else
						sys->print("snapshot %s written (review %d/%d, frame tic %d)\n",
							rpath, rvni, rvn, view->ringtic(rvni));
				}
				if (rvni != review || revshow) {
					revshow = 0;
					review = rvni;
					perr := view->ringrestore(rvni);
					if (perr != nil) {
						sys->print("review: %s\n", perr);
						review = -1;
					} else {
						rr.convert(v.fb);
						v.present();
						sys->print("review %d/%d frame tic %d\n",
							rvni, rvn, view->ringtic(rvni));
					}
				}
			}
			continue;
		}
		prevleft = keystate[Left];
		prevright = keystate[Right];

		tic++;

		# build ticcmd from key state
		fm := 0;
		sm := 0;
		at := 0;
		btn := 0;
		if (keystate[Up] || keystate['w'])
			fm += 50;
		if (keystate[Down] || keystate['s'])
			fm -= 50;
		if (keystate[Left])
			at += 1280;		# turn left (BAM, ~22.5 deg/tic)
		if (keystate[Right])
			at -= 1280;
		if (keystate['a'] && !keystate[Left])
			sm -= 25;
		if (keystate['d'] && !keystate[Right])
			sm += 25;
		if (keystate['q'])
			sm -= 25;
		if (keystate['e'])
			sm += 25;
		if (keystate[' '])
			btn |= 1;		# BT_USE
		if (keystate[LCtrl] || keystate[RCtrl])
			btn |= 2;		# BT_ATTACK

		# demo playback overrides the ticcmd (G_ReadDemoTiccmd:
		# s8 forward, s8 side, s8 angleturn<<8, u8 buttons; our
		# buttons bit 2=attack 1=use vs vanilla 1/4)
		if (demo1 && demosrc != nil) {
			if (demoofs + 4 > len demosrc
			    || int demosrc[demoofs] == 16r80) {
				sys->print("play: demo ended at t=%d\n",
					tic);
				quit = 1;
				break;
			}
			fm = demobyte(demoofs);
			demoofs++;
			sm = demobyte(demoofs);
			demoofs++;
			at = demobyte(demoofs) << 8;
			demoofs++;
			db := int demosrc[demoofs];
			demoofs++;
			if (db & 1)
				btn |= 2;	# BT_ATTACK
			if (db & 4)
				btn |= 1;	# BT_USE
		}

		game->setcmd(fm, sm, at, btn);
		game->ticker();

		# render: update view from player, walk BSP, present
		game->setview();
		view->render(game->viewx, game->viewy, game->viewz,
			game->viewangle, game->viewcos, game->viewsin,
			game->mobjs);
		rr.convert(v.fb);
		v.present();

		# user snapshot (F1): dump the frame just presented for
		# offline replay; game continues normally.
		if (snapreq) {
			snapreq = 0;
			spath := sys->sprint("doomsnap%d.log", snapno);
			snapno++;
			serr := view->snapshot(spath, tic);
			if (serr != nil)
				sys->print("snapshot FAILED: %s\n", serr);
			else
				sys->print("snapshot %s written at t=%d pos %d,%d angle %d deg\n",
					spath, tic, mo.x >> 16, mo.y >> 16,
					bamdegrees(mo.angle));
		}

		if (tic % 70 == 0) {
			p = game->consoleplayer();
			if (p != nil && p.mo != nil)
				mo = p.mo;
			sys->print("t=%d pos %d,%d,%d angle %d deg health %d spr %d ds %d mid %d\n",
				tic, mo.x >> 16, mo.y >> 16, mo.z >> 16,
				bamdegrees(mo.angle), mo.health,
				view->nsprites, view->ndrawsegs, view->nmasked);
		}
	}
	v.close();
	w.close();
	sys->print("play: quit at t=%d\n", tic);
}

# autopilot screenshot test: run forward out of the spawn closet into the
# room first (so the camera is in open space), then do a slow sweep so
# screenshots catch the room interior, not the closet's back wall.
walltest(rr: ref Renderer, v: ref Context, mo: ref Mobj)
{
	sys->print("walltest: running forward 40 tics into the room...\n");
	for (t := 0; t < 40; t++) {
		game->setcmd(50, 0, 0, 0);
		game->ticker();
		game->setview();
		view->render(game->viewx, game->viewy, game->viewz,
			game->viewangle, game->viewcos, game->viewsin,
			game->mobjs);
		rr.convert(v.fb);
		v.present();
		sys->sleep(1000 / 35);
	}
	sys->print("walltest: sweeping 180 deg (12 x 15 deg)...\n");
	turn := 2730;		# 2730<<16 ~ 15 deg BAM
	for (s := 0; s < 12; s++) {
		game->setcmd(0, 0, turn, 0);
		game->ticker();
		game->setview();
		view->render(game->viewx, game->viewy, game->viewz,
			game->viewangle, game->viewcos, game->viewsin,
			game->mobjs);
		rr.convert(v.fb);
		v.present();
		sys->print("  step %2d angle %d deg\n", s + 1, bamdegrees(mo.angle));
		sys->sleep(700);
	}
	sys->print("walltest: done, final pos %d,%d angle %d deg\n",
		mo.x >> 16, mo.y >> 16, bamdegrees(mo.angle));
}

# map raw X11 evdev keycode to our keystate index; -1 = ignore
keysym(code: int): int
{
	case code {
	XK_Esc =>
		return Esc;
	XK_Q =>
		return 'q';
	XK_W =>
		return 'w';
	XK_E =>
		return 'e';
	XK_LCtrl =>
		return LCtrl;
	XK_A =>
		return 'a';
	XK_S =>
		return 's';
	XK_D =>
		return 'd';
	XK_Space =>
		return ' ';
	XK_RCtrl =>
		return RCtrl;
	XK_Up =>
		return Up;
	XK_Down =>
		return Down;
	XK_Left =>
		return Left;
	XK_Right =>
		return Right;
	XK_F1 =>
		return Snap;
	XK_F2 =>
		return Rev;
	* =>
		return -1;
	}
}

# wm delivers a "quit" on window close; the game reads real key state
# from /dev/scancode, so this shim only needs to forward quit.
wmquitshim(src: chan of string, ch: chan of int)
{
	for (;;) {
		s := <-src;
		if (s == "quit")
			ch <-= Esc;
	}
}

	# /dev/scancode: raw X11 keycodes, press=code, release=code|0x80.
	# true key-up events (unlike /dev/keyboard's press-only runes, which
	# relied on X auto-repeat + a hold-decay hack that leaked movement
	# after release and stuttered between repeats).  opening /dev/scancode
	# makes emu route ALL key events here (xkeyboard: gkscanq path).
	# note: the FIRST read at offset 0 returns the gkscanid banner string
	# ("emu_x11"), not scancodes; skip it and keep reading scancodes.
	kbdreader(ch: chan of int)
	{
		dfd := sys->open("/dev/scancode", sys->OREAD);
		if (dfd == nil) {
			sys->print("kbdreader: can't open /dev/scancode: %r\n");
			return;
		}
		buf := array[64] of byte;
		for (;;) {
			n := sys->read(dfd, buf, len buf);
			if (n < 1)
				break;
			for (i := 0; i < n; i++) {
				b := int buf[i];
				k := keysym(b & 16r7f);
				if (k < 0)
					continue;
				if ((b & 16r80) != 0)	# release
					ch <-= k | 16r10000;
				else
					ch <-= k;
			}
		}
	}

# apply one scancode event to keystate; returns 1 if it was Esc (quit).
# press = k, release = k | 16r10000 (the /dev/scancode encoding).
handlekey(k: int): int
{
	if (k == Esc)
		return 1;
	if ((k & 16r10000) != 0) {	# release
		k &= ~16r10000;
		if (k >= 0 && k < NKEYS)
			keystate[k] = 0;
	} else if (k >= 0 && k < NKEYS) {
		keystate[k] = 1;
		if (k == Snap)
			snapreq = 1;	# edge: one snapshot per press
		if (k == Rev)
			revreq = 1;	# edge: toggle review per press
	}
	return 0;
}

timerproc(ch: chan of int, ms: int)
{
	for (;;) {
		sys->sleep(ms);
		ch <-= 1;
	}
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "doom: %s\n", s);
	raise "fail:error";
}
