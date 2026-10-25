# Automap (milestone 20): am_map.c, single-player path.
#
# Vanilla draws the automap as untextured Bresenham lines straight
# into the 320x168 view area of the frame buffer (AM_clipMline +
# AM_drawFline), with the status bar and HUD messages still drawn on
# top afterwards.  Line colors encode geometry: solid walls red,
# floor-height changes brown, ceiling-height changes yellow,
# two-sided gray (only when cheating), secret doors red/pink,
# teleporters brighter red, explored-but-invisible/all-map gray.
# Lines become ML_MAPPED when the world renderer stores their wall
# range (r_segs.c); the all-map power shows every non-hidden line
# gray.  The mark key stores AMMNUM0..9 patches; iddt (M25) cycles
# all-lines and things.  The level-title HUD line shows while this
# module is active (hu.setautomap, wired by doom.b).
#
# Reference: doomgeneric am_map.c (GPL-2).

implement Am;

include "sys.m";
include "wad.m";
	File: import wad;
include "rend.m";
	Renderer: import rend;
include "map.m";
include "info.m";
	inf: Info;
	MobjInfo: import inf;
include "sound.m";
include "game.m";
include "am.m";

sys: Sys;
wad: Wad;
rend: Rend;
game: Game;
lev: ref Map->Level;
plr: ref Game->Player;

# Limbo rejects `array of byte` as an allocation element type
Patch: adt {
	d:	array of byte;
};

# am_map.c color bands (full-screen palette indices)
REDS:		con 256 - 5*16;		# 176
REDRANGE:	con 16;
GREENS:		con 7*16;		# 112
GREENRANGE:	con 16;
GRAYS:		con 6*16;		# 96
GRAYSRANGE:	con 16;
BROWNS:		con 4*16;		# 64
BROWNRANGE:	con 16;
YELLOWS:	con 256 - 32 + 7;	# 231
YELLOWRANGE:	con 1;
BLACK:		con 0;
WHITE:		con 256 - 47;		# 209
BACKGROUND:	con BLACK;
YOURCOLORS:	con WHITE;
YOURRANGE:	con 0;
WALLCOLORS:	con REDS;
WALLRANGE:	con REDRANGE;
TSWALLCOLORS:	con GRAYS;
TSWALLRANGE:	con GRAYSRANGE;
FDWALLCOLORS:	con BROWNS;
FDWALLRANGE:	con BROWNRANGE;
CDWALLCOLORS:	con YELLOWS;
CDWALLRANGE:	con YELLOWRANGE;
THINGCOLORS:	con GREENS;
THINGRANGE:	con GREENRANGE;
SECRETWALLCOLORS: con WALLCOLORS;
SECRETWALLRANGE: con WALLRANGE;
GRIDCOLORS:	con GRAYS + GRAYSRANGE/2;	# 104
GRIDRANGE:	con 0;
XHAIRCOLORS:	con GRAYS;

# drawing stuff (am_map.c)
AM_NUMMARKPOINTS: con 10;
INITSCALEMTOF:	con 13107;	# (int)(.2*FRACUNIT)
F_PANINC:	con 4;		# fb pixels per tic while panning
M_ZOOMIN:	con 66846;	# (int)(1.02*FRACUNIT)
M_ZOOMOUT:	con 64250;	# (int)(FRACUNIT/1.02)
FRACUNIT:	con 65536;
FRACBITS:	con 16;
INTMAX:		con 16r7FFFFFFF;
PLAYERRADIUS:	con 16*FRACUNIT;
R_ADT:		con (8*PLAYERRADIUS)/7;	# player-arrow radius

# clip outcodes (am_map.c AM_clipMline)
LEFT:	con 1;
RIGHT:	con 2;
BOTTOM:	con 4;
TOP:	con 8;

