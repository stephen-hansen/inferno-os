# Play simulation.  Reference: doomgeneric p_mobj.c p_map.c
# p_maputl.c p_user.c p_tick.c (GPL-2).  Collision walks every
# line/thing each check (no blockmap); P_SlideMove is a momentum
# stub; action routines and specials are no-op stubs for now.

implement Game;

include "sys.m";
	sys: Sys;
include "rend.m";
	rend: Rend;
include "wad.m";
	wad: Wad;
include "map.m";
	map: Map;
	Level: import map;
	Thing: import map;
include "info.m";
	inf: Info;
	MobjInfo: import inf;
include "game.m";

# collision temporaries (vanilla module globals in p_map.c)
tmthing: ref Mobj;
tmflags, tmx, tmy: int;
tmbbox: array of int;		# BOXTOP, BOXBOTTOM, BOXLEFT, BOXRIGHT
tmfloorz, tmceilingz, tmdropoffz: int;
floatok: int;
ceilingline: int;		# linedef index, -1 if none
opentop, openbottom, openrange, lowfloor: int;

init(): string
{
	if (sys == nil) {
		sys = load Sys Sys->PATH;
		if (sys == nil)
			return "can't load Sys";
	}
	if (inf == nil) {
		inf = load Info Info->PATH;
		if (inf == nil)
			inf = load Info "info.dis";
		if (inf == nil)
			return "can't load Info module";
		err := inf->init();
		if (err != nil)
			return err;
	}
	if (rend == nil) {
		rend = load Rend Rend->PATH;
		if (rend == nil)
			rend = load Rend "rend.dis";
		if (rend == nil)
			return "can't load Rend module";
	}
	if (map == nil) {		# ST_* constants via map->
		map = load Map Map->PATH;
		if (map == nil)
			map = load Map "map.dis";
		if (map == nil)
			return "can't load Map module";
	}
	if (tmbbox == nil)
		tmbbox = array[4] of int;
	mobjs = array[0] of ref Mobj;
	players = array[MAXPLAYERS] of ref Player;
	lvltime = 0;
	prndindex = 0;
	return nil;
}

prandom(): int
{
	prndindex = (prndindex + 1) & 255;
	return inf->rndtable[prndindex];
}

absi(a: int): int
{
	if (a < 0)
		return -a;
	return a;
}

approxdistance(x, y: int): int
{
	x = absi(x);
	y = absi(y);
	if (x < y)
		return x + y - (x >> 1);
	return y + x - (y >> 1);
}

# ---------------------------------------------------------------------------
# level setup / spawning
# ---------------------------------------------------------------------------

setuplevel(l: ref Map->Level, skill: int): string
{
	if (l == nil)
		return "setuplevel: nil map";
	lev = l;
	gameskill = skill;
	lvltime = 0;
	totalkills = 0;
	totalitems = 0;
	mobjs = array[0] of ref Mobj;
	for (i := 0; i < MAXPLAYERS; i++)
		players[i] = nil;

	for (i = 0; i < len l.things; i++)
		spawnmapthing(l.things[i]);
	return nil;
}

