# Status bar (milestone 18): st_stuff.c + st_lib.c, single-player
# shareware path.  Reference: doomgeneric st_stuff.c/st_lib.c
# (GPL-2).  Full redraw each frame (no vanilla backing-screen diff
# blits: pixels are identical, and the JIT makes a complete redraw
# cheaper than diff tracking).
#
# Layout constants are vanilla st_stuff.c (ST_* below).  Face state
# machine is a literal transcription including its static-variable
# quirks (priority decays only when the face count expires).

implement St;

include "sys.m";
include "wad.m";
	File: import wad;
include "rend.m";
include "map.m";
include "info.m";
	MobjInfo: import inf;
include "sound.m";
include "game.m";
include "st.m";

sys: Sys;
wad: Wad;
rend: Rend;
inf: Info;
game: Game;

# geometry (st_stuff.c)
SBARTOP:	con 168;	# SCREENHEIGHT - SBARHEIGHT(32)
ST_AMMOX:	con 44;
ST_AMMOY:	con 171;
ST_HEALTHX:	con 90;
ST_HEALTHY:	con 171;
ST_ARMSX:	con 111;
ST_ARMSY:	con 172;
ST_ARMSBGX:	con 104;
ST_ARMSBGY:	con 168;
ST_ARMSXSPACE:	con 12;
ST_ARMSYSPACE:	con 10;
ST_ARMORX:	con 221;
ST_ARMORY:	con 171;
ST_KEY0X:	con 239;
ST_KEY0Y:	con 171;
ST_AMMO0X:	con 288;
ST_MAXAMMO0X:	con 314;
ST_FACESX:	con 143;
ST_FACESY:	con 168;

# face set layout (st_stuff.c)
FACESTRIDE:	con 8;
NUMPAINFACES:	con 5;
TURNOFFSET:	con 3;
OUCHOFFSET:	con 5;
EVILGRINOFFSET:	con 6;
RAMPAGEOFFSET:	con 7;
GODFACE:	con 40;
DEADFACE:	con 41;
NUMFACES:	con 42;
MUCHPAIN:	con 20;

# palette shifts (st_stuff.c STARTREDPALS etc.)
STARTREDPALS:	con 1;
STARTBONUSPALS:	con 9;
NUMREDPALS:	con 8;
NUMBONUSPALS:	con 4;
RADIATIONPAL:	con 13;

TICRATE:	con 35;
ANG45:		con 16r20000000;
ANG180:		con ~2147483647;	# 16r80000000

# Limbo: allocation expressions reject `array of byte` as an element
# type, so patches live in a small adt wrapper for the nested arrays.
Patch: adt {
	d:	array of byte;
};

sbar:		array of byte;
tallnum:	array of Patch;
tallpct:	array of byte;
tallminus:	array of byte;
shortnum:	array of Patch;
keys:		array of Patch;
armsbg:		array of byte;
arms:		array of array of Patch;
faceback:	array of byte;
faces:		array of Patch;
tallw, shortw:	int;

# face state (vanilla statics)
faceindex:	int;
facecount:	int;
priority:	int;
lastattackdown:	int;
oldhealthv:	int;
painhealth:	int;
paincalc:	int;
oldweap:	array of int;
rndindex:	int;
lastpal:	int;	# last palette index applied (-1 = none)

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

need(w: ref Wad->File, name: string): array of byte
{
	b := getpatch(w, name);
	if (b == nil)
		sys->print("st: missing patch %s\n", name);
	return b;
}