# vanilla vector graphics, as flat (a.x,a.y,b.x,b.y) tables.  Values
# are the C integer expressions, truncating divisions included.
player_arrow := array[] of {
	-R_ADT+R_ADT/8, 0,	R_ADT, 0,
	R_ADT, 0,	R_ADT-R_ADT/2, R_ADT/4,
	R_ADT, 0,	R_ADT-R_ADT/2, -R_ADT/4,
	-R_ADT+R_ADT/8, 0,	-R_ADT-R_ADT/8, R_ADT/4,
	-R_ADT+R_ADT/8, 0,	-R_ADT-R_ADT/8, -R_ADT/4,
	-R_ADT+3*R_ADT/8, 0,	-R_ADT+R_ADT/8, R_ADT/4,
	-R_ADT+3*R_ADT/8, 0,	-R_ADT+R_ADT/8, -R_ADT/4,
};

cheat_player_arrow := array[] of {
	-R_ADT+R_ADT/8, 0,	R_ADT, 0,
	R_ADT, 0,	R_ADT-R_ADT/2, R_ADT/6,
	R_ADT, 0,	R_ADT-R_ADT/2, -R_ADT/6,
	-R_ADT+R_ADT/8, 0,	-R_ADT-R_ADT/8, R_ADT/6,
	-R_ADT+R_ADT/8, 0,	-R_ADT-R_ADT/8, -R_ADT/6,
	-R_ADT+3*R_ADT/8, 0,	-R_ADT+R_ADT/8, R_ADT/6,
	-R_ADT+3*R_ADT/8, 0,	-R_ADT+R_ADT/8, -R_ADT/6,
	-R_ADT/2, 0,	-R_ADT/2, -R_ADT/6,
	-R_ADT/2, -R_ADT/6,	-R_ADT/2+R_ADT/6, -R_ADT/6,
	-R_ADT/2+R_ADT/6, -R_ADT/6,	-R_ADT/2+R_ADT/6, R_ADT/4,
	-R_ADT/6, 0,	-R_ADT/6, -R_ADT/6,
	-R_ADT/6, -R_ADT/6,	0, -R_ADT/6,
	0, -R_ADT/6,	0, R_ADT/4,
	R_ADT/6, R_ADT/4,	R_ADT/6, -R_ADT/7,
	R_ADT/6, -R_ADT/7,	R_ADT/6+R_ADT/32, -R_ADT/7-R_ADT/32,
	R_ADT/6+R_ADT/32, -R_ADT/7-R_ADT/32, R_ADT/6+R_ADT/10, -R_ADT/7,
};

# (fixed_t)(-.5*FRACUNIT), (fixed_t)(-.7*FRACUNIT), R, truncated
# like the C casts (am_map.c thintriangle_guy, drawn scaled 16x)
thintriangle_guy := array[] of {
	-32768, -45875,	65536, 0,
	65536, 0,	-32768, 45875,
	-32768, 45875,	-32768, -45875,
};

# state (am_map.c statics)
automapactive:	int;
stopped:	int;
grid:		int;
cheating:	int;
followplayer:	int;
bigstate:	int;
lightlev:	int;
amclock:	int;

f_x, f_y:	int;
f_w, f_h:	int;

m_panx, m_pany:	int;
mtof_zoommul:	int;
ftom_zoommul:	int;

m_x, m_y:	int;
m_x2, m_y2:	int;
m_w, m_h:	int;

min_x, min_y:	int;
max_x, max_y:	int;
max_w, max_h:	int;
min_w, min_h:	int;
min_scale_mtof:	int;
max_scale_mtof:	int;

old_m_w, old_m_h:	int;
old_m_x, old_m_y:	int;
f_oldlocx:	int;
f_oldlocy:	int;

scale_mtof:	int;
scale_ftom:	int;

marknums:	array of Patch;
markx, marky:	array of int;
markpointnum:	int;

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

init(w: ref Wad->File, g: Game): string
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
	inf = load Info Info->PATH;
	if (inf == nil)
		inf = load Info "info.dis";
	if (inf == nil)
		return "can't load Info module";
	ierr := inf->init();
	if (ierr != nil)
		return ierr;
	game = g;

	marknums = array[AM_NUMMARKPOINTS] of Patch;
	for (i := 0; i < AM_NUMMARKPOINTS; i++)
		marknums[i] = Patch(getpatch(w, sys->sprint("AMMNUM%d", i)));
	markx = array[AM_NUMMARKPOINTS] of int;
	marky = array[AM_NUMMARKPOINTS] of int;
	clearmarks();

	automapactive = 0;
	stopped = 1;
	grid = 0;
	cheating = 0;
	followplayer = 1;
	bigstate = 0;
	lightlev = 0;
	scale_mtof = INITSCALEMTOF;
	return nil;
}

