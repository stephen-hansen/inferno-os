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
		nil;

	args = tl args;
	for (;;) {
		if (args == nil ||
		    (hd args != "-v"))
			break;
		if (hd args == "-v")
			verbose = 1;
		else {
			usage();
			return;
		}
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

	# exercise read on a small and a medium lump
	checkread(w, "PLAYPAL", 768*14);
	checkread(w, "E1M1", -1);
	w.close();

	# interactive play; -v: sprite diagnostics (PDROP/PROJ/CMISS/POFF)
	play(path, ctxt);
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




usage()
{
	sys->fprint(sys->fildes(2), "usage: doom [-v] [doom.wad]\n");
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
LShift:	con KShift|4;	# run key (vanilla key_speed)
RShift:	con KShift|5;

# X11 evdev keycodes (/dev/scancode, +8: press=code, release=code|0x80)
XK_Esc:	con 9;
XK_Q:	con 24;
XK_W:	con 25;
XK_E:	con 26;
XK_LCtrl:	con 37;
XK_LShift:	con 50;	# evdev LeftShift 42 + 8
XK_RShift:	con 62;	# evdev RightShift 54 + 8
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
turnheld:	int;		# vanilla accelerative-turn counter (tics)
verbose:	int;		# TEMP: -v enables view sprite diagnostics

play(path: string, wmctxt: ref Draw->Context)
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

	(l, merr) := map->open(w, "E1M1");
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

	err = game->setuplevel(l, game->SK_MEDIUM);
	if (err != nil)
		fail(err);

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
	turnheld = 0;	# vanilla accelerative turning starts slow
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
	sys->print("play: E1M1 skill medium: arrows/wasd move, shift=run, ctrl=fire, space=use, esc=quit, F1=snapshot, F2=review\n");
	sys->print("  player at %d,%d angle %d deg\n",
		mo.x >> 16, mo.y >> 16, bamdegrees(mo.angle));

	TICMS := 1000 / 35;
	tick := chan of int;
	spawn timerproc(tick, TICMS);
	tic := 0;
	quit := 0;
	dotic := 0;
	exitshown := 0;		# level-complete announced once
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
					if (navhold >= 3) {
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

		# build ticcmd from key state — vanilla G_BuildTiccmd
		# keyboard subset (g_game.c): walk/run tables selected by
		# the speed key, two-stage accelerative turning (slow 320
		# until turnheld reaches SLOWTURNTICS=6, then 640 walk /
		# 1280 run), independent keys (opposites cancel),
		# MAXPLMOVE clamp.
		# (no mouse/joystick/chat/weapon-keys: milestones 21/25;
		# A/D/Q/E direct strafe keys have no vanilla equivalent
		# but use vanilla sidemove steps.)
		speed := 0;
		if (keystate[LShift] || keystate[RShift])
			speed = 1;
		if (keystate[Left] || keystate[Right])
			turnheld++;
		else
			turnheld = 0;
		# walk/run step tables (vanilla forwardmove/sidemove);
		# turn ramps: 320 for the first 6 tics, then 640/1280
		fmstep, smstep: int;
		if (speed != 0) {
			fmstep = 50;
			smstep = 40;
		} else {
			fmstep = 25;
			smstep = 24;
		}
		atstep := 320;
		if (turnheld >= 6) {
			if (speed != 0)
				atstep = 1280;
			else
				atstep = 640;
		}
		fm := 0;
		sm := 0;
		at := 0;
		btn := 0;
		if (keystate[Up] || keystate['w'])
			fm += fmstep;
		if (keystate[Down] || keystate['s'])
			fm -= fmstep;
		if (keystate[Left])
			at += atstep;
		if (keystate[Right])
			at -= atstep;
		if (keystate['a'])
			sm -= smstep;
		if (keystate['d'])
			sm += smstep;
		if (keystate['q'])
			sm -= smstep;
		if (keystate['e'])
			sm += smstep;
		if (fm > 50)
			fm = 50;
		if (fm < -50)
			fm = -50;
		if (sm > 50)
			sm = 50;
		if (sm < -50)
			sm = -50;
		if (keystate[' '])
			btn |= 2;		# BT_USE
		if (keystate[LCtrl] || keystate[RCtrl])
			btn |= 1;		# BT_ATTACK


		game->setcmd(fm, sm, at, btn);
		game->ticker();

		# vanilla P_UpdateSpecials animate block: advance flat/
		# texture animation on the shared Renderer (game->ticker
		# can't — the sim never holds rr, and Rend module tables
		# are per-load-instance)
		rend->animtic(rr, game->getleveltime());

		# level-exit flags (S1 exit / secret exit; intermission
		# is milestone 16, so just announce once for now)
		if ((game->levexit() != 0 || game->secretexit() != 0) &&
		    exitshown == 0) {
			exitshown = 1;
			sys->print("level complete\n");
		}

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
	XK_LShift =>
		return LShift;
	XK_RShift =>
		return RShift;
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