init(w: ref Wad->File, g: Game): string
{
	sys = load Sys Sys->PATH;
	# File adt methods (w.find/w.read) dispatch through this handle
	wad = load Wad Wad->PATH;
	if (wad == nil)
		return "can't load Wad module";
	rend = load Rend Rend->PATH;
	if (rend == nil)
		return "can't load Rend module";
	inf = load Info Info->PATH;
	if (inf == nil)
		return "can't load Info module";
	ierr := inf->init();
	if (ierr != nil)
		return ierr;
	game = g;	# doom.b's initialized instance (tables live)
	if (game == nil)
		return "no Game module";

	sbar = need(w, "STBAR");
	if (sbar == nil)
		return "no STBAR";
	tallnum = array[10] of Patch;
	shortnum = array[10] of Patch;
	for (i := 0; i < 10; i++) {
		tallnum[i].d = need(w, sys->sprint("STTNUM%d", i));
		shortnum[i].d = need(w, sys->sprint("STYSNUM%d", i));
		if (tallnum[i].d == nil || shortnum[i].d == nil)
			return "missing number patch";
	}
	tallpct = need(w, "STTPRCNT");
	tallminus = need(w, "STTMINUS");
	if (tallpct == nil || tallminus == nil)
		return "missing percent/minus patch";
	keys = array[6] of Patch;
	for (i = 0; i < 6; i++) {
		keys[i].d = need(w, sys->sprint("STKEYS%d", i));
		if (keys[i].d == nil)
			return "missing key patch";
	}
	armsbg = need(w, "STARMS");
	if (armsbg == nil)
		return "missing STARMS";
	arms = array[6] of array of Patch;
	for (i = 0; i < 6; i++) {
		arms[i] = array[2] of Patch;
		arms[i][0].d = need(w, sys->sprint("STGNUM%d", i + 2));
		arms[i][1].d = shortnum[i + 2].d;
		if (arms[i][0].d == nil)
			return "missing arms patch";
	}
	faceback = need(w, "STFB0");
	if (faceback == nil)
		return "missing STFB0";
	# faces in loader order: per pain level STFST{i}{0..2}, STFTR{i}0,
	# STFTL{i}0, STFOUCH{i}, STFEVL{i}, STFKILL{i}; then god, dead.
	faces = array[NUMFACES] of Patch;
	fnum := 0;
	for (i = 0; i < NUMPAINFACES; i++) {
		for (j := 0; j < 3; j++) {
			faces[fnum].d = need(w, sys->sprint("STFST%d%d", i, j));
			fnum++;
		}
		faces[fnum].d = need(w, sys->sprint("STFTR%d0", i));
		fnum++;
		faces[fnum].d = need(w, sys->sprint("STFTL%d0", i));
		fnum++;
		faces[fnum].d = need(w, sys->sprint("STFOUCH%d", i));
		fnum++;
		faces[fnum].d = need(w, sys->sprint("STFEVL%d", i));
		fnum++;
		faces[fnum].d = need(w, sys->sprint("STFKILL%d", i));
		fnum++;
	}
	faces[fnum].d = need(w, "STFGOD0");
	fnum++;
	faces[fnum].d = need(w, "STFDEAD0");
	for (i = 0; i < NUMFACES; i++)
		if (faces[i].d == nil)
			return "missing face patch";

	tallw = rend->rpatchwidth(tallnum[0].d);
	shortw = rend->rpatchwidth(shortnum[0].d);

	faceindex = 0;
	facecount = 0;
	priority = 0;
	lastattackdown = -1;
	oldhealthv = -1;
	painhealth = -1;
	paincalc = 0;
	rndindex = 0;
	lastpal = -1;
	oldweap = array[9] of int;
	for (i = 0; i < 9; i++)
		oldweap[i] = 0;
	return nil;
}

start(p: ref Game->Player)
{
	faceindex = 0;
	oldhealthv = -1;
	painhealth = -1;
	if (oldweap == nil)
		oldweap = array[9] of int;
	for (i := 0; i < 9; i++)
		oldweap[i] = 0;
	if (p != nil)
		for (i = 0; i < 9; i++)
			oldweap[i] = p.weaponowned[i];
}

# vanilla M_Random: own index into the shared rndtable (must NOT
# disturb the sim's P_Random sequence)
mrandom(): int
{
	rndindex = (rndindex + 1) & 16rff;
	return inf->rndtable[rndindex];
}

# unsigned angle compare (C angle_t semantics on 32-bit ints)
ult(a, b: int): int
{
	return ((a ^ ANG180) < (b ^ ANG180));
}

painoffset(p: ref Game->Player): int
{
	health := p.health;
	if (health > 100)
		health = 100;
	if (health != painhealth) {
		paincalc = FACESTRIDE * (((100 - health) * NUMPAINFACES) / 101);
		painhealth = health;
	}
	return paincalc;
}