fmul(a, b: int): int
{
	return rend->fixedmul(a, b);
}

fdiv(a, b: int): int
{
	return rend->fixeddiv(a, b);
}

# am_map.c coordinate transforms (f_w/f_h fixed by the 320-wide view)
ftom(x: int): int
{
	return fmul(x << 16, scale_ftom);
}

mtof(x: int): int
{
	return fmul(x, scale_mtof) >> 16;
}

cxmtof(x: int): int
{
	return f_x + mtof(x - m_x);
}

cymtof(y: int): int
{
	return f_y + (f_h - mtof(y - m_y));
}

clearmarks()
{
	for (i := 0; i < AM_NUMMARKPOINTS; i++)
		markx[i] = -1;
	markpointnum = 0;
}

addmark()
{
	markx[markpointnum] = m_x + m_w/2;
	marky[markpointnum] = m_y + m_h/2;
	markpointnum = (markpointnum + 1) % AM_NUMMARKPOINTS;
}

# vanilla AM_findMinMaxBoundaries, including its else-if quirk
# (a coordinate can only update max_x when it did not update min_x)
findminmax()
{
	min_x = min_y = INTMAX;
	max_x = max_y = -INTMAX;
	for (i := 0; i < len lev.vertices; i++) {
		if (lev.vertices[i].x < min_x)
			min_x = lev.vertices[i].x;
		else if (lev.vertices[i].x > max_x)
			max_x = lev.vertices[i].x;
		if (lev.vertices[i].y < min_y)
			min_y = lev.vertices[i].y;
		else if (lev.vertices[i].y > max_y)
			max_y = lev.vertices[i].y;
	}
	max_w = max_x - min_x;
	max_h = max_y - min_y;
	min_w = 2*PLAYERRADIUS;
	min_h = 2*PLAYERRADIUS;
	a := fdiv(f_w << 16, max_w);
	b := fdiv(f_h << 16, max_h);
	min_scale_mtof = a;
	if (b < a)
		min_scale_mtof = b;
	max_scale_mtof = fdiv(f_h << 16, 2*PLAYERRADIUS);
}

setlevel(l: ref Map->Level)
{
	lev = l;
	if (game != nil)
		plr = game->consoleplayer();

	f_x = 0;
	f_y = 0;
	f_w = 320;
	f_h = 168;
	clearmarks();
	findminmax();
	# vanilla AM_LevelInit: start zoomed out a bit past the whole map
	scale_mtof = fdiv(min_scale_mtof, 45875);	# 0.7*FRACUNIT
	if (scale_mtof > max_scale_mtof)
		scale_mtof = min_scale_mtof;
	scale_ftom = fdiv(FRACUNIT, scale_mtof);
}

activatenewscale()
{
	m_x += m_w/2;
	m_y += m_h/2;
	m_w = ftom(f_w);
	m_h = ftom(f_h);
	m_x -= m_w/2;
	m_y -= m_h/2;
	m_x2 = m_x + m_w;
	m_y2 = m_y + m_h;
}

savescaleandloc()
{
	old_m_x = m_x;
	old_m_y = m_y;
	old_m_w = m_w;
	old_m_h = m_h;
}

restorescaleandloc()
{
	m_w = old_m_w;
	m_h = old_m_h;
	if (followplayer == 0) {
		m_x = old_m_x;
		m_y = old_m_y;
	} else if (plr != nil && plr.mo != nil) {
		m_x = plr.mo.x - m_w/2;
		m_y = plr.mo.y - m_h/2;
	}
	m_x2 = m_x + m_w;
	m_y2 = m_y + m_h;
	scale_mtof = fdiv(f_w << 16, m_w);
	scale_ftom = fdiv(FRACUNIT, scale_mtof);
}

minoutwindowscale()
{
	scale_mtof = min_scale_mtof;
	scale_ftom = fdiv(FRACUNIT, scale_mtof);
	activatenewscale();
}

maxoutwindowscale()
{
	scale_mtof = max_scale_mtof;
	scale_ftom = fdiv(FRACUNIT, scale_mtof);
	activatenewscale();
}