spawnmapthing(t: Thing)
{
	if (t.typ == 11)		# deathmatch start; ignored for now
		return;
	if (t.typ <= 0)
		return;
	if (t.typ <= 4) {		# player start
		spawnplayer(t);
		return;
	}

	# netgame is false: skip single-player-excluded things
	if ((t.options & MTF_NOTSINGLE) != 0)
		return;

	bit := 1 << (gameskill - 1);
	if (gameskill == SK_BABY)
		bit = MTF_EASY;
	else if (gameskill == SK_NIGHTMARE)
		bit = MTF_HARD;
	if ((t.options & bit) == 0)
		return;

	# find mobjinfo by doomednum
	i := 0;
	for (i = 0; i < inf->NUMMOBJTYPES; i++)
		if (t.typ == inf->mobjinfo[i].doomednum)
			break;
	if (i >= inf->NUMMOBJTYPES)
		return;			# unknown type: skip (vanilla I_Errors)

	z := ONFLOORZ;
	if ((inf->mobjinfo[i].flags & inf->MF_SPAWNCEILING) != 0)
		z = ONCEILINGZ;

	mo := spawnmobj(t.x, t.y, z, i);
	mo.spawnpoint = t;
	if (mo.tics > 0)
		mo.tics = 1 + (prandom() % mo.tics);
	if ((mo.flags & inf->MF_COUNTKILL) != 0)
		totalkills++;
	if ((mo.flags & inf->MF_COUNTITEM) != 0)
		totalitems++;
	mo.angle = ANG45 * (t.angle / 45);
	if ((t.options & MTF_AMBUSH) != 0)
		mo.flags = mo.flags | inf->MF_AMBUSH;
}

spawnplayer(t: Thing)
{
	i := t.typ - 1;
	if (i < 0 || i >= MAXPLAYERS)
		return;
	if (players[i] == nil) {
		np := ref Player(nil, Ticcmd(0, 0, 0, 0), PST_REBORN,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			nil, nil, nil, nil);
		players[i] = np;
	}
	p := players[i];
	if (p.playerstate == PST_REBORN)
		playerreborn(p);

	mo := spawnmobj(t.x, t.y, ONFLOORZ, inf->MT_PLAYER);
	if (t.typ > 1)
		mo.flags = mo.flags | ((t.typ - 1) << inf->MF_TRANSSHIFT);
	mo.angle = ANG45 * (t.angle / 45);
	mo.player = p;
	mo.health = p.health;
	p.mo = mo;
	p.playerstate = PST_LIVE;
	p.viewheight = VIEWHEIGHT;
}

playerreborn(p: ref Player)
{
	# minimal: G_PlayerReborn without dehacked/frag carry-over
	p.playerstate = PST_LIVE;
	p.health = 100;
	p.readyweapon = WP_PISTOL;
	p.pendingweapon = WP_PISTOL;
	p.weaponowned = array[NUMWEAPONS] of int;
	p.weaponowned[WP_FIST] = 1;
	p.weaponowned[WP_PISTOL] = 1;
	p.ammo = array[NUMAMMO] of int;
	p.ammo[AM_CLIP] = 50;
	p.maxammo = array[NUMAMMO] of int;
	p.maxammo[AM_CLIP] = 200;
	p.maxammo[AM_SHELL] = 50;
	p.maxammo[AM_CELL] = 300;
	p.maxammo[AM_MISL] = 50;
	p.frags = array[MAXPLAYERS] of int;
	p.usedown = 1;
	p.attackdown = 1;
	p.killcount = 0;
	p.itemcount = 0;
	p.secretcount = 0;
}

spawnmobj(x, y, z, typ: int): ref Mobj
{
	mi := inf->mobjinfo[typ];
	st := inf->states[mi.spawnstate];
	rl := 0;
	if (gameskill != SK_NIGHTMARE)
		rl = mi.reactiontime;
	mo := ref Mobj(typ, mi, x, y, 0, 0,
		0, 0, 0,
		mi.radius, mi.height, mi.flags, mi.spawnhealth,
		mi.spawnstate, st.sprite, st.frame, st.tics,
		rl, prandom() % MAXPLAYERS,
		Thing(0, 0, 0, 0, 0), nil, 0, 0,
		nil, nil, 0,
		0, 0, 0);

	setthingposition(mo);
	mo.floorz = mo.subsector.sector.floorheight;
	mo.ceilingz = mo.subsector.sector.ceilingheight;
	if (z == ONFLOORZ)
		mo.z = mo.floorz;
	else if (z == ONCEILINGZ)
		mo.z = mo.ceilingz - mo.info.height;
	else
		mo.z = z;

	n := len mobjs;
	nm := array[n + 1] of ref Mobj;
	if (n > 0)
		nm[0:] = mobjs;
	nm[n] = mo;
	mobjs = nm;
	return mo;
}

