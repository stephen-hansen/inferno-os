implement Wi;
include "sys.m";
	sys: Sys;
include "wad.m";
	wad: Wad;
	File: import wad;
include "rend.m";
	rend: Rend;
	Renderer: import rend;
include "map.m";
	mapm: Map;
include "info.m";
	inf: Info;
	MobjInfo: import inf;
include "sound.m";
	sound: Sound;
include "game.m";
include "wi.m";

# single-player states (wi_stuff.c StatCount/ShowNextLoc/NoState)
ST_COUNT, ST_SHOWNEXT, ST_NO: con iota;
WI_TITLEY: con 2;
SHOWNEXTLEN: con 4 * 35;
SP_STATSX: con 50;
SP_STATSY: con 50;
SP_TIMEX: con 16;
SP_TIMEY: con 168;	# 200 - 32
NANIM: con 10;
ANIMN: con 3;
ANIMPERIOD: con 11;	# TICRATE/3, integer like vanilla C

Animw: adt {
	typ, period, nanims, x, y, ctr, nexttic: int;
};

# episode-0 level nodes (wi_stuff.c lnodes[0]) and map anims
# (epsd0animinfo); built once in init
lnodex, lnodey: array of int;
animx, animy: array of int;

# per-intermission state (vanilla wbstartstruct subset + counters)
w_epsd, w_last, w_next: int;
w_maxkills, w_maxitems, w_maxsecret: int;
w_didsecret: int;
p_skills, p_sitems, p_ssecret: int;
p_stime, w_partime: int;	# tics; displayed in seconds
state: int;
sp_state: int;
bcnt: int;			# never reset (vanilla global)
cnt, cnt_pause: int;
ckills, citems, csecret, ctime, cpar: int;
snl_pointeron: int;
acceleratestage: int;
attackdown, usedown: int;
wdone: int;
wfile: ref Wad->File;
background: array of byte;
lnames: array of array of byte;		# [9] WILV0i
num: array of array of byte;		# [10] WINUMd
percent, colon, minus, wi_finished, entering: array of byte;
kills, secret, items, timepatch, par, sucks: array of byte;
yah: array of array of byte;		# [2] WIURH0/1
splat: array of array of byte;		# [1] WISPLAT
anims: array of Animw;			# [NANIM] animated back
anp: array of array of array of byte;	# [NANIM][ANIMN] WIA0ji
mindex: int;				# own M_Random index into rndtable

getlump(name: string): array of byte
{
	fi := wfile.find(name);
	if (fi < 0) {
		sys->print("WI: missing lump %s\n", name);
		return nil;
	}
	(b, err) := wfile.read(fi);
	if (b == nil) {
		sys->print("WI: unreadable %s: %s\n", name, err);
		return nil;
	}
	return b;
}

# vanilla M_Random on the shared table with a private index
mrandom(): int
{
	mindex = (mindex + 1) & 16rff;
	return inf->rndtable[mindex];
}