changewindowloc()
{
	if (m_panx != 0 || m_pany != 0) {
		followplayer = 0;
		f_oldlocx = INTMAX;
	}
	m_x += m_panx;
	m_y += m_pany;
	if (m_x + m_w/2 > max_x)
		m_x = max_x - m_w/2;
	else if (m_x + m_w/2 < min_x)
		m_x = min_x - m_w/2;
	if (m_y + m_h/2 > max_y)
		m_y = max_y - m_h/2;
	else if (m_y + m_h/2 < min_y)
		m_y = min_y - m_h/2;
	m_x2 = m_x + m_w;
	m_y2 = m_y + m_h;
}

changewindowscale()
{
	scale_mtof = fmul(scale_mtof, mtof_zoommul);
	scale_ftom = fdiv(FRACUNIT, scale_mtof);
	if (scale_mtof < min_scale_mtof)
		minoutwindowscale();
	else if (scale_mtof > max_scale_mtof)
		maxoutwindowscale();
	else
		activatenewscale();
}

dofollowplayer()
{
	if (plr == nil || plr.mo == nil)
		return;
	if (f_oldlocx != plr.mo.x || f_oldlocy != plr.mo.y) {
		m_x = ftom(mtof(plr.mo.x)) - m_w/2;
		m_y = ftom(mtof(plr.mo.y)) - m_h/2;
		m_x2 = m_x + m_w;
		m_y2 = m_y + m_h;
		f_oldlocx = plr.mo.x;
		f_oldlocy = plr.mo.y;
	}
}

# vanilla AM_initVariables: recenter on the player, keep the zoom
initvariables()
{
	automapactive = 1;
	f_oldlocx = INTMAX;
	f_oldlocy = INTMAX;
	amclock = 0;
	lightlev = 0;
	m_panx = 0;
	m_pany = 0;
	ftom_zoommul = FRACUNIT;
	mtof_zoommul = FRACUNIT;

	m_w = ftom(f_w);
	m_h = ftom(f_h);

	if (game != nil)
		plr = game->consoleplayer();
	if (plr == nil || plr.mo == nil)
		return;
	m_x = plr.mo.x - m_w/2;
	m_y = plr.mo.y - m_h/2;
	changewindowloc();

	savescaleandloc();
}

start()
{
	if (stopped == 0)
		stop();
	stopped = 0;
	initvariables();
}

stop()
{
	automapactive = 0;
	stopped = 1;
}

active(): int
{
	return automapactive;
}

following(): int
{
	return followplayer;
}

ticker()
{
	if (automapactive == 0)
		return;
	amclock++;
	if (followplayer != 0)
		dofollowplayer();
	if (ftom_zoommul != FRACUNIT)
		changewindowscale();
	if (m_panx != 0 || m_pany != 0)
		changewindowloc();
}

cheatcycle()
{
	cheating = (cheating + 1) % 3;
}

# --- drawing ---------------------------------------------------------

drawfline(r: ref Rend->Renderer, ax, ay, bx, by, color: int)
{
	# after clipping this cannot fire; vanilla guards with the same
	# check (and a debug print) to keep PUTDOT in bounds
	if (ax < 0 || ax >= f_w || ay < 0 || ay >= f_h ||
	    bx < 0 || bx >= f_w || by < 0 || by >= f_h)
		return;
	fb := r.fb8;
	dx := bx - ax;
	adx: int;
	sx: int;
	if (dx < 0) {
		adx = -2*dx;
		sx = -1;
	} else {
		adx = 2*dx;
		sx = 1;
	}
	dy := by - ay;
	ady: int;
	sy: int;
	if (dy < 0) {
		ady = -2*dy;
		sy = -1;
	} else {
		ady = 2*dy;
		sy = 1;
	}
	x := ax;
	y := ay;
	d: int;
	if (adx > ady) {
		d = ady - adx/2;
		for (;;) {
			fb[y*f_w+x] = byte color;
			if (x == bx)
				return;
			if (d >= 0) {
				y += sy;
				d -= adx;
			}
			x += sx;
			d += ady;
		}
	} else {
		d = adx - ady/2;
		for (;;) {
			fb[y*f_w+x] = byte color;
			if (y == by)
				return;
			if (d >= 0) {
				x += sx;
				d -= ady;
			}
			y += sy;
			d += adx;
		}
	}
}