# vanilla ST_updateFaceWidget: dead > evil grin > turned head >
# straight ahead, with priority only decaying when the timer expires.
updateface(p: ref Game->Player, rand: int)
{
	if (priority < 10) {
		if (p.health <= 0) {
			priority = 9;
			faceindex = DEADFACE;
			facecount = 1;
		}
	}
	if (priority < 9) {
		if (p.bonuscount != 0) {
			evil := 0;
			for (i := 0; i < 9; i++) {
				if (oldweap[i] != p.weaponowned[i]) {
					evil = 1;
					oldweap[i] = p.weaponowned[i];
				}
			}
			if (evil != 0) {
				priority = 8;
				facecount = 2 * TICRATE;
				faceindex = painoffset(p) + EVILGRINOFFSET;
			}
		}
	}
	if (priority < 8) {
		if (p.damagecount != 0 && p.attacker != nil
		    && p.attacker != p.mo) {
			priority = 7;
			if (p.health - oldhealthv > MUCHPAIN) {
				facecount = TICRATE;
				faceindex = painoffset(p) + OUCHOFFSET;
			} else {
				badguyangle := game->pointtoangle2(p.mo.x,
					p.mo.y, p.attacker.x, p.attacker.y);
				diffang: int;
				i: int;
				if (ult(p.mo.angle, badguyangle)) {
					diffang = badguyangle - p.mo.angle;
					if (ult(ANG180, diffang))
						i = 1;
					else
						i = 0;
				} else {
					diffang = p.mo.angle - badguyangle;
					if (ult(ANG180, diffang))
						i = 0;
					else
						i = 1;
				}
				facecount = TICRATE;
				faceindex = painoffset(p);
				if (ult(diffang, ANG45))
					faceindex += RAMPAGEOFFSET;
				else if (i != 0)
					faceindex += TURNOFFSET;
				else
					faceindex += TURNOFFSET + 1;
			}
		}
	}
	if (priority < 7) {
		if (p.damagecount != 0) {
			if (p.health - oldhealthv > MUCHPAIN) {
				priority = 7;
				facecount = TICRATE;
				faceindex = painoffset(p) + OUCHOFFSET;
			} else {
				priority = 6;
				facecount = TICRATE;
				faceindex = painoffset(p) + RAMPAGEOFFSET;
			}
		}
	}
	if (priority < 6) {
		if (p.attackdown != 0) {
			if (lastattackdown == -1)
				lastattackdown = 2 * TICRATE;
			else {
				lastattackdown = lastattackdown - 1;
				if (lastattackdown == 0) {
					priority = 5;
					faceindex = painoffset(p) + RAMPAGEOFFSET;
					facecount = 1;
					lastattackdown = 1;
				}
			}
		} else
			lastattackdown = -1;
	}
	if (priority < 5) {
		if ((p.cheats & game->CF_GODMODE) != 0
		    || p.powers[game->PW_INVULNERABILITY] != 0) {
			priority = 4;
			faceindex = GODFACE;
			facecount = 1;
		}
	}
	if (facecount == 0) {
		faceindex = painoffset(p) + (rand % 3);
		facecount = TICRATE / 2;
		priority = 0;
	}
	facecount = facecount - 1;
}

ticker(p: ref Game->Player)
{
	if (p == nil)
		return;
	rand := mrandom();
	updateface(p, rand);
	oldhealthv = p.health;
}

# draw a right-aligned number ending at xr (vanilla STlib_drawNum)
drawnum(r: ref Rend->Renderer, xr, y, ndig, num: int,
		digits: array of Patch, w: int)
{
	neg := 0;
	if (num < 0) {
		neg = 1;
		if (ndig == 2 && num < -9)
			num = -9;
		else if (ndig == 3 && num < -99)
			num = -99;
		num = -num;
	}
	x := xr;
	if (num == 0) {
		x -= w;
		rdrawpatch(r, x, y, digits[0].d);
	} else {
		n := num;
		while (n != 0) {
			x -= w;
			rdrawpatch(r, x, y, digits[n % 10].d);
			n /= 10;
		}
	}
	if (neg)
		rdrawpatch(r, x - 8, y, tallminus);
}

rdrawpatch(r: ref Rend->Renderer, x, y: int, pd: array of byte)
{
	if (pd != nil)
		rend->rdrawpatch(r, x, y, pd);
}

# weaponinfo ammo column (d_items.c order)
weaponammo(w: int): int
{
	if (w == game->WP_PISTOL)
		return game->AM_CLIP;
	if (w == game->WP_SHOTGUN || w == game->WP_SUPERSHOTGUN)
		return game->AM_SHELL;
	if (w == game->WP_CHAINGUN)
		return game->AM_CLIP;
	if (w == game->WP_MISSILE)
		return game->AM_MISL;
	if (w == game->WP_PLASMA || w == game->WP_BFG)
		return game->AM_CELL;
	return game->AM_NOAMMO;	# fist, chainsaw
}