init(w: ref Wad->File, snd: Sound): string
{
	if (sys == nil) {
		sys = load Sys Sys->PATH;
		if (sys == nil)
			return "can't load Sys";
	}
	wfile = w;
	if (wad == nil) {
		# File adt methods dispatch through this handle
		wad = load Wad Wad->PATH;
		if (wad == nil)
			return "can't load Wad module";
	}
	if (rend == nil) {
		rend = load Rend Rend->PATH;
		if (rend == nil)
			return "can't load Rend module";
	}
	if (sound == nil) {
		sound = snd;	# shared instance from doom.b (single mixer)
		if (sound == nil)
			return "no Sound module";
	}
	if (inf == nil) {
		inf = load Info Info->PATH;
		if (inf == nil)
			inf = load Info "info.dis";
		if (inf == nil)
			return "can't load Info module";
		ierr := inf->init();
		if (ierr != nil)
			return ierr;
	}
	mindex = 0;
	bcnt = 0;
	lnodex = array[] of { 185, 148, 69, 209, 116, 166, 71, 135, 71 };
	lnodey = array[] of { 164, 143, 122, 102, 89, 55, 56, 29, 24 };
	animx = array[] of { 224, 184, 112, 72, 88, 64, 192, 136, 80, 64 };
	animy = array[] of { 104, 160, 136, 112, 96, 48, 40, 16, 16, 24 };
	background = getlump("WIMAP0");
	if (background == nil)
		return "no WIMAP0";
	lnames = array[9] of array of byte;
	for (i := 0; i < 9; i++) {
		lnames[i] = getlump(sys->sprint("WILV0%d", i));
		if (lnames[i] == nil)
			return sys->sprint("no WILV0%d", i);
	}
	num = array[10] of array of byte;
	for (i = 0; i < 10; i++) {
		num[i] = getlump(sys->sprint("WINUM%d", i));
		if (num[i] == nil)
			return sys->sprint("no WINUM%d", i);
	}
	percent = getlump("WIPCNT");
	colon = getlump("WICOLON");
	minus = getlump("WIMINUS");
	wi_finished = getlump("WIF");
	entering = getlump("WIENTER");
	kills = getlump("WIOSTK");
	secret = getlump("WIOSTS");
	items = getlump("WIOSTI");
	timepatch = getlump("WITIME");
	par = getlump("WIPAR");
	sucks = getlump("WISUCKS");
	if (percent == nil || colon == nil || minus == nil ||
	    wi_finished == nil || entering == nil || kills == nil ||
	    secret == nil || items == nil || timepatch == nil ||
	    par == nil || sucks == nil)
		return "missing WI text patch";
	yah = array[2] of array of byte;
	yah[0] = getlump("WIURH0");
	yah[1] = getlump("WIURH1");
	if (yah[0] == nil || yah[1] == nil)
		return "missing WIURH";
	splat = array[1] of array of byte;
	splat[0] = getlump("WISPLAT");
	if (splat[0] == nil)
		return "missing WISPLAT";
	anims = array[NANIM] of Animw;
	anp = array[NANIM] of array of array of byte;
	digits := "0123456789";
	for (j := 0; j < NANIM; j++) {
		anims[j] = Animw(0, ANIMPERIOD, ANIMN,
			animx[j], animy[j], -1, 0);
		anp[j] = array[ANIMN] of array of byte;
		for (k := 0; k < ANIMN; k++) {
			# WIA0<j:02d><i:02d>, e.g. WIA00902
			nm := "WIA00" + digits[j:j+1] + "0" + digits[k:k+1];
			anp[j][k] = getlump(nm);
			if (anp[j][k] == nil)
				return sys->sprint("no %s", nm);
		}
	}
	return nil;
}

initanimatedback()
{
	for (i := 0; i < NANIM; i++) {
		a := anims[i];
		a.ctr = -1;
		a.nexttic = bcnt + 1 + mrandom() % a.period;
		anims[i] = a;
	}
}

updateanimatedback()
{
	for (i := 0; i < NANIM; i++) {
		a := anims[i];
		if (bcnt == a.nexttic) {
			if (a.ctr + 1 >= a.nanims)
				a.ctr = 0;
			else
				a.ctr = a.ctr + 1;
			anims[i].ctr = a.ctr;
			anims[i].nexttic = bcnt + a.period;
		}
	}
}

drawanimatedback(r: ref Rend->Renderer)
{
	for (i := 0; i < NANIM; i++) {
		if (anims[i].ctr >= 0)
			rend->rdrawpatch(r, anims[i].x, anims[i].y,
				anp[i][anims[i].ctr]);
	}
}

# vanilla WI_checkForAccelerate: BT_ATTACK/BT_USE rising edges
checkaccelerate(buttons: int)
{
	if ((buttons & Game->BT_ATTACK) != 0) {
		if (attackdown == 0)
			acceleratestage = 1;
		attackdown = 1;
	} else
		attackdown = 0;
	if ((buttons & Game->BT_USE) != 0) {
		if (usedown == 0)
			acceleratestage = 1;
		usedown = 1;
	} else
		usedown = 0;
}

# vanilla WI_drawNum: right-aligned, digits<0 = variable width,
# n==1994 draws nothing (returns 0)
drawnum(r: ref Rend->Renderer, x, y, n, digits: int): int
{
	fontw := rend->rpatchwidth(num[0]);
	temp := n;
	if (digits < 0) {
		if (n == 0)
			digits = 1;
		else {
			digits = 0;
			while (temp != 0) {
				temp /= 10;
				digits = digits + 1;
			}
		}
	}
	neg := 0;
	if (n < 0) {
		neg = 1;
		n = -n;
	}
	if (n == 1994)
		return 0;
	while (digits > 0) {
		digits = digits - 1;
		x -= fontw;
		rend->rdrawpatch(r, x, y, num[n % 10]);
		n /= 10;
	}
	if (neg != 0)
		rend->rdrawpatch(r, x - 8, y, minus);
	return x;
}

# vanilla WI_drawPercent
drawpercent(r: ref Rend->Renderer, x, y, p: int)
{
	if (p < 0)
		return;
	rend->rdrawpatch(r, x, y, percent);
	drawnum(r, x, y, p, -1);
}