outcode(x, y: int): int
{
	oc := 0;
	if (y < 0)
		oc |= TOP;
	else if (y >= f_h)
		oc |= BOTTOM;
	if (x < 0)
		oc |= LEFT;
	else if (x >= f_w)
		oc |= RIGHT;
	return oc;
}

# vanilla AM_clipMline: map coords in, frame-buffer coords out.
# Returns (1, x1, y1, x2, y2) when visible, else ok = 0.
clipmline(ax, ay, bx, by: int): (int, int, int, int, int)
{
	oc1 := 0;
	oc2 := 0;
	if (ay > m_y2)
		oc1 = TOP;
	else if (ay < m_y)
		oc1 = BOTTOM;
	if (by > m_y2)
		oc2 = TOP;
	else if (by < m_y)
		oc2 = BOTTOM;
	if ((oc1 & oc2) != 0)
		return (0, 0, 0, 0, 0);

	if (ax < m_x)
		oc1 |= LEFT;
	else if (ax > m_x2)
		oc1 |= RIGHT;
	if (bx < m_x)
		oc2 |= LEFT;
	else if (bx > m_x2)
		oc2 |= RIGHT;
	if ((oc1 & oc2) != 0)
		return (0, 0, 0, 0, 0);

	fx1 := cxmtof(ax);
	fy1 := cymtof(ay);
	fx2 := cxmtof(bx);
	fy2 := cymtof(by);

	oc1 = outcode(fx1, fy1);
	oc2 = outcode(fx2, fy2);
	if ((oc1 & oc2) != 0)
		return (0, 0, 0, 0, 0);

	while ((oc1 | oc2) != 0) {
		outside := 0;
		if (oc1 != 0)
			outside = oc1;
		else
			outside = oc2;

		tx, ty: int;
		if ((outside & TOP) != 0) {
			dy := fy1 - fy2;
			dx := fx2 - fx1;
			tx = fx1 + (dx*fy1)/dy;
			ty = 0;
		} else if ((outside & BOTTOM) != 0) {
			dy := fy1 - fy2;
			dx := fx2 - fx1;
			tx = fx1 + (dx*(fy1-f_h))/dy;
			ty = f_h - 1;
		} else if ((outside & RIGHT) != 0) {
			dy := fy2 - fy1;
			dx := fx2 - fx1;
			ty = fy1 + (dy*(f_w-1-fx1))/dx;
			tx = f_w - 1;
		} else if ((outside & LEFT) != 0) {
			dy := fy2 - fy1;
			dx := fx2 - fx1;
			ty = fy1 + (dy*(-fx1))/dx;
			tx = 0;
		} else {
			tx = 0;
			ty = 0;
		}

		if (outside == oc1) {
			fx1 = tx;
			fy1 = ty;
			oc1 = outcode(fx1, fy1);
		} else {
			fx2 = tx;
			fy2 = ty;
			oc2 = outcode(fx2, fy2);
		}
		if ((oc1 & oc2) != 0)
			return (0, 0, 0, 0, 0);
	}
	return (1, fx1, fy1, fx2, fy2);
}

drawmline(r: ref Rend->Renderer, ax, ay, bx, by, color: int)
{
	(ok, fx1, fy1, fx2, fy2) := clipmline(ax, ay, bx, by);
	if (ok != 0)
		drawfline(r, fx1, fy1, fx2, fy2, color);
}

# vanilla AM_rotate (angle is BAM)
rotate(x, y, a: int): (int, int)
{
	idx := (a >> 19) & 8191;
	sin := inf->finesine[idx];
	cos := inf->finesine[(idx + 2048) & 8191];
	tmpx := fmul(x, cos) - fmul(y, sin);
	ny := fmul(x, sin) + fmul(y, cos);
	return (tmpx, ny);
}