setthingposition(mo: ref Mobj)
{
	ss := lev.pointsubsector(mo.x, mo.y);
	if (ss == nil)
		fail("setthingposition: no subsector");
	mo.subsector = ss;
	# milestone 5: no sector thinglist / blockmap links
}

removemobj(mo: ref Mobj)
{
	mo.removed = 1;
	mo.state = inf->S_NULL;
}

# ---------------------------------------------------------------------------
# state / thinkers
# ---------------------------------------------------------------------------

setmobjstate(mo: ref Mobj, state: int): int
{
	s := state;
	for (;;) {
		if (s == inf->S_NULL) {
			mo.state = inf->S_NULL;
			removemobj(mo);
			return 0;
		}
		st := inf->states[s];
		mo.state = s;
		mo.tics = st.tics;
		mo.sprite = st.sprite;
		mo.frame = st.frame;
		doaction(mo, st.action);
		s = st.nextstate;
		if (mo.tics != 0)
			return 1;
	}
}

doaction(mo: ref Mobj, act: int)
{
	# milestone 5 stub: A_Look/A_Chase/weapon routines come with
	# the AI and psprite milestones; states still advance by tics.
	mo = mo;
	if (act == 0)
		return;
}

explodemissile(mo: ref Mobj)
{
	mo.momx = 0;
	mo.momy = 0;
	mo.momz = 0;
	setmobjstate(mo, mo.info.deathstate);
	mo.tics = mo.tics - (prandom() & 3);
	if (mo.tics < 1)
		mo.tics = 1;
	mo.flags = mo.flags & ~inf->MF_MISSILE;
}

mobjthinker(mo: ref Mobj)
{
	if (mo.momx != 0 || mo.momy != 0 || (mo.flags & inf->MF_SKULLFLY) != 0) {
		xymovement(mo);
		if (mo.removed)
			return;
	}
	if (mo.z != mo.floorz || mo.momz != 0) {
		zmovement(mo);
		if (mo.removed)
			return;
	}
	if (mo.tics != -1) {
		mo.tics = mo.tics - 1;
		if (mo.tics == 0) {
			if (!setmobjstate(mo, inf->states[mo.state].nextstate))
				return;
		}
	}
}

runthinkers()
{
	# snapshot the list: thinkers may spawn; removed are compacted
	n := len mobjs;
	if (n == 0)
		return;
	snap := array[n] of ref Mobj;
	snap[0:] = mobjs;
	for (i := 0; i < n; i++) {
		mo := snap[i];
		if (mo.removed)
			continue;
		mobjthinker(mo);
	}
	# compact removed (lazy unlink, vanilla P_RunThinkers free)
	kept := 0;
	for (i = 0; i < n; i++)
		if (!snap[i].removed)
			kept++;
	nm := array[kept] of ref Mobj;
	k := 0;
	for (i = 0; i < n; i++)
		if (!snap[i].removed) {
			nm[k] = snap[i];
			k++;
		}
	mobjs = nm;
}

# ---------------------------------------------------------------------------
# movement
# ---------------------------------------------------------------------------

thrust(p: ref Player, angle, move: int)
{
	a := (angle >> ANGLETOFINESHIFT) & FINEMASK;
	p.mo.momx = p.mo.momx + rend->fixedmul(move, inf->finesine[a + 2048]);
	p.mo.momy = p.mo.momy + rend->fixedmul(move, inf->finesine[a]);
}

moveplayer(p: ref Player)
{
	cmd := p.cmd;
	p.mo.angle = p.mo.angle + (cmd.angleturn << 16);

	onground := p.mo.z <= p.mo.floorz;
	if (cmd.forwardmove != 0 && onground)
		thrust(p, p.mo.angle, cmd.forwardmove * 2048);
	if (cmd.sidemove != 0 && onground)
		thrust(p, p.mo.angle - ANG90, cmd.sidemove * 2048);

	if ((cmd.forwardmove != 0 || cmd.sidemove != 0) &&
	    p.mo.state == inf->S_PLAY)
		setmobjstate(p.mo, inf->S_PLAY_RUN1);
}