# vanilla ST_doPaletteStuff: damage -> red shift, pickup -> gold,
# radiation suit -> green.  Palette indices are PLAYPAL rows.
dopalette(r: ref Rend->Renderer, p: ref Game->Player)
{
	cnt := p.damagecount;
	if (p.powers[game->PW_STRENGTH] != 0) {
		# slowly fade the berserk red out
		bzc := 12 - (p.powers[game->PW_STRENGTH] >> 6);
		if (bzc > cnt)
			cnt = bzc;
	}
	pal := 0;
	if (cnt != 0) {
		pal = (cnt + 7) >> 3;
		if (pal >= NUMREDPALS)
			pal = NUMREDPALS - 1;
		pal += STARTREDPALS;
	} else if (p.bonuscount != 0) {
		pal = (p.bonuscount + 7) >> 3;
		if (pal >= NUMBONUSPALS)
			pal = NUMBONUSPALS - 1;
		pal += STARTBONUSPALS;
	} else if (p.powers[game->PW_IRONFEET] > 4 * 32
	    || (p.powers[game->PW_IRONFEET] & 8) != 0)
		pal = RADIATIONPAL;
	if (pal != lastpal) {
		lastpal = pal;
		rend->rpalette(r, pal);
	}
}

drawer(r: ref Rend->Renderer, p: ref Game->Player)
{
	if (p == nil || sbar == nil)
		return;
	# palette shift from damage/pickup/radiation (vanilla does
	# this in ST_Drawer before the widgets)
	dopalette(r, p);

	# background
	rdrawpatch(r, 0, SBARTOP, sbar);

	# ready-weapon ammo (tall): no-ammo weapons show nothing
	wa := weaponammo(p.readyweapon);
	if (wa != game->AM_NOAMMO)
		drawnum(r, ST_AMMOX, ST_AMMOY, 3, p.ammo[wa], tallnum, tallw);

	# health
	rdrawpatch(r, ST_HEALTHX, ST_HEALTHY, tallpct);
	drawnum(r, ST_HEALTHX, ST_HEALTHY, 3, p.health, tallnum, tallw);

	# armor
	rdrawpatch(r, ST_ARMORX, ST_ARMORY, tallpct);
	drawnum(r, ST_ARMORX, ST_ARMORY, 3, p.armorpoints, tallnum, tallw);

	# arms background + six weapon slots (gray # = not owned,
	# yellow # = owned; vanilla ST_ARMSX/Y grid)
	rdrawpatch(r, ST_ARMSBGX, ST_ARMSBGY, armsbg);
	for (i := 0; i < 6; i++) {
		own := 0;
		if (p.weaponowned[i + 1] != 0)
			own = 1;
		rdrawpatch(r, ST_ARMSX + (i % 3) * ST_ARMSXSPACE,
			ST_ARMSY + (i / 3) * ST_ARMSYSPACE, arms[i][own].d);
	}

	# face: vanilla draws the STFB background only for netgames
	# (player-color backdrop); single player shows the bar art.
	fi := faceindex;
	if (fi < 0)
		fi = 0;
	if (fi >= NUMFACES)
		fi = NUMFACES - 1;
	rdrawpatch(r, ST_FACESX, ST_FACESY, faces[fi].d);

	# keys (3 boxes: card 0-2 on top, skulls 3-5 replace them)
	for (i = 0; i < 3; i++) {
		ki := -1;
		if (p.cards[i] != 0)
			ki = i;
		if (p.cards[i + 3] != 0)
			ki = i + 3;
		if (ki >= 0)
			rdrawpatch(r, ST_KEY0X, ST_KEY0Y + i * 10, keys[ki].d);
	}

	# ammo counts: 4 small numbers + maxima (vanilla y order:
	# bullets, shells, cells(191), rockets(185))
	ys := array[] of {173, 179, 191, 185};
	for (i = 0; i < 4; i++) {
		drawnum(r, ST_AMMO0X, ys[i], 3, p.ammo[i], shortnum, shortw);
		drawnum(r, ST_MAXAMMO0X, ys[i], 3, p.maxammo[i],
			shortnum, shortw);
	}
}