# vanilla AM_drawLineCharacter: optional scale, optional rotation,
# then translate to (x,y) and clip/draw each segment.
drawlinecharacter(r: ref Rend->Renderer, tab: array of int, nlines: int,
	scale, angle, color, x, y: int)
{
	for (i := 0; i < nlines; i++) {
		lax := tab[4*i];
		lay := tab[4*i+1];
		lbx := tab[4*i+2];
		lby := tab[4*i+3];
		if (scale != 0) {
			lax = fmul(scale, lax);
			lay = fmul(scale, lay);
			lbx = fmul(scale, lbx);
			lby = fmul(scale, lby);
		}
		if (angle != 0) {
			(lax, lay) = rotate(lax, lay, angle);
			(lbx, lby) = rotate(lbx, lby, angle);
		}
		drawmline(r, lax + x, lay + y, lbx + x, lby + y, color);
	}
}

drawgrid(r: ref Rend->Renderer, color: int)
{
	block := 128 << 16;	# MAPBLOCKUNITS<<FRACBITS
	start := m_x;
	rem := (start - lev.bmaporgx) % block;
	if (rem != 0)
		start += block - rem;
	end := m_x + m_w;
	for (x := start; x < end; x += block)
		drawmline(r, x, m_y, x, m_y + m_h, color);

	start = m_y;
	rem = (start - lev.bmaporgy) % block;
	if (rem != 0)
		start += block - rem;
	end = m_y + m_h;
	for (y := start; y < end; y += block)
		drawmline(r, m_x, y, m_x + m_w, y, color);
}

drawwalls(r: ref Rend->Renderer)
{
	for (i := 0; i < len lev.lines; i++) {
		ln := lev.lines[i];
		if (ln.v1 < 0 || ln.v1 >= len lev.vertices ||
		    ln.v2 < 0 || ln.v2 >= len lev.vertices)
			continue;
		v1 := lev.vertices[ln.v1];
		v2 := lev.vertices[ln.v2];
		if (cheating != 0 || (ln.flags & Game->ML_MAPPED) != 0) {
			if ((ln.flags & Game->ML_DONTDRAW) != 0 && cheating == 0)
				continue;
			if (ln.backsector == nil) {
				drawmline(r, v1.x, v1.y, v2.x, v2.y,
					WALLCOLORS + lightlev);
			} else if (ln.special == 39) {
				# teleporters
				drawmline(r, v1.x, v1.y, v2.x, v2.y,
					WALLCOLORS + WALLRANGE/2);
			} else if ((ln.flags & Game->ML_SECRET) != 0) {
				# secret door
				if (cheating != 0)
					drawmline(r, v1.x, v1.y, v2.x, v2.y,
						SECRETWALLCOLORS + lightlev);
				else
					drawmline(r, v1.x, v1.y, v2.x, v2.y,
						WALLCOLORS + lightlev);
			} else if (ln.frontsector != nil &&
				   ln.backsector.floorheight != ln.frontsector.floorheight) {
				# floor level change
				drawmline(r, v1.x, v1.y, v2.x, v2.y,
					FDWALLCOLORS + lightlev);
			} else if (ln.frontsector != nil &&
				   ln.backsector.ceilingheight != ln.frontsector.ceilingheight) {
				# ceiling level change
				drawmline(r, v1.x, v1.y, v2.x, v2.y,
					CDWALLCOLORS + lightlev);
			} else if (cheating != 0) {
				drawmline(r, v1.x, v1.y, v2.x, v2.y,
					TSWALLCOLORS + lightlev);
			}
		} else if (plr != nil && plr.powers[Game->PW_ALLMAP] != 0) {
			if ((ln.flags & Game->ML_DONTDRAW) == 0)
				drawmline(r, v1.x, v1.y, v2.x, v2.y, GRAYS+3);
		}
	}
}

drawplayers(r: ref Rend->Renderer)
{
	if (plr == nil || plr.mo == nil)
		return;
	if (cheating != 0)
		drawlinecharacter(r, cheat_player_arrow, 16, 0,
			plr.mo.angle, WHITE, plr.mo.x, plr.mo.y);
	else
		drawlinecharacter(r, player_arrow, 7, 0,
			plr.mo.angle, WHITE, plr.mo.x, plr.mo.y);
}