calcheight(p: ref Player)
{
	bob := rend->fixedmul(p.mo.momx, p.mo.momx) +
		rend->fixedmul(p.mo.momy, p.mo.momy);
	bob = bob >> 2;
	if (bob > MAXBOB)
		bob = MAXBOB;
	p.bob = bob;

	onground := p.mo.z <= p.mo.floorz;
	if ((p.cheats & CF_NOMOMENTUM) != 0 || !onground) {
		p.viewz = p.mo.z + VIEWHEIGHT;
		if (p.viewz > p.mo.ceilingz - 4 * FRACUNIT)
			p.viewz = p.mo.ceilingz - 4 * FRACUNIT;
		p.viewz = p.mo.z + p.viewheight;
		return;
	}

	angle := ((FINEANGLES / 20) * lvltime) & FINEMASK;
	bob = rend->fixedmul(p.bob / 2, inf->finesine[angle]);

	if (p.playerstate == PST_LIVE) {
		p.viewheight = p.viewheight + p.deltaviewheight;
		if (p.viewheight > VIEWHEIGHT) {
			p.viewheight = VIEWHEIGHT;
			p.deltaviewheight = 0;
		}
		if (p.viewheight < VIEWHEIGHT / 2) {
			p.viewheight = VIEWHEIGHT / 2;
			if (p.deltaviewheight <= 0)
				p.deltaviewheight = 1;
		}
		if (p.deltaviewheight != 0) {
			p.deltaviewheight = p.deltaviewheight + FRACUNIT / 4;
			if (p.deltaviewheight == 0)
				p.deltaviewheight = 1;
		}
	}
	p.viewz = p.mo.z + p.viewheight + bob;
	if (p.viewz > p.mo.ceilingz - 4 * FRACUNIT)
		p.viewz = p.mo.ceilingz - 4 * FRACUNIT;
}

deaththink(p: ref Player)
{
	if (p.viewheight > 6 * FRACUNIT)
		p.viewheight = p.viewheight - FRACUNIT;
	if (p.viewheight < 6 * FRACUNIT)
		p.viewheight = 6 * FRACUNIT;
	p.deltaviewheight = 0;
	calcheight(p);
	# use-button respawn / messaging later
}

playerthink(p: ref Player)
{
	if ((p.cheats & CF_NOCLIP) != 0)
		p.mo.flags = p.mo.flags | inf->MF_NOCLIP;
	else
		p.mo.flags = p.mo.flags & ~inf->MF_NOCLIP;

	if ((p.mo.flags & inf->MF_JUSTATTACKED) != 0) {
		p.cmd.angleturn = 0;
		p.cmd.forwardmove = 16rc800 / 512;
		p.cmd.sidemove = 0;
		p.mo.flags = p.mo.flags & ~inf->MF_JUSTATTACKED;
	}

	if (p.playerstate == PST_DEAD) {
		deaththink(p);
		return;
	}

	if (p.mo.reactiontime != 0)
		p.mo.reactiontime = p.mo.reactiontime - 1;
	else
		moveplayer(p);

	calcheight(p);

	# P_PlayerInSpecialSector / weapon change / use lines: later
}