# vanilla WI_drawTime (mm:ss with colons, "sucks" past 61:59)
drawtime(r: ref Rend->Renderer, x, y, t: int)
{
	if (t < 0)
		return;
	if (t <= 61 * 59) {
		div := 1;
		for (;;) {
			n := (t / div) % 60;
			x = drawnum(r, x, y, n, 2) - rend->rpatchwidth(colon);
			div *= 60;
			if (div == 60 || t / div != 0)
				rend->rdrawpatch(r, x, y, colon);
			if (t / div == 0)
				break;
		}
	} else
		rend->rdrawpatch(r, x - rend->rpatchwidth(sucks), y, sucks);
}

# vanilla WI_slamBackground
slambackground(r: ref Rend->Renderer)
{
	rend->rdrawpatch(r, 0, 0, background);
}

# vanilla WI_drawLF: "<Levelname> Finished!"
drawlf(r: ref Rend->Renderer)
{
	y := WI_TITLEY;
	ln := lnames[w_last];
	rend->rdrawpatch(r, (r.w - rend->rpatchwidth(ln)) / 2, y, ln);
	y += 5 * rend->rpatchheight(ln) / 4;
	rend->rdrawpatch(r, (r.w - rend->rpatchwidth(wi_finished)) / 2, y, wi_finished);
}

# vanilla WI_drawEL: "Entering <Levelname>"
drawel(r: ref Rend->Renderer)
{
	y := WI_TITLEY;
	rend->rdrawpatch(r, (r.w - rend->rpatchwidth(entering)) / 2, y, entering);
	ln := lnames[w_next];
	y += 5 * rend->rpatchheight(ln) / 4;
	rend->rdrawpatch(r, (r.w - rend->rpatchwidth(ln)) / 2, y, ln);
}

le16off(pd: array of byte, o: int): int
{
	if (o + 1 >= len pd)
		return 0;
	v := int pd[o] | int pd[o+1] << 8;
	if (v >= 16r8000)
		v -= 16r10000;
	return v;
}

# vanilla WI_drawOnLnode (shareware fit rule: strict < bounds)
drawonlnode(r: ref Rend->Renderer, n: int, c: array of array of byte)
{
	i := 0;
	fits := 0;
	for (;;) {
		if (i >= len c || c[i] == nil)
			break;
		left := lnodex[n] - le16off(c[i], 4);
		top := lnodey[n] - le16off(c[i], 6);
		right := left + le16off(c[i], 0);
		bottom := top + le16off(c[i], 2);
		if (left >= 0 && right < r.w && top >= 0 && bottom < r.h) {
			fits = 1;
			break;
		}
		i = i + 1;
		if (i >= 2)
			break;
	}
	if (fits != 0 && i < 2)
		rend->rdrawpatch(r, lnodex[n], lnodey[n], c[i]);
}

# vanilla WI_drawStats (single player)
drawstats(r: ref Rend->Renderer)
{
	lh := 3 * rend->rpatchheight(num[0]) / 2;
	slambackground(r);
	drawanimatedback(r);
	drawlf(r);
	rend->rdrawpatch(r, SP_STATSX, SP_STATSY, kills);
	drawpercent(r, r.w - SP_STATSX, SP_STATSY, ckills);
	rend->rdrawpatch(r, SP_STATSX, SP_STATSY + lh, items);
	drawpercent(r, r.w - SP_STATSX, SP_STATSY + lh, citems);
	rend->rdrawpatch(r, SP_STATSX, SP_STATSY + 2 * lh, secret);
	drawpercent(r, r.w - SP_STATSX, SP_STATSY + 2 * lh, csecret);
	rend->rdrawpatch(r, SP_TIMEX, SP_TIMEY, timepatch);
	drawtime(r, r.w / 2 - SP_TIMEX, SP_TIMEY, ctime);
	rend->rdrawpatch(r, r.w / 2 + SP_TIMEX, SP_TIMEY, par);
	drawtime(r, r.w - SP_TIMEX, SP_TIMEY, cpar);
}

# vanilla WI_drawShowNextLoc (shareware path)
drawshownextloc(r: ref Rend->Renderer)
{
	slambackground(r);
	drawanimatedback(r);
	last := w_last;
	if (w_last == 8)
		last = w_next - 1;
	for (i := 0; i <= last; i++)
		drawonlnode(r, i, splat);
	if (w_didsecret != 0)
		drawonlnode(r, 8, splat);
	if (snl_pointeron != 0)
		drawonlnode(r, w_next, yah);
	drawel(r);
}

pct(v, max: int): int
{
	if (max <= 0)
		return 0;
	return v * 100 / max;
}