drawthings(r: ref Rend->Renderer)
{
	if (game == nil)
		return;
	for (i := 0; i < len game->mobjs; i++) {
		mo := game->mobjs[i];
		if (mo == nil || mo.removed != 0)
			continue;
		drawlinecharacter(r, thintriangle_guy, 3, 16 << 16,
			mo.angle, THINGCOLORS + lightlev, mo.x, mo.y);
	}
}

drawmarks(r: ref Rend->Renderer)
{
	for (i := 0; i < AM_NUMMARKPOINTS; i++) {
		if (markx[i] == -1)
			continue;
		fx := cxmtof(markx[i]);
		fy := cymtof(marky[i]);
		if (fx >= f_x && fx <= f_w - 5 && fy >= f_y && fy <= f_h - 6 &&
		    marknums[i].d != nil)
			r.drawpatch(fx, fy, marknums[i].d);
	}
}

drawer(r: ref Rend->Renderer)
{
	if (automapactive == 0)
		return;
	# AM_clearFB(BACKGROUND): vanilla clears the 320x168 view area;
	# clearing the full fb8 is equivalent here because the status
	# bar is fully redrawn right after (st.b does no diffing).
	r.clear(BACKGROUND);
	if (grid != 0)
		drawgrid(r, GRIDCOLORS);
	drawwalls(r);
	drawplayers(r);
	if (cheating == 2)
		drawthings(r);
	# AM_drawCrosshair: the single center pixel of the 320x168 area
	r.fb8[(f_w*(f_h+1))/2] = byte XHAIRCOLORS;
	drawmarks(r);
}

# --- input -----------------------------------------------------------

keydown(k: int): int
{
	if (automapactive == 0) {
		if (k == Tab) {
			start();
			return 1;
		}
		return 0;
	}

	if (game != nil)
		plr = game->consoleplayer();

	consumed := 1;
	if (k == KR) {			# pan right
		if (followplayer == 0)
			m_panx = ftom(F_PANINC);
		else
			consumed = 0;
	} else if (k == KL) {		# pan left
		if (followplayer == 0)
			m_panx = -ftom(F_PANINC);
		else
			consumed = 0;
	} else if (k == KU) {		# pan up
		if (followplayer == 0)
			m_pany = ftom(F_PANINC);
		else
			consumed = 0;
	} else if (k == KD) {		# pan down
		if (followplayer == 0)
			m_pany = -ftom(F_PANINC);
		else
			consumed = 0;
	} else if (k == '-') {		# zoom out
		mtof_zoommul = M_ZOOMOUT;
		ftom_zoommul = M_ZOOMIN;
	} else if (k == '=') {		# zoom in
		mtof_zoommul = M_ZOOMIN;
		ftom_zoommul = M_ZOOMOUT;
	} else if (k == Tab) {		# map off
		bigstate = 0;
		stop();
	} else if (k == '0') {		# max zoom toggle
		bigstate = !bigstate;
		if (bigstate != 0) {
			savescaleandloc();
			minoutwindowscale();
		} else {
			restorescaleandloc();
		}
	} else if (k == 'f') {		# follow on/off
		followplayer = !followplayer;
		f_oldlocx = INTMAX;
		if (plr != nil) {
			if (followplayer != 0)
				plr.message = "Follow Mode ON";
			else
				plr.message = "Follow Mode OFF";
		}
	} else if (k == 'g') {		# grid on/off
		grid = !grid;
		if (plr != nil) {
			if (grid != 0)
				plr.message = "Grid ON";
			else
				plr.message = "Grid OFF";
		}
	} else if (k == 'm') {		# drop a mark
		if (plr != nil)
			plr.message = sys->sprint("Marked Spot %d", markpointnum);
		addmark();
	} else if (k == 'c') {		# clear marks
		clearmarks();
		if (plr != nil)
			plr.message = "All Marks Cleared";
	} else {
		consumed = 0;
	}
	return consumed;
}

keyup(k: int): int
{
	if (automapactive == 0)
		return 0;
	if (k == KR || k == KL) {
		if (followplayer == 0)
			m_panx = 0;
		return 1;
	}
	if (k == KU || k == KD) {
		if (followplayer == 0)
			m_pany = 0;
		return 1;
	}
	if (k == '-' || k == '=') {
		mtof_zoommul = FRACUNIT;
		ftom_zoommul = FRACUNIT;
		return 1;
	}
	return 0;
}