xymovement(mo: ref Mobj)
{
	if (mo.momx == 0 && mo.momy == 0) {
		if ((mo.flags & inf->MF_SKULLFLY) != 0) {
			mo.flags = mo.flags & ~inf->MF_SKULLFLY;
			mo.momx = 0;
			mo.momy = 0;
			mo.momz = 0;
			setmobjstate(mo, mo.info.spawnstate);
		}
		return;
	}

	if (mo.momx > MAXMOVE)
		mo.momx = MAXMOVE;
	else if (mo.momx < -MAXMOVE)
		mo.momx = -MAXMOVE;
	if (mo.momy > MAXMOVE)
		mo.momy = MAXMOVE;
	else if (mo.momy < -MAXMOVE)
		mo.momy = -MAXMOVE;

	xmove := mo.momx;
	ymove := mo.momy;
	for (;;) {
		ptryx := 0;
		ptryy := 0;
		if (xmove > MAXMOVE / 2 || ymove > MAXMOVE / 2) {
			ptryx = mo.x + xmove / 2;
			ptryy = mo.y + ymove / 2;
			xmove = xmove >> 1;
			ymove = ymove >> 1;
		} else {
			ptryx = mo.x + xmove;
			ptryy = mo.y + ymove;
			xmove = 0;
			ymove = 0;
		}
		if (!trymove(mo, ptryx, ptryy)) {
			if (mo.player != nil) {
				slidemove(mo);
			} else if ((mo.flags & inf->MF_MISSILE) != 0) {
				# sky hack skipped: no skyflatnum yet
				explodemissile(mo);
				return;
			} else {
				mo.momx = 0;
				mo.momy = 0;
			}
		}
		if (xmove == 0 && ymove == 0)
			break;
	}

	if (mo.player != nil && (mo.player.cheats & CF_NOMOMENTUM) != 0) {
		mo.momx = 0;
		mo.momy = 0;
		return;
	}
	if ((mo.flags & (inf->MF_MISSILE | inf->MF_SKULLFLY)) != 0)
		return;
	if (mo.z > mo.floorz)
		return;
	if ((mo.flags & inf->MF_CORPSE) != 0) {
		if (mo.momx > FRACUNIT / 4 || mo.momx < -FRACUNIT / 4 ||
		    mo.momy > FRACUNIT / 4 || mo.momy < -FRACUNIT / 4) {
			if (mo.floorz != mo.subsector.sector.floorheight)
				return;
		}
	}
	if (mo.momx > -STOPSPEED && mo.momx < STOPSPEED &&
	    mo.momy > -STOPSPEED && mo.momy < STOPSPEED &&
	    (mo.player == nil ||
	     (mo.player.cmd.forwardmove == 0 && mo.player.cmd.sidemove == 0))) {
		if (mo.player != nil) {
			st := mo.player.mo.state;
			if (st >= inf->S_PLAY_RUN1 && st < inf->S_PLAY_RUN1 + 4)
				setmobjstate(mo.player.mo, inf->S_PLAY);
		}
		mo.momx = 0;
		mo.momy = 0;
	} else {
		mo.momx = rend->fixedmul(mo.momx, FRICTION);
		mo.momy = rend->fixedmul(mo.momy, FRICTION);
	}
}

zmovement(mo: ref Mobj)
{
	if (mo.player != nil && mo.z < mo.floorz) {
		mo.player.viewheight = mo.player.viewheight - (mo.floorz - mo.z);
		mo.player.deltaviewheight = (VIEWHEIGHT - mo.player.viewheight) >> 3;
	}

	mo.z = mo.z + mo.momz;

	# float-to-target skipped (no floaters with targets yet)

	if (mo.z <= mo.floorz) {
		if (mo.momz < 0) {
			if (mo.player != nil && mo.momz < -GRAVITY * 8)
				mo.player.deltaviewheight = mo.momz >> 3;
			mo.momz = 0;
		}
		mo.z = mo.floorz;
		if ((mo.flags & inf->MF_MISSILE) != 0 &&
		    (mo.flags & inf->MF_NOCLIP) == 0) {
			explodemissile(mo);
			return;
		}
	} else if ((mo.flags & inf->MF_NOGRAVITY) == 0) {
		if (mo.momz == 0)
			mo.momz = -GRAVITY * 2;
		else
			mo.momz = mo.momz - GRAVITY;
	}

	if (mo.z + mo.height > mo.ceilingz) {
		if (mo.momz > 0)
			mo.momz = 0;
		mo.z = mo.ceilingz - mo.height;
		if ((mo.flags & inf->MF_MISSILE) != 0 &&
		    (mo.flags & inf->MF_NOCLIP) == 0) {
			explodemissile(mo);
			return;
		}
	}
}