# vanilla WI_updateStats (single player)
updatestats()
{
	updateanimatedback();
	if (acceleratestage != 0 && sp_state != 10) {
		acceleratestage = 0;
		ckills = pct(p_skills, w_maxkills);
		citems = pct(p_sitems, w_maxitems);
		csecret = pct(p_ssecret, w_maxsecret);
		ctime = p_stime;
		cpar = w_partime;
		sound->startsound(0, 0, sound->SFX_BAREXP);
		sp_state = 10;
	}
	if (sp_state == 2) {
		ckills = ckills + 2;
		if ((bcnt & 3) == 0)
			sound->startsound(0, 0, sound->SFX_PISTOL);
		if (ckills >= pct(p_skills, w_maxkills)) {
			ckills = pct(p_skills, w_maxkills);
			sound->startsound(0, 0, sound->SFX_BAREXP);
			sp_state = sp_state + 1;
		}
	} else if (sp_state == 4) {
		citems = citems + 2;
		if ((bcnt & 3) == 0)
			sound->startsound(0, 0, sound->SFX_PISTOL);
		if (citems >= pct(p_sitems, w_maxitems)) {
			citems = pct(p_sitems, w_maxitems);
			sound->startsound(0, 0, sound->SFX_BAREXP);
			sp_state = sp_state + 1;
		}
	} else if (sp_state == 6) {
		csecret = csecret + 2;
		if ((bcnt & 3) == 0)
			sound->startsound(0, 0, sound->SFX_PISTOL);
		if (csecret >= pct(p_ssecret, w_maxsecret)) {
			csecret = pct(p_ssecret, w_maxsecret);
			sound->startsound(0, 0, sound->SFX_BAREXP);
			sp_state = sp_state + 1;
		}
	} else if (sp_state == 8) {
		if ((bcnt & 3) == 0)
			sound->startsound(0, 0, sound->SFX_PISTOL);
		ctime = ctime + 3;
		if (ctime >= p_stime)
			ctime = p_stime;
		cpar = cpar + 3;
		if (cpar >= w_partime)
			cpar = w_partime;
		if (ctime >= p_stime && cpar >= w_partime) {
			sound->startsound(0, 0, sound->SFX_BAREXP);
			sp_state = sp_state + 1;
		}
	} else if (sp_state == 10) {
		if (acceleratestage != 0) {
			sound->startsound(0, 0, sound->SFX_SGCOCK);
			initshownextloc();
		}
	} else if ((sp_state & 1) != 0) {
		cnt_pause = cnt_pause - 1;
		if (cnt_pause == 0) {
			sp_state = sp_state + 1;
			cnt_pause = Game->TICRATE;
		}
	}
}

initshownextloc()
{
	state = ST_SHOWNEXT;
	acceleratestage = 0;
	cnt = SHOWNEXTLEN;
	initanimatedback();
}

initnostate()
{
	state = ST_NO;
	acceleratestage = 0;
	cnt = 10;
}

	ticker(buttons: int)
{
	bcnt = bcnt + 1;
	checkaccelerate(buttons);
	if (state == ST_COUNT)
		updatestats();
	else if (state == ST_SHOWNEXT) {
		updateanimatedback();
		cnt = cnt - 1;
		if (cnt == 0 || acceleratestage != 0)
			initnostate();
		else
			snl_pointeron = (cnt & 31) < 20;
	} else if (state == ST_NO) {
		updateanimatedback();
		cnt = cnt - 1;
		if (cnt == 0)
			wdone = 1;
	}
}

drawer(r: ref Rend->Renderer)
{
	if (state == ST_COUNT)
		drawstats(r);
	else {
		# NoState draws the map screen with pointer forced on
		if (state == ST_NO)
			snl_pointeron = 1;
		drawshownextloc(r);
	}
}

done(): int
{
	return wdone;
}

nextmap(): int
{
	return w_next + 1;
}

start(s: ref Game->Wistat, g: Game)
{
	w_epsd = s.epsd;
	w_last = s.last;
	w_next = s.next;
	w_maxkills = s.maxkills;
	w_maxitems = s.maxitems;
	w_maxsecret = s.maxsecret;
	p_skills = s.kills;
	p_sitems = s.items;
	p_ssecret = s.secrets;
	p_stime = s.stime / Game->TICRATE;
	w_partime = s.partime / Game->TICRATE;
	w_didsecret = s.didsecret;
	cp := g->consoleplayer();
	if (cp != nil) {
		attackdown = cp.attackdown;
		usedown = cp.usedown;
	} else {
		attackdown = 0;
		usedown = 0;
	}
	acceleratestage = 0;
	wdone = 0;
	state = ST_COUNT;
	sp_state = 1;
	ckills = -1;
	citems = -1;
	csecret = -1;
	ctime = -1;
	cpar = -1;
	cnt_pause = Game->TICRATE;
	snl_pointeron = 0;
	initanimatedback();
}