# milestone 5: no intercepts yet; stop dead instead of sliding
slidemove(mo: ref Mobj)
{
	mo.momx = 0;
	mo.momy = 0;
}

# ---------------------------------------------------------------------------
# collision (brute force over all lines / mobjs)
# ---------------------------------------------------------------------------

pointonlineside(x, y, n: int): int
{
	ld := lev.lines[n];
	v1 := lev.vertices[ld.v1];
	if (ld.dx == 0) {
		if (x <= v1.x)
			return ld.dy > 0;
		return ld.dy < 0;
	}
	if (ld.dy == 0) {
		if (y <= v1.y)
			return ld.dx < 0;
		return ld.dx > 0;
	}
	dx := x - v1.x;
	dy := y - v1.y;
	left := rend->fixedmul(ld.dy >> 16, dx);
	right := rend->fixedmul(dy, ld.dx >> 16);
	if (right < left)
		return 0;
	return 1;
}

boxonlineside(box: array of int, n: int): int
{
	ld := lev.lines[n];
	v1 := lev.vertices[ld.v1];
	p1 := 0;
	p2 := 0;
	st := ld.slopetype;
	if (st == map->ST_HORIZONTAL) {
		p1 = box[0] > v1.y;
		p2 = box[1] > v1.y;
		if (ld.dx < 0) {
			p1 = p1 ^ 1;
			p2 = p2 ^ 1;
		}
	} else if (st == map->ST_VERTICAL) {
		p1 = box[2] < v1.x;
		p2 = box[3] < v1.x;
		if (ld.dy < 0) {
			p1 = p1 ^ 1;
			p2 = p2 ^ 1;
		}
	} else if (st == map->ST_POSITIVE) {
		p1 = pointonlineside(box[3], box[0], n);	# LEFT, TOP
		p2 = pointonlineside(box[2], box[1], n);	# RIGHT, BOTTOM
	} else {
		p1 = pointonlineside(box[2], box[0], n);	# RIGHT, TOP
		p2 = pointonlineside(box[3], box[1], n);	# LEFT, BOTTOM
	}
	if (p1 == p2)
		return p1;
	return -1;
}

lineopening(n: int)
{
	ld := lev.lines[n];
	if (ld.sides[1] == nil) {		# single sided
		openrange = 0;
		return;
	}
	front := ld.frontsector;
	back := ld.backsector;
	if (front.ceilingheight < back.ceilingheight)
		opentop = front.ceilingheight;
	else
		opentop = back.ceilingheight;
	if (front.floorheight > back.floorheight) {
		openbottom = front.floorheight;
		lowfloor = back.floorheight;
	} else {
		openbottom = back.floorheight;
		lowfloor = front.floorheight;
	}
	openrange = opentop - openbottom;
}

pitcheckline(n: int): int
{
	ld := lev.lines[n];
	if (tmbbox[2] <= ld.bbox[2] ||		# RIGHT <= LEFT
	    tmbbox[3] >= ld.bbox[3] ||		# LEFT >= RIGHT
	    tmbbox[0] <= ld.bbox[1] ||		# TOP <= BOTTOM
	    tmbbox[1] >= ld.bbox[0])		# BOTTOM >= TOP
		return 1;
	if (boxonlineside(tmbbox, n) != -1)
		return 1;

	if (ld.backsector == nil)
		return 0;			# one sided

	if ((tmflags & inf->MF_MISSILE) == 0) {
		if ((ld.flags & ML_BLOCKING) != 0)
			return 0;
		if (tmthing.player == nil && (ld.flags & ML_BLOCKMONSTERS) != 0)
			return 0;
	}

	lineopening(n);
	if (opentop < tmceilingz) {
		tmceilingz = opentop;
		ceilingline = n;
	}
	if (openbottom > tmfloorz)
		tmfloorz = openbottom;
	if (lowfloor < tmdropoffz)
		tmdropoffz = lowfloor;
	# special lines / spechit: later milestone
	return 1;
}

pitcheckthing(thing: ref Mobj): int
{
	if ((thing.flags & (inf->MF_SOLID | inf->MF_SPECIAL | inf->MF_SHOOTABLE)) == 0)
		return 1;
	blockdist := thing.radius + tmthing.radius;
	if (absi(thing.x - tmx) >= blockdist ||
	    absi(thing.y - tmy) >= blockdist)
		return 1;
	if (thing == tmthing)
		return 1;
	# skullfly / missile / special pickup: not reachable in m5
	return (thing.flags & inf->MF_SOLID) == 0;
}

checkposition(thing: ref Mobj, x, y: int): int
{
	tmthing = thing;
	tmflags = thing.flags;
	tmx = x;
	tmy = y;
	tmbbox[0] = y + thing.radius;		# BOXTOP
	tmbbox[1] = y - thing.radius;		# BOXBOTTOM
	tmbbox[2] = x + thing.radius;		# BOXRIGHT
	tmbbox[3] = x - thing.radius;		# BOXLEFT

	ss := lev.pointsubsector(x, y);
	if (ss == nil)
		fail("checkposition: no subsector");
	ceilingline = -1;
	tmfloorz = ss.sector.floorheight;
	tmdropoffz = tmfloorz;
	tmceilingz = ss.sector.ceilingheight;

	if ((tmflags & inf->MF_NOCLIP) != 0)
		return 1;

	for (i := 0; i < len mobjs; i++)
		if (!pitcheckthing(mobjs[i]))
			return 0;
	for (i = 0; i < len lev.lines; i++)
		if (!pitcheckline(i))
			return 0;
	return 1;
}

trymove(mo: ref Mobj, x, y: int): int
{
	floatok = 0;
	if (!checkposition(mo, x, y))
		return 0;
	if ((mo.flags & inf->MF_NOCLIP) == 0) {
		if (tmceilingz - tmfloorz < mo.height)
			return 0;
		floatok = 1;
		if ((mo.flags & inf->MF_TELEPORT) == 0 &&
		    tmceilingz - mo.z < mo.height)
			return 0;
		if ((mo.flags & inf->MF_TELEPORT) == 0 &&
		    tmfloorz - mo.z > 24 * FRACUNIT)
			return 0;
		if ((mo.flags & (inf->MF_DROPOFF | inf->MF_FLOAT)) == 0 &&
		    tmfloorz - tmdropoffz > 24 * FRACUNIT)
			return 0;
	}
	mo.floorz = tmfloorz;
	mo.ceilingz = tmceilingz;
	mo.x = x;
	mo.y = y;
	setthingposition(mo);
	# crossed special lines: later
	return 1;
}

# ---------------------------------------------------------------------------
# tic loop
# ---------------------------------------------------------------------------

ticker()
{
	for (i := 0; i < MAXPLAYERS; i++) {
		p := players[i];
		if (p != nil && p.mo != nil)
			playerthink(p);
	}
	runthinkers();
	# P_UpdateSpecials / P_RespawnSpecials: later
	lvltime = lvltime + 1;
}

runtics(n: int)
{
	for (i := 0; i < n; i++)
		ticker();
}

setcmd(forwardmove, sidemove, angleturn, buttons: int)
{
	if (players[0] == nil)
		fail("setcmd: no player 0");
	players[0].cmd = Ticcmd(forwardmove, sidemove, angleturn, buttons);
}

nummobjs(): int
{
	return len mobjs;
}

consoleplayer(): ref Player
{
	return players[0];
}

getleveltime(): int
{
	return lvltime;
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "game: %s\n", s);
	raise "fail:error";
}
