implement View;

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
include "game.m";
include "view.m";

# fine-angle table constants (mirror game.m; view.b does not import game.m).
# finesine[k] = sin(k*PI/2048) in 16.16; finecosine[k] = finesine[k+2048].
# view builds its own local table so it does not depend on Info.init().
ANGLETOFINESHIFT:	con 19;
FINEMASK:		con 8191;
FINEANGLES:		con 8192;
FINESINELEN:		con 10240;	# full sine + 1 extra quadrant for finecosine
# vanilla lighting constants (r_main.h): light index i = lightlevel>>4
# (16 bands), colormap rows 0..31 (row 0 = fullbright, 31 = darkest),
# plane distance band shift 20, wall scale band shift 12.
LIGHTLEVELS:		con 16;
LIGHTSEGSHIFT:		con 4;
NUMCOLORMAPS:		con 32;
LIGHTSCALESHIFT:	con 12;
MAXLIGHTSCALE:		con 48;
LIGHTZSHIFT:		con 20;
MAXLIGHTZ:		con 128;
DISTMAP:		con 2;
fsine:	array of int;	# local sine table, built once in init()

# camera state (set at start of render)
vx, vy, vz:	int;	# 16.16
	vangle:		int;	# BAM
	# TEMP diagnostics (sprite clip debugging): auto sweep
	dbgframes:	int;
	dbgcx, dbgcy:	int;
	cltopfrom, clbotfrom: array of int;
vcos, vsin:	int;	# 16.16

# renderer state (set by init)
r:	ref Rend->Renderer;
lev:	ref Map->Level;
w, h:	int;
proj:	int;		# 16.16 focal length (= centerx for 90deg FOV)
solid:	array of int;	# per-column occlusion: solid[2*x]=first open row, solid[2*x+1]=one past last open row (vanilla ceilingclip+1 / floorclip)

# ---- floor/ceiling plane rendering ----
# Vanilla visplane model (r_plane.c).  As walls are walked front-to-
# back, each seg marks the floor/ceiling planes it exposes into a list
# of visplanes (interned by z/flat/light).  Each visplane holds a
# per-column [top,bottom] clip; contiguous runs become spans, mapped
# to screen by mapplane() at frame end (drawplanes).
MAXVISPLANES:	con 128;
MAXVISW:	con 512;	# width cap for visplane clip arrays

Visplane: adt {
	z:	int;		# plane world z, 16.16
	light:	int;		# vanilla light index i = lightlevel>>LIGHTSEGSHIFT (0..15);
				# the colormap row is picked per distance band via zlight
	flatname:	string;
	minx, maxx:	int;
	top, bottom:	array of int;	# [MAXVISW] per-column clip; -1 = none
};

vps:	array of Visplane;	# MAXVISPLANES slots
nvp:	int;			# live visplanes
curfloor, curceil:	int;	# index into vps of current floor/ceiling plane, -1 = none

yslope:	array of int;	# [h] proj/|dy|, 16.16
distscale:	array of int;	# [w] 1/cos(ray), 16.16
xtofine:	array of int;	# [w] fine index of column's view angle (vanilla xtoviewangle>>ANGLETOFINESHIFT)
centerx:	int;
basexscale:	int;	# world u step per unit depth along right axis (16.16)
baseyscale:	int;	# world v step per unit depth (16.16)
plfl:	ref Rend->Flat;	# flat bound for the mapplane call below
zlight:	array of array of int;	# [LIGHTLEVELS][MAXLIGHTZ] colormap row per light band / plane distance band
scalelight:	array of array of int;	# [LIGHTLEVELS][MAXLIGHTSCALE] row per light band / wall scale index

# ---- milestone 8: sprites + masked mids (r_things.c / r_segs.c) ----
MINZ:		con 4 * 16r10000;	# r_things.c:40
MAXDRAWSEGS:	con 256;		# r_defs.h:51
MAXVISSPRITES:	con 128;		# r_things.h:25
FF_FRAMEMASK:	con 16r7fff;		# p_pspr.h:45
FF_FULLBRIGHT:	con 16r8000;		# p_pspr.h:44
ML_DONTPEGTOP:	con 8;			# doomdata.h:117
ML_DONTPEGBOTTOM: con 16;		# doomdata.h:120
SIL_BOTTOM:	con 1;			# r_defs.h:47
SIL_TOP:	con 2;			# r_defs.h:48
ANG45HALF9:	con ~1879048191;	# (ANG45/2)*9 = 0x90000000, r_things.c:515
INT_MAX:	con 2147483647;
INT_MIN:	con ~2147483647;	# 0x80000000

wfile:	ref Wad->File;		# open WAD for sprite lumps (set by init)
gmod:	Game;			# loaded Game module (sprite rotation angles)

# one sprite patch lump: header + raw column data (vanilla reads
# posts straight from the lump, so keep it raw like R_GetColumn)
SprPatch: adt {
	w, h:	int;
	xoff, yoff:	int;	# left/top offsets, 16.16 (spriteoffset/titetopoffset)
	colofs:	array of int;	# column directory into raw
	raw:	array of byte;
};

# per sprite/frame rotation table (R_InitSpriteDefs)
SpriteFrame: adt {
	rotate:	int;		# -1 no patches, 0 all-rotations, 1 eight rots
	lump:	array of int;	# [8] patch index, -1 = missing
	flip:	array of int;	# [8]
};

SprDef: adt {
	frames:	array of SpriteFrame;
};

sprdefs:	array of SprDef;	# [Info->NUMSPRITES]
sprpatch:	array of ref SprPatch;
sprfirst:	int;		# index of first sprite lump (offset base)

# temp install state (vanilla sprtemp/maxframe globals)
sprtemp:	array of SpriteFrame;
sprmaxf:	int;
sprname:	string;

# vissprite pool (r_things.c)
Vissprite: adt {
	x1, x2:	int;
	gx, gy, gz, gzt:	int;	# world position, 16.16
	startfrac, scale, xiscale, texturemid: int;
	patch:	int;		# index into sprpatch
	light:	int;		# colormap row 0..31, -1 = fuzz draw
	mobjflags:	int;
};
viss:	array of Vissprite;
nvis:	int;
ovvis:	Vissprite;		# overflow slot (never drawn, vanilla behavior)

# drawseg pool (r_defs.h drawseg_t): records every drawn wall seg so
# sprites can clip against it and masked mids can be flushed later
Drawseg: adt {
	x1, x2:	int;
	s1, s2, ox1, tspan: int;	# scale basis, same as the wall loop
	sil:	int;		# SIL_* bitmask
	bsilh, tsilh:	int;		# sprite clip height tests
	segnum:	int;		# lev.segs index for R_PointOnSegSide
	walllight:	int;		# orientation-adjusted light index
	midxex:	ref Rend->Texture;	# masked mid (nil = none)
	tmidbase:	int;		# masked dc_texturemid base
	mcol, mflag:	array of int;	# per column tex col / state (masked only)
	top, bot:	array of int;	# clip snapshot (our convention:
					# top = first open row, bot = one past last)
};
dssegs:	array of Drawseg;
nds:	int;

# per-sprite clip built by the drawseg scan (vanilla cliptop/clipbot)
sptop, spbot:	array of int;

init(rr: ref Rend->Renderer, l: ref Map->Level, wf: ref Wad->File,
		g: Game, width, height: int): string
{
	if (sys == nil)
		sys = load Sys Sys->PATH;
	sys->print("view.init: start\n");
	if (rr == nil)
		return "view.init: nil renderer";
	if (l == nil)
		return "view.init: nil level";
	if (wf == nil)
		return "view.init: nil wad";
	if (g == nil)
		return "view.init: nil game module";
	if (wad == nil)
		wad = load Wad Wad->PATH;
	if (mapm == nil)
		mapm = load Map Map->PATH;
	if (rend == nil) {
		rend = load Rend Rend->PATH;
		if (rend == nil)
			return sys->sprint("can't load Rend module: %r");
	}
	buildfsine();	# local sine table, replaces Info dependency
	r = rr;
	lev = l;
	wfile = wf;
	gmod = g;
	w = width;
	h = height;
	proj = width / 2;		# 90-degree horizontal FOV (raw pixels)
	centerx = width / 2;
	solid = array[w * 2] of int;

	# sprite + drawseg pools, sprite clip arrays
	viss = array[MAXVISSPRITES] of Vissprite;
	dssegs = array[MAXDRAWSEGS] of Drawseg;
	sptop = array[w] of int;
	spbot = array[w] of int;

	# sprite defs from the WAD (Info tables were built by game.init)
	err := loadsprdefs();
	if (err != nil)
		return err;

	# plane texture-mapping table.  yslope[y] = proj/|dy| (16.16) scales
	# the eye-to-plane vertical distance into a per-row depth; vanilla
	# r_main.c uses abs(dy).  distscale[x] = 1/cos(ray through x), the
	# lateral (cosine) correction so edges don't stretch (built below,
	# after xtofine, from the same quantized column angle as vanilla).
	yslope = array[h] of int;
	for (y := 0; y < h; y++) {
		# vanilla r_main.c: dy = abs(((i-viewheight/2)<<FRACBITS)+FRACUNIT/2);
		# yslope = FixedDiv((viewwidth/2)*FRACUNIT, dy) = (proj<<32)/dy.
		# the +FRACUNIT/2 half-pixel bias was dropped before, skewing every
		# row's depth slightly.
		dyp := ((y - h / 2) << 16) + 32768;
		if (dyp < 0)
			dyp = -dyp;
		yslope[y] = int((big(proj) << 32) / big dyp);
	}
	distscale = array[w] of int;
	# per-column fine view angle (vanilla xtoviewangle[x]>>ANGLETOFINESHIFT).
	# the fine index k for column x is the one whose tangent matches
	# (x-centerx)/proj: tan = finesine[k]/finesine[k+2048].  k is monotone
	# in x, so binary-search the half-circle once per column (12 iters,
	# ~4K ops total); mapplane then adds vangle.  This is what removes the
	# rotation shear: a precomputed exact index replaces a per-span ray
	# composition (single fixedmul per pixel, like vanilla).
	xtofine = array[w] of int;
	for (xc := 0; xc < w; xc++) {
		tds := ((xc - centerx) << 16) / proj;	# signed tan(delta), 16.16
		# find k in [-1024,1024] minimizing |tan(k)-tds| via binary search
		# on the monotone tangent; tan(k)=finesine[k]/finesine[k+2048].
		lo := -1024;
		hi := 1024;
		while (lo < hi) {
			# floor-division midpoint; Limbo truncates toward zero, which
			# stalls when lo=-1,hi=0 (mid=0 -> hi=0 forever).  compute floor
			# of (lo+hi)/2 explicitly for negative sums.
			sum := lo + hi;
			mid := sum / 2;
			if (sum < 0 && (sum % 2) != 0)
				mid = mid - 1;
			mk := mid & FINEMASK;
			cs := fsine[(mk + 2048) & FINEMASK];
			sn := fsine[mk];
			# smallest k with tan(k) >= tds.  tan = sn/cs (both 16.16,
			# scale cancels); tds is 16.16, so compare sn/cs vs tds/65536
			# -> sn<<16 vs tds*cs.  (old code compared sn*proj vs tds*cs:
			# wrong scale -- rhs was ~409x lhs, so the search always
			# returned the +/-1024 boundary for every column.)
			lhs := big(sn) << 16;
			rhs := big(tds) * big(cs);
			if (lhs < rhs)
				lo = mid + 1;
			else
				hi = mid;
		}
		# vanilla xtoviewangle[x] is NEGATIVE for x > centerx (the ray
		# through column x is at viewangle - delta).  the raw search finds
		# +delta, so negate: the old port stored +delta, mirroring the
		# texture origin left-right against the step axes -> shear.
		xtofine[xc] = (-lo) & FINEMASK;
	}

	# distscale[x] = 1/cos(ray through x), 16.16.  vanilla r_main.c:734-736:
	#   cosadj = abs(finecosine[xtoviewangle[i]>>ANGLETOFINESHIFT]);
	#   distscale[i] = FixedDiv(FRACUNIT, cosadj) = (1<<32)/cosadj.
	# built from the SAME quantized column angle as the origin (xtofine),
	# like vanilla, so length and origin stay exactly consistent.  The old
	# path computed 1/sqrt(1+tan^2) via isqrt(sum<<16): sum<<16 OVERFLOWS
	# int32 for sum>32767 (|tan|>0.63, the outer third of each screen
	# side), silently returning garbage/0 -> distscale fell back to 1.0
	# while the origin angle was still rotated: length up to 41% short at
	# the edges = severe shear/Stretch near screen edges.
	for (x := 0; x < w; x++) {
		# cosadj = finecosine[xtofine[x]] = fsine[(xtofine+2048)&FINEMASK].
		# |offset| <= 1024 fine (45 deg) -> cosadj in [46341, 65535] > 0.
		cosadj := fsine[(xtofine[x] + 2048) & FINEMASK];
		if (cosadj <= 0)
			cosadj = 16r10000;
		distscale[x] = int(big(65536) * big(65536) / big cosadj);
	}

	# vanilla light tables (r_main.c: R_InitLightTables builds zlight,
	# R_SetViewSize builds scalelight).  startmap = the dark/far base
	# for light band i; plane distance (zlight) and wall scale
	# (scalelight) subtract up to 31 (DISTMAP=2), so near = bright,
	# far = startmap.  i = lightlevel>>LIGHTSEGSHIFT with extralight=0
	# (no light-amp pickups): lightlevel 255 -> i=15 -> startmap 0 ->
	# row 0 at EVERY distance (outdoors fullbright).  The old
	# (lightlevel*31)/255 was INVERTED: 255 -> row 31, the DARKEST
	# colormap row -> outdoors (lightlevel 255/224) rendered pitch
	# black; the curves crossed at 128 so dim interiors looked fine.
	zlight = array[LIGHTLEVELS] of array of int;
	scalelight = array[LIGHTLEVELS] of array of int;
	for (i := 0; i < LIGHTLEVELS; i++) {
		startmap := ((LIGHTLEVELS - 1 - i) * 2) * NUMCOLORMAPS / LIGHTLEVELS;
		level := 0;
		j := 0;
		zlight[i] = array[MAXLIGHTZ] of int;
		scalelight[i] = array[MAXLIGHTSCALE] of int;
		for (j = 0; j < MAXLIGHTZ; j++) {
			# scale = FixedDiv((w/2)*FRACUNIT, (j+1)<<LIGHTZSHIFT)
			#         >> LIGHTSCALESHIFT; big: (w/2)<<(16+16) > int32
			scale := int((big(w / 2) << 32) / big((j + 1) << LIGHTZSHIFT))
				>> LIGHTSCALESHIFT;
			level = startmap - scale / DISTMAP;
			if (level < 0)
				level = 0;
			if (level >= NUMCOLORMAPS)
				level = NUMCOLORMAPS - 1;
			zlight[i][j] = level;
		}
		for (j = 0; j < MAXLIGHTSCALE; j++) {
			# vanilla: startmap - j*SCREENWIDTH/viewwidth/DISTMAP
			# (= startmap - j/2 at detailshift 0, w = SCREENWIDTH = 320)
			level = startmap - j * 320 / w / DISTMAP;
			if (level < 0)
				level = 0;
			if (level >= NUMCOLORMAPS)
				level = NUMCOLORMAPS - 1;
			scalelight[i][j] = level;
		}
	}

	# visplane slots
	vps = array[MAXVISPLANES] of Visplane;
	for (i = 0; i < MAXVISPLANES; i++) {
		vps[i] = Visplane(z := 0, light := 0, flatname := "",
			minx := w, maxx := -1,
			top := array[MAXVISW] of int,
			bottom := array[MAXVISW] of int);
		for (x = 0; x < MAXVISW; x++) {
			vps[i].top[x] = -1;
			vps[i].bottom[x] = -1;
		}
	}
	nvp = 0;
	curfloor = curceil = -1;
	return nil;
}

render(viewx, viewy, viewz, viewangle, viewcos, viewsin: int,
		mobs: array of ref Game->Mobj)
{
	if (r == nil || lev == nil)
		return;
	# TEMP: clip-attribution arrays for drawspscan instrumentation
	if (cltopfrom == nil) {
		cltopfrom = array[w] of int;
		clbotfrom = array[w] of int;
	}
	dbgframes++;
	vx = viewx;
	vy = viewy;
	vz = viewz;
	vangle = viewangle;
	vcos = viewcos;
	vsin = viewsin;
	# per-frame plane step axes (vanilla r_plane.c:200-201):
	#   basexscale =  finecosine[viewangle-ANG90] / centerxfrac
	#   baseyscale = -finesine  [viewangle-ANG90] / centerxfrac
	# with centerxfrac = centerx<<FRACBITS = proj<<16.  fine-angle identity
	# (finecosine[k]=finesine[k+2048]):
	#   finecosine[viewangle-ANG90] =  sin(viewangle) = vsin
	#   finesine  [viewangle-ANG90] = -cos(viewangle) = -vcos
	# so the raw lines reduce to:
	#   basexscale =  vsin / (proj<<16)
	#   baseyscale = -(-vcos) / (proj<<16) = +vcos / (proj<<16)
	# Earlier the port wrote baseyscale = -vcos(...): a sign flip.  The step
	# then pointed along left instead of right while the origin was correct,
	# so texture coords slid the wrong way -- shear that grows with the
	# column's lateral offset (zero at default view, worst at the edges on
	# rotation).  mapplane applies xstep=distance*basexscale directly; the
	# /proj is REQUIRED (removing it smears the flat into diagonal noise).
	basexscale = rend->rfixeddiv(vsin, proj << 16);
	baseyscale = rend->rfixeddiv(vcos, proj << 16);
	nsegs = ncolumns = nspans = 0;
	nds = 0;
	nvis = 0;
	nsprites = 0;
	ndrawsegs = 0;

	# clear to black
	rend->rclear(r, 0);

	# reset occlusion: full screen open in every column.
	# solid[2x] is the first open row (vanilla ceilingclip+1, init -1+1=0),
	# solid[2x+1] one past the last (vanilla floorclip = viewheight).
	for (x := 0; x < w; x++) {
		solid[2*x] = 0;
		solid[2*x+1] = h;
	}

	# reset visplanes for this frame
	nvp = 0;
	curfloor = curceil = -1;

	# walk BSP front-to-back from the root
	if (len lev.nodes > 0)
		renderbsp(len lev.nodes - 1);
	else if (len lev.subsectors > 0)
		rendersubsector(0);

	# project thing sprites (vanilla does this per sector during the
	# walk via R_AddSprites; projecting everything here is equivalent
	# because offscreen/behind/culled sectors fail the same tests)
	# project thing sprites (vanilla does this per sector during the
	# walk via R_AddSprites; projecting everything here is equivalent
	# because offscreen/behind/culled sectors fail the same tests)
	if (mobs != nil) {
		for (i := 0; i < len mobs; i++)
			projectmo(mobs[i]);
	}
	nsprites = nvis;
	nmasked = 0;

	# flush accumulated floor/ceiling spans to screen
	drawplanes();

	# sprites back-to-front, then remaining masked midtextures
	drawmasked();
}

# vanilla R_PointOnSide: 0 = front (right), 1 = back (left)
pointonside(x, y: int, nd: Map->Node): int
{
	if (nd.dx == 0) {
		if (x <= nd.x)
			return int nd.dy > 0;
		return int nd.dy < 0;
	}
	if (nd.dy == 0) {
		if (y <= nd.y)
			return int nd.dx < 0;
		return int nd.dx > 0;
	}
	dx := x - nd.x;
	dy := y - nd.y;
	# cross-product comparison; fixedmul overflows for large
	# 16.16 coords (ah*bh<<16), so compare full products in big
	left := big(nd.dy) * big(dx);
	right := big(dy) * big(nd.dx);
	if (right < left)
		return 0;
	return 1;
}

renderbsp(n: int)
{
	if (n < 0)
		return;
	if (n & 16r8000) {
		rendersubsector(n & ~16r8000);
		return;
	}
	if (n >= len lev.nodes)
		return;
	nd := lev.nodes[n];
	side := pointonside(vx, vy, nd);
	# near side first
	renderbsp(nd.children[side]);
	# far side
	renderbsp(nd.children[side ^ 1]);
}

rendersubsector(num: int)
{
	if (num < 0 || num >= len lev.subsectors)
		return;
	ss := lev.subsectors[num];
	for (i := 0; i < ss.numsegs; i++) {
		si := ss.firstseg + i;
		if (si < 0 || si >= len lev.segs)
			continue;
		addline(si);
	}
}

# project world (x,y) to view-space (depth, lateral), both 16.16
# depth: forward distance (positive = in front of camera)
# lateral: left offset (positive = left of center)
toworld(x, y: int): (int, int)
{
	dx := x - vx;
	dy := y - vy;
	depth := rend->fixedmul(dx, vcos) + rend->fixedmul(dy, vsin);
	lateral := rend->fixedmul(dy, vcos) - rend->fixedmul(dx, vsin);
	return (depth, lateral);
}

# screen x from lateral/depth: centerx - lateral*proj/depth
# uses big: lateral*proj overflows int32 for distant vertices
projx(lateral, depth: int): int
{
	if (depth <= 0)
		return 16r7fffffff;	# behind
	return (w / 2) - int(big(lateral) * big(proj) / big(depth));
}

# screen y from world z and depth: centery - (z-viewz)*proj/depth
projy(z, depth: int): int
{
	if (depth <= 0)
		return 16r7fffffff;
	dz := z - vz;
	return r.centery - int(big(dz) * big(proj) / big(depth));
}

FRACUNIT:	con 16r10000;
SKYFLAT:	con "F_SKY1";	# map flat marking a sky ceiling (r_sky.h SKYFLATNAME)
SKYTEX:		con "SKY1";	# sky texture: episode 1 (g_game.c maps episodes to
			# SKY1/SKY2/SKY3; shareware has SKY1 only)
SKYMID:		con 6553600;	# 100*FRACUNIT, vanilla skytexturemid (r_sky.c)

# draw one seg as wall columns
addline(segnum: int)
{
	# vanilla R_StoreWallRange overflow check (r_segs.c:383): the whole
	# seg (wall draw included) is skipped when the drawseg pool is full
	if (nds >= MAXDRAWSEGS)
		return;
	seg := lev.segs[segnum];
	v1 := lev.vertices[seg.v1];
	v2 := lev.vertices[seg.v2];

	# transform both endpoints
	(d1, l1) := toworld(v1.x, v1.y);
	(d2, l2) := toworld(v2.x, v2.y);

	# both endpoints behind camera: skip
	if (d1 <= 0 && d2 <= 0)
		return;

	# clip to near plane (z=0 in view space) by interpolating
	# if one endpoint is behind, clip it
	x1 := 0;
	x2 := 0;
	z1t := 0;	# interpolated top z at endpoint 1
	z1b := 0;	# interpolated bottom z at endpoint 1
	z2t := 0;
	z2b := 0;
	u1 := 0;	# texture u at endpoint 1
	u2 := 0;

	# get linedef + sidedef for texture info
	if (seg.linedef < 0 || seg.linedef >= len lev.lines)
		return;
	ld := lev.lines[seg.linedef];
	if (seg.side < 0 || seg.side >= len ld.sides || ld.sides[seg.side] == nil)
		return;
	sd := ld.sides[seg.side];

	# sector heights (front sector of this side)
	sec := sd.sector;
	if (sec == nil)
		return;
	floorz := sec.floorheight;
	ceilz := sec.ceilingheight;

	# back sector (for two-sided lines)
	back: ref Map->Sector;
	if (ld.backsector != nil && seg.side == 0)
		back = ld.backsector;
	else if (ld.backsector != nil && seg.side == 1 && len ld.sides > 0 && ld.sides[0] != nil)
		back = ld.sides[0].sector;

	# texture u: offset along the line from v1
	# u1 = seg.offset (start), u2 = offset + line length
	ldx := v2.x - v1.x;
	ldy := v2.y - v1.y;
	linelen := 1;
	if (ldx != 0 || ldy != 0)
		linelen = isqrt((ldx >> 16) * (ldx >> 16) + (ldy >> 16) * (ldy >> 16)) << 16;
	# texture u: offset along the line from v1, plus the sidedef's
	# horizontal texture offset (vanilla rw_offset adds both)
	u1 = seg.offset + sd.textureoffset;
	u2 = u1 + linelen;

	# clip endpoints behind the near plane.
	# interpolation is in wall-parameter space (affine) so linear
	# frac is exact here; frac itself needs big: (-d1)<<16
	# overflows int32 for far-behind endpoints (16.16 << 16).
	if (d1 <= 0) {
		if (d2 <= 0)
			return;
		frac := int((big(-d1) << 16) / big(d2 - d1));	# 16.16
		l1 = l1 + rend->fixedmul(l2 - l1, frac);
		d1 = FRACUNIT / 4;	# small positive depth
		u1 = u1 + rend->fixedmul(u2 - u1, frac);
	} else if (d2 <= 0) {
		frac := int((big(-d2) << 16) / big(d1 - d2));	# 16.16
		l2 = l2 + rend->fixedmul(l1 - l2, frac);
		d2 = FRACUNIT / 4;
		u2 = u2 + rend->fixedmul(u1 - u2, frac);
	}
	x1 = projx(l1, d1);
	x2 = projx(l2, d2);
	z1t = ceilz;
	z1b = floorz;
	z2t = ceilz;
	z2b = floorz;

	# ensure x1 <= x2 (swap if needed)
	sx := 0;
	sd_ := 0;
	sl := 0;
	su := 0;
	if (x1 > x2) {
		sx = x1;
		x1 = x2;
		x2 = sx;
		sd_ = d1;
		d1 = d2;
		d2 = sd_;
		sl = l1;
		l1 = l2;
		l2 = sl;
		su = u1;
		u1 = u2;
		u2 = su;
	}
	# keep ORIGINAL projected x for the interpolation basis.
	# screen-x scale/u fractions must span the true endpoint
	# positions (possibly far offscreen); clamping x1/x2 first
	# and interpolating from the clamped values warps scale/u
	# at the screen edges (near-clipped endpoints project to
	# |x| ~ millions, depth=0.25 scale = 640px/unit).
	ox1 := x1;
	ox2 := x2;

	# clip loop bounds to screen
	if (ox2 < 0 || ox1 >= w)
		return;
	lx1 := ox1;
	if (lx1 < 0)
		lx1 = 0;
	lx2 := ox2;
	if (lx2 >= w)
		lx2 = w - 1;

	# vanilla light indices (r_segs.c R_StoreWallRange + r_plane.c).
	# plane claims use the sector index i = lightlevel>>LIGHTSEGSHIFT
	# with extralight = 0; wall columns additionally get the orientation
	# hack (r_segs.c:649-653: horizontal segs one step darker, vertical
	# one step brighter, then clamp to [0,LIGHTLEVELS-1]).
	pllight := sec.lightlevel >> LIGHTSEGSHIFT;
	if (pllight < 0)
		pllight = 0;
	if (pllight >= LIGHTLEVELS)
		pllight = LIGHTLEVELS - 1;
	walllight := pllight;
	if (v1.y == v2.y)
		walllight--;
	else if (v1.x == v2.x)
		walllight++;
	if (walllight < 0)
		walllight = 0;
	if (walllight >= LIGHTLEVELS)
		walllight = LIGHTLEVELS - 1;

	# scale basis for the whole seg (both wall loops and the drawseg
	# record use this same linear-in-x basis)
	dd1 := d1;
	dd2 := d2;
	if (dd1 < FRACUNIT / 4)
		dd1 = FRACUNIT / 4;
	if (dd2 < FRACUNIT / 4)
		dd2 = FRACUNIT / 4;
	s1 := int(big(FRACUNIT) * big(FRACUNIT) * big(proj) / big(dd1));
	s2 := int(big(FRACUNIT) * big(FRACUNIT) * big(proj) / big(dd2));
	tspan := ox2 - ox1;

	# record the wall for sprite clipping / masked flushes
	dsidx := claimds(segnum, lx1, lx2, s1, s2, ox1, tspan, walllight);

	# choose texture
	texname := sd.midtexture;
	if (back != nil) {
		# vanilla markfloor/markceiling (r_segs.c:536-560): a plane is
		# marked when back differs on z/pic/light, or the door is closed.
		# The sky hack makes equal-sky ceilings always z-equal (vanilla
		# rewrites worldtop = worldhigh before the compare).  These gate
		# drawtwosided's textureless clip advance (r_segs.c:315, 345).
		markfloor := 1;
		markceiling := 1;
		if (back.floorheight == floorz
			&& back.floortexture == sec.floortexture
			&& back.lightlevel == sec.lightlevel)
			markfloor = 0;
		if (sec.ceilingtexture == SKYFLAT && back.ceilingtexture == SKYFLAT) {
			if (back.lightlevel == sec.lightlevel)
				markceiling = 0;
		} else if (back.ceilingheight == ceilz
			&& back.ceilingtexture == sec.ceilingtexture
			&& back.lightlevel == sec.lightlevel)
			markceiling = 0;
		if (back.ceilingheight <= floorz || back.floorheight >= ceilz) {
			markfloor = 1;
			markceiling = 1;
		}
		# two-sided: draw upper and lower, maybe masked middle
		drawtwosided(dsidx, sd, ld.flags, lx1, lx2, ox1, ox2,
			d1, d2, u1, u2, ceilz, floorz, back.ceilingheight,
			back.floorheight, back.ceilingtexture, pllight,
			walllight, markfloor, markceiling);
		return;
	}

	# one-sided: terminal clip, SIL_BOTH with constant closed clips
	# (vanilla r_segs.c:473-477)
	sil1s(dsidx);

	# intern this sector's floor/ceiling planes for the column loop below.
	# vanilla R_Subsector only picks a floorplane below the eye and a
	# ceilingplane above it (or sky): outside those bounds the plane is
	# not visible and claiming with it paints garbage.  checkplane then
	# decides per seg whether claims join the interned visplane or a
	# duplicate (vanilla R_CheckPlane), keeping per-column strips exact.
	# (runs even for untextured walls: the loop still closes solid[]
	# and claims planes, matching vanilla R_RenderSegLoop)
	curfloor = -1;
	if (floorz < vz)
		curfloor = checkplane(findplane(floorz, sec.floortexture, pllight),
			lx1, lx2);
	curceil = -1;
	if (ceilz > vz || sec.ceilingtexture == SKYFLAT)
		curceil = checkplane(findplane(ceilz, sec.ceilingtexture, pllight),
			lx1, lx2);

	# nil tex ("" / "-" / unknown) -> run the loop without the column draw
	tex: ref Rend->Texture;
	if (texname != "" && texname != "-")
		tex = rend->rtexture(r, texname);

	# u is linear in wall-parameter, MOBIUS in screen x (vanilla
	# gets this right via finetangent per column).  u/depth and
	# 1/depth are both linear in screen x, so interp those and
	# divide.  big: u1<<16 overflows int32 (u up to 4000 units).
	ud1 := int((big(u1) << 16) / big(dd1));	# u/depth, 16.16
	ud2 := int((big(u2) << 16) / big(dd2));
	id1 := int(16r100000000 / big(dd1));	# 1/depth, 16.16
	id2 := int(16r100000000 / big(dd2));

	# draw columns lx1..lx2; frac spans the ORIGINAL x span
	nsegs++;
	for (x := lx1; x <= lx2; x++) {
		frac := 0;
		if (tspan > 0)
			# ox1 is the ORIGINAL projected endpoint (kept unclamped as
			# the interpolation basis) and can sit far off-screen: a
			# near-plane-clipped endpoint projects to |x| ~ 100k px, so
			# (x-ox1)<<16 overflows int32 for left-extending segs ->
			# garbage/negative frac -> scale/id extrapolated to garbage:
			# zoomed or missing wall columns along the screen's left edge.
			# (Right-extending segs never overflow: ox1 stays on-screen
			# so x-ox1 <= 320.)  big required; result stays <= 65536
			# since x <= ox2.
			frac = int(((big(x) - big(ox1)) << 16) / big(tspan));
		scale := s1 + rend->fixedmul(s2 - s1, frac);
		if (scale <= 0)
			continue;

		ud := ud1 + rend->fixedmul(ud2 - ud1, frac);
		id := id1 + rend->fixedmul(id2 - id1, frac);
		if (id <= 0)
			continue;
		u := int((big(ud) << 16) / big(id));

		yt := r.centery - int(big(z1t + rend->fixedmul(z2t - z1t, frac) - vz) * big(scale) >> 32);
		yb := r.centery - int(big(z1b + rend->fixedmul(z2b - z1b, frac) - vz) * big(scale) >> 32);

		# clip to occlusion
		cclip := solid[2*x];
		fclip := solid[2*x+1];
		if (yt < cclip)
			yt = cclip;
		if (yt < 0)
			yt = 0;
		if (yb >= fclip)
			yb = fclip - 1;
		if (yb >= h)
			yb = h - 1;

		# mark the planes this wall exposes before drawing, like vanilla
		# R_RenderSegLoop: rows above the wall to the ceiling plane, rows
		# below to the floor plane.  markplane clamps both strips to the
		# open window, and a fully clipped wall still marks (its strips
		# tile what the window has left) then closes the column.
		markplane(curceil, x, cclip, yt - 1);
		markplane(curfloor, x, yb + 1, fclip);

			if (yt <= yb && tex != nil) {
				# texture mapping
				col := u >> 16;
				# iscale: 16.16 texture units per screen pixel = 2^32/scale.
				# int-safe when scale>=2^16 (result<=2^16); else big (rare: very close walls).
				iscale: int;
				if (scale >= 16r10000)
					iscale = int(big(16r100000000) / big(scale));
				else
					iscale = int(16r100000000 / big(scale));
				# texturemid: world z above eye, 16.16 texels (1 texel = 1 unit).
				# vanilla rw_midtexturemid (r_segs.c:459-468): DONTPEGBOTTOM
				# anchors the texture bottom at the front floor, else top at
				# the ceiling; both + sidedef rowoffset.
				tmid: int;
				if (ld.flags & ML_DONTPEGBOTTOM)
					tmid = floorz + (tex.height << 16) - vz;
				else
					tmid = z1t + rend->fixedmul(z2t - z1t, frac) - vz;
				tmid += sd.rowoffset;
			# vanilla wall light: index = rw_scale>>LIGHTSCALESHIFT
			# (r_segs.c:260-263), clamp MAXLIGHTSCALE-1, row from
			# scalelight[front lightnum][index]
			lidx := scale >> LIGHTSCALESHIFT;
			if (lidx >= MAXLIGHTSCALE)
				lidx = MAXLIGHTSCALE - 1;
			rend->rdrawcolumn(r,x, yt, yb, scalelight[walllight][lidx],
				tex, col, tmid, iscale);
			ncolumns++;
		}

		# a solid wall is terminal: close the column completely
		# (vanilla sets ceilingclip=viewheight, floorclip=-1).
		solid[2*x] = h;
		solid[2*x+1] = -1;
	}
}

# two-sided line: draw upper and lower textures where heights differ,
# and store the masked middle for the back-to-front flush.  dsidx is
# the drawseg claimed in addline (scale basis / clip storage).
# plight = front sector plane light index; walllight = front sector wall
# light index (orientation-adjusted, computed in addline).
drawtwosided(dsidx: int, sd: ref Map->Side, ldflags: int,
	lx1, lx2, ox1, ox2, d1, d2, u1, u2: int,
	fceilz, ffloorz, bceilz, bfloorz: int, bceiltex: string,
	plight, walllight, markfloor, markceiling: int)
{
	ds := dssegs[dsidx];
	nsegs++;

	# masked middle texture: store per-column texture coords for a
	# back-to-front flush after the walls (r_segs.c:537-579, 604-622).
	# dc_texturemid (r_segs.c:137-149): hidden peg anchors the texture
	# at the shared floor plus texture height, else at the higher ceiling.
	midtex: ref Rend->Texture;
	if (sd.midtexture != "" && sd.midtexture != "-") {
		midtex = rend->rtexture(r, sd.midtexture);
		if (midtex != nil) {
			ds.midxex = midtex;
			if (ds.mcol == nil) {
				ds.mcol = array[w] of int;
				ds.mflag = array[w] of int;
			}
			for (x := lx1; x <= lx2; x++)
				ds.mflag[x] = 0;
			if (ldflags & ML_DONTPEGBOTTOM) {
				base := ffloorz;
				if (bfloorz > base)
					base = bfloorz;
				ds.tmidbase = base + (midtex.height << 16) - vz;
			} else {
				top := fceilz;
				if (bceilz < top)
					top = bceilz;
				ds.tmidbase = top - vz;
			}
			ds.tmidbase += sd.rowoffset;
		}
	}

	# silhouette heights (r_segs.c:485-521): bsilh/tsilh are compared
	# against sprite world bottom/top; closed windows are terminal clips.
	# masked segs force both bits so sprites never cut on this wall
	# (r_segs.c:731-740; the wall itself still clips them via top/bot).
	ds.sil = 0;
	ds.bsilh = INT_MAX;
	ds.tsilh = INT_MIN;
	topclosed := 0;
	botclosed := 0;
	if (ffloorz > bfloorz) {
		ds.sil |= SIL_BOTTOM;
		ds.bsilh = ffloorz;
	} else if (bfloorz > vz) {
		ds.sil |= SIL_BOTTOM;
		ds.bsilh = INT_MAX;
	}
	if (fceilz < bceilz) {
		ds.sil |= SIL_TOP;
		ds.tsilh = fceilz;
	} else if (bceilz < vz) {
		ds.sil |= SIL_TOP;
		ds.tsilh = INT_MIN;
	}
	if (bceilz <= ffloorz) {
		botclosed = 1;
		ds.bsilh = INT_MAX;
		ds.sil |= SIL_BOTTOM;
	}
	if (bfloorz >= fceilz) {
		topclosed = 1;
		ds.tsilh = INT_MIN;
		ds.sil |= SIL_TOP;
	}
	if (midtex != nil) {
		if (!(ds.sil & SIL_TOP)) {
			ds.sil |= SIL_TOP;
			ds.tsilh = INT_MIN;
		}
		if (!(ds.sil & SIL_BOTTOM)) {
			ds.sil |= SIL_BOTTOM;
			ds.bsilh = INT_MAX;
		}
	}
	# closed windows keep constant terminal clips (vanilla's
	# screenheightarray/negonearray equivalents)
	if (topclosed) {
		for (x := lx1; x <= lx2; x++)
			ds.top[x] = h;
	}
	if (botclosed) {
		for (x := lx1; x <= lx2; x++)
			ds.bot[x] = -1;
	}

	# scale basis from the shared record; perspective-correct u via
	# u/depth and 1/depth (linear in x), same depth clamp as the record
	s1 := ds.s1;
	s2 := ds.s2;
	dd1 := d1;
	dd2 := d2;
	if (dd1 < FRACUNIT / 4)
		dd1 = FRACUNIT / 4;
	if (dd2 < FRACUNIT / 4)
		dd2 = FRACUNIT / 4;
	ud1 := int((big(u1) << 16) / big(dd1));
	ud2 := int((big(u2) << 16) / big(dd2));
	id1 := int(16r100000000 / big(dd1));
	id2 := int(16r100000000 / big(dd2));

	# intern the FRONT sector's planes for this seg.  vanilla picks
	# floorplane/ceilingplane per subsector (R_Subsector): floor only
	# below the eye, ceiling only above it (or sky) -- outside those
	# bounds the plane is invisible and must not claim rows.  The window
	# rows between the textures are claimed by the next seg behind this
	# portal, whose front sector is the back side: vanilla never claims
	# back-sector planes here (doing so double-claimed flat portals and
	# painted back floors over front floors at steps).  checkplane keeps
	# per-column strips exact (vanilla R_CheckPlane).
	fsec := sd.sector;
	frontfloor := -1;
	if (ffloorz < vz)
		frontfloor = checkplane(findplane(ffloorz, fsec.floortexture, plight),
			lx1, lx2);
	frontceil := -1;
	if (fceilz > vz || fsec.ceilingtexture == SKYFLAT)
		frontceil = checkplane(findplane(fceilz, fsec.ceilingtexture, plight),
			lx1, lx2);

	tspan := ox2 - ox1;
	for (x := lx1; x <= lx2; x++) {
		frac := 0;
		if (tspan > 0)
			# big: same left-edge ox1 overflow as in addline's loop
			frac = int(((big(x) - big(ox1)) << 16) / big(tspan));	# int-safe
		scale := s1 + rend->fixedmul(s2 - s1, frac);
		if (scale <= 0)
			continue;
		ud := ud1 + rend->fixedmul(ud2 - ud1, frac);
		id := id1 + rend->fixedmul(id2 - id1, frac);
		if (id <= 0)
			continue;
		u := int((big(ud) << 16) / big(id));
		col := u >> 16;

		# record the masked texture column for the later flush
		if (midtex != nil) {
			ds.mcol[x] = col;
			ds.mflag[x] = 1;
		}

		cclip := solid[2*x];
		fclip := solid[2*x+1];

		# vanilla wall light: index = rw_scale>>LIGHTSCALESHIFT
		# (r_segs.c:260-263), clamp MAXLIGHTSCALE-1, row from
		# scalelight[front lightnum][index]
		lidx := scale >> LIGHTSCALESHIFT;
		if (lidx >= MAXLIGHTSCALE)
			lidx = MAXLIGHTSCALE - 1;
		if (x == lx1)
		wrow := scalelight[walllight][lidx];

		iscale: int;
		if (scale >= 16r10000)
			iscale = int(big(16r100000000) / big(scale));
		else
			iscale = int(16r100000000 / big(scale));

		# upper texture: from back ceiling to front ceiling.  vanilla
		# sky hack (r_segs.c:525-530): when both ceilings are sky,
		# worldtop = worldhigh -- the upper texture collapses to zero
		# height and is never drawn, so the sky flows continuously
		# across height-changing outdoor areas.  our clip advance below
		# (cclip = max(cclip, fctop)) already matches vanilla's
		# markceiling branch (ceilingclip = yl-1) for undrawn uppers.
		if (bceilz < fceilz && sd.toptexture != "" && sd.toptexture != "-"
			&& !(fsec.ceilingtexture == SKYFLAT && bceiltex == SKYFLAT)) {
			tex := rend->rtexture(r,sd.toptexture);
			if (tex != nil) {
				yt := r.centery - int(big(fceilz - vz) * big(scale) >> 32);
				yb := r.centery - int(big(bceilz - vz) * big(scale) >> 32);
				if (yt < cclip) yt = cclip;
				if (yt < 0) yt = 0;
				if (yb >= fclip) yb = fclip - 1;
				if (yb >= h) yb = h - 1;
				if (yt <= yb) {
					# upper texture anchor (r_segs.c:571-585):
					# DONTPEGTOP -> row 0 at the front ceiling, else
					# texture bottom at the back ceiling (vanilla vtop);
					# both + rowoffset.
					tmid: int;
					if (ldflags & ML_DONTPEGTOP)
						tmid = fceilz - vz;
					else
						tmid = bceilz + (tex.height << 16) - vz;
					tmid += sd.rowoffset;
					rend->rdrawcolumn(r,x, yt, yb, wrow, tex, col, tmid, iscale);
					ncolumns++;
					cclip = yb + 1;
				}
			}
		}

		# lower texture: from front floor to back floor
		if (bfloorz > ffloorz && sd.bottomtexture != "" && sd.bottomtexture != "-") {
			tex := rend->rtexture(r,sd.bottomtexture);
			if (tex != nil) {
				# big: fixedmul(dz, scale)>>16 overflows for
				# close walls (dz ~200 units * scale 640px/u)
				yt := r.centery - int(big(bfloorz - vz) * big(scale) >> 32);
				yb := r.centery - int(big(ffloorz - vz) * big(scale) >> 32);
				if (yt < cclip) yt = cclip;
				if (yt < 0) yt = 0;
				if (yb >= fclip) yb = fclip - 1;
				if (yb >= h) yb = h - 1;
				if (yt <= yb) {
					# lower texture anchor (r_segs.c:591-599):
					# DONTPEGBOTTOM -> row 0 at the front ceiling,
					# else top at the back floor (worldlow);
					# both + rowoffset.
					tmid: int;
					if (ldflags & ML_DONTPEGBOTTOM)
						tmid = fceilz - vz;
					else
						tmid = bfloorz - vz;
					tmid += sd.rowoffset;
					rend->rdrawcolumn(r,x, yt, yb, wrow, tex, col, tmid, iscale);
					ncolumns++;
					fclip = yt;
				}
			}
		}

		# window edges (port equivalents of vanilla's topfrac/bottomfrac
		# rows for the front sector's ceiling and floor)
		fctop := r.centery - int(big(fceilz - vz) * big(scale) >> 32);
		flbot := r.centery - int(big(ffloorz - vz) * big(scale) >> 32);

		# advance the column clips to the front edges where no texture
		# covered them.  An upper/lower texture draw above already set
		# cclip/fclip past these edges, so the max/min are no-ops there.
		# This is vanilla's "no top/bottom wall" clip branches
		# (ceilingclip = yl-1, floorclip = yh+1) INCLUDING their
		# markceiling/markfloor gates (r_segs.c:315, 345): at a portal
		# where both sides share the plane vanilla leaves the clip OPEN,
		# and the sprite clipper must not cut either -- sprites behind
		# stand on that plane and project past this seg's edge row (feet
		# below a shared floor; entirely when the shared floor is above
		# the eye, flbot < 0 closed the whole column).  The gate only
		# skips the advance when the planes match, and then the next
		# seg behind claims with identical z/flat/light and joins the
		# same visplane anyway.
		if (markceiling && fctop > cclip)
			cclip = fctop;
		if (markfloor && flbot + 1 < fclip)
			fclip = flbot + 1;
		# clamp to the screen window: projy extremes for near-camera
		# geometry must not escape [0..h], and one unclamped write
		# inverts the visible region (yt > yb) for the rest of the
		# frame.  fclip <= cclip is just a closed column either way.
		if (cclip < 0)
			cclip = 0;
		if (cclip > h)
			cclip = h;
		if (fclip < 0)
			fclip = 0;
		if (fclip > h)
			fclip = h;

		# mark the front sector's planes in the strips above the upper
		# wall and below the lower wall; markplane clamps both to the
		# open window (vanilla's mutual ceilingclip/floorclip clamps).
		# Window rows are left for the next seg behind the portal, whose
		# front sector is the back side -- claiming back-sector planes here
		# double-claimed flat portals and painted back floors over front
		# floors at steps.
		markplane(frontceil, x, solid[2*x], fctop - 1);
		markplane(frontfloor, x, flbot + 1, solid[2*x+1]);

		solid[2*x] = cclip;
		solid[2*x+1] = fclip;
	}

	# snapshot the final clip for sprite occlusion (r_segs.c:715-740):
	# sprites need the wall's own clip state per column.  const-closed
	# columns keep their constants set above (the vanilla pre-clipped
	# screenheightarray/negonearray is equivalent), everything else
	# takes the post-loop solid[] state.
	if (!topclosed && ((ds.sil & SIL_TOP) || ds.midxex != nil)) {
		for (x = lx1; x <= lx2; x++)
			ds.top[x] = solid[2*x];
	}
	if (!botclosed && ((ds.sil & SIL_BOTTOM) || ds.midxex != nil)) {
		for (x = lx1; x <= lx2; x++)
			ds.bot[x] = solid[2*x+1];
	}
	# sync scalar/array-field state back into the pool: ds is a value
	# copy (array contents shared, scalar fields not)
	dssegs[dsidx].midxex = ds.midxex;
	dssegs[dsidx].tmidbase = ds.tmidbase;
	dssegs[dsidx].sil = ds.sil;
	dssegs[dsidx].bsilh = ds.bsilh;
	dssegs[dsidx].tsilh = ds.tsilh;
	dssegs[dsidx].mcol = ds.mcol;
	dssegs[dsidx].mflag = ds.mflag;
}

# ---- drawseg pool (r_segs.c R_StoreWallRange bookkeeping) ----

# one-sided line: terminal clip + SIL_BOTH, constant closed clips in
# every column (vanilla sets sprtopclip=screenheightarray,
# sprbottomclip=negonearray, bsilheight=INT_MAX, tsilheight=INT_MIN)
sil1s(dsidx: int)
{
	dssegs[dsidx].sil = SIL_BOTTOM | SIL_TOP;
	dssegs[dsidx].bsilh = INT_MAX;
	dssegs[dsidx].tsilh = INT_MIN;
	dssegs[dsidx].midxex = nil;
	ds := dssegs[dsidx];
	for (x := 0; x < w; x++) {
		ds.top[x] = h;
		ds.bot[x] = -1;
	}
}

# claim the next drawseg slot for a wall that passed all clipping;
# records the scale basis and fills open clips.  The overflow check
# is at addline entry (vanilla R_StoreWallRange: whole seg skipped).
claimds(segnum, x1, x2, s1, s2, ox1, tspan, walllight: int): int
{
	if (nds >= MAXDRAWSEGS)
		return -1;
	# Limbo gotcha: 'ref dssegs[i]' COPIES the element instead of
	# aliasing it, so scalar/field writes must use the direct path.
	# Array CONTENTS reached through a value copy ARE shared.
	dssegs[nds].x1 = x1;
	dssegs[nds].x2 = x2;
	dssegs[nds].s1 = s1;
	dssegs[nds].s2 = s2;
	dssegs[nds].ox1 = ox1;
	dssegs[nds].tspan = tspan;
	dssegs[nds].segnum = segnum;
	dssegs[nds].walllight = walllight;
	dssegs[nds].sil = 0;
	dssegs[nds].bsilh = 0;
	dssegs[nds].tsilh = 0;
	dssegs[nds].midxex = nil;
	dssegs[nds].tmidbase = 0;
	if (dssegs[nds].top == nil) {
		dssegs[nds].top = array[w] of int;
		dssegs[nds].bot = array[w] of int;
	}
	ds := dssegs[nds];
	for (x := 0; x < w; x++) {
		ds.top[x] = 0;
		ds.bot[x] = h;
	}
	nds++;
	ndrawsegs = nds;
	return nds - 1;
}

# wall scale (px per world unit) at screen column x: same linear-in-x
# basis the column loops use (validated against vanilla stepping)
evalscale(ds: Drawseg, x: int): int
{
	frac := 0;
	if (ds.tspan > 0)
		frac = int(((big(x) - big(ds.ox1)) << 16) / big(ds.tspan));
	return ds.s1 + rend->fixedmul(ds.s2 - ds.s1, frac);
}

# vanilla R_PointOnSegSide (r_main.c): 0 = right/front side, 1 = left.
# exact transcription incl. the sign-bit fast path (validated vs C on
# 200k random inputs); ~2147483647 is the 0x80000000 mask as an int.
pointonsegside(x, y, segnum: int): int
{
	seg := lev.segs[segnum];
	v1 := lev.vertices[seg.v1];
	v2 := lev.vertices[seg.v2];
	ldx := v2.x - v1.x;
	ldy := v2.y - v1.y;
	if (ldx == 0) {
		if (x <= v1.x) {
			if (ldy > 0)
				return 1;
			return 0;
		}
		if (ldy < 0)
			return 1;
		return 0;
	}
	if (ldy == 0) {
		if (y <= v1.y) {
			if (ldx < 0)
				return 1;
			return 0;
		}
		if (ldx > 0)
			return 1;
		return 0;
	}
	dx := x - v1.x;
	dy := y - v1.y;
	if (((ldy ^ ldx ^ dx ^ dy) & ~2147483647) != 0) {
		if (((ldy ^ dx) & ~2147483647) != 0)
			return 1;
		return 0;
	}
	left := rend->fixedmul(ldy >> 16, dx);
	right := rend->fixedmul(dy, ldx >> 16);
	if (right < left)
		return 0;
	return 1;
}

# ---- masked post draw (r_draw.c R_DrawMaskedColumn + colfunc) ----
# draws one opaque post [yl..yh] already clipped to the caller's clip
# arrays; light < 0 selects vanilla R_DrawFuzzColumn.  src[soff + k]
# with k = frac>>16 clamped to [0,len) (safe vs vanilla's unchecked
# read; identical when the screen math is exact, which it is).
maskpost(x, yl, yh, light, tmid, iscale: int,
		src: array of byte, soff, npx: int)
{
	# belt-and-braces screen clamp: a clip read from a drawseg is
	# already in [0..h], but an fb8 write outside it is a hard crash.
	if (yl < 0)
		yl = 0;
	if (yh >= h)
		yh = h - 1;
	if (yl > yh)
		return;
	if (light < 0) {
		r.drawfuzz(x, yl, yh);
		ncolumns++;
		return;
	}
	if (npx <= 0 || soff < 0 || soff + npx > len src)
		return;
	cm := light * 256;
	frac := tmid + (yl - r.centery) * iscale;
	dest := yl * r.w + x;
	for (i := yl; i <= yh; i++) {
		k := frac >> 16;
		if (k < 0)
			k = 0;
		if (k >= npx)
			k = npx - 1;
		r.fb8[dest] = r.colormap[cm + int src[soff + k]];
		dest += r.w;
		frac += iscale;
	}
	ncolumns++;
}

# ---- thing sprites (r_things.c) ----

# TEMP drop diagnostics for the sprite-disappearance hunt (silent
# unless view->dbgprints, set by doom -v)
pdrop(reason: string, a, b, c: int)
{
	if (dbgprints != 0)
		sys->print("PDROP f=%d %s a=%d b=%d c=%d\n",
			dbgframes, reason, a, b, c);
}

# project one mobj into the vissprite pool (vanilla R_ProjectSprite)
projectmo(mo: ref Game->Mobj)
{
	if (mo == nil || mo.removed || mo.subsector == nil)
		return;
	if (mo.sprite < 0 || mo.sprite >= len sprdefs) {
		pdrop("sprdef", mo.sprite, len sprdefs, 0);
		return;
	}
	trx := mo.x - vx;
	TRY := mo.y - vy;
	gxt := rend->fixedmul(trx, vcos);
	gyt := -rend->fixedmul(TRY, vsin);
	tz := gxt - gyt;
	if (tz < MINZ) {
		pdrop("minz", tz, mo.x, mo.y);
		return;
	}
	xscale := int(big(FRACUNIT) * big(FRACUNIT) * big(proj) / big(tz));
	if (xscale <= 0) {
		pdrop("xscale", xscale, tz, 0);
		return;
	}
	gxt = -rend->fixedmul(trx, vsin);
	gyt = rend->fixedmul(TRY, vcos);
	tx := -(gyt + gxt);
	atx := tx;
	if (atx < 0)
		atx = -atx;
	if (atx > (tz << 2)) {
		pdrop("atx", atx, tz, mo.sprite);
		return;
	}
	sd := sprdefs[mo.sprite];
	f := mo.frame & FF_FRAMEMASK;
	if (f < 0 || f >= len sd.frames) {
		pdrop("frm", f, len sd.frames, mo.sprite);
		return;
	}
	sfr := sd.frames[f];
	if (len sfr.lump == 0) {
		pdrop("nolump", f, mo.sprite, sfr.rotate);
		return;
	}
	rot := 0;
	flip := 0;
	if (sfr.rotate == 1) {
		if (gmod == nil) {
			pdrop("nomod", 0, 0, 0);
			return;
		}
		ang := gmod->pointtoangle2(vx, vy, mo.x, mo.y);
		rot = ((ang - mo.angle + ANG45HALF9) >> 29) & 7;
		if (sfr.lump[rot] < 0) {
			pdrop("rothole", rot, f, mo.sprite);
			return;
		}
		flip = sfr.flip[rot];
	} else {
		if (sfr.lump[0] < 0) {
			pdrop("lump0", f, mo.sprite, 0);
			return;
		}
	}
	lp := sfr.lump[rot];
	sp := sprpatch[lp];
	if (sp == nil) {
		pdrop("nopatch", lp, 0, 0);
		return;
	}
	cx := centerx << 16;
	txm := tx - sp.xoff;		# tx -= spriteoffset (16.16)
	x1 := (cx + rend->fixedmul(txm, xscale)) >> 16;
	if (x1 > w) {
		pdrop("x1off", x1, w, mo.sprite);
		return;
	}
	txm += sp.w << 16;		# tx += spritewidth (16.16)
	x2 := ((cx + rend->fixedmul(txm, xscale)) >> 16) - 1;
	if (x2 < 0) {
		pdrop("x2off", x2, 0, mo.sprite);
		return;
	}

	if (nvis >= MAXVISSPRITES) {
		pdrop("ovf", nvis, 0, 0);
		return;			# overflow: discarded, vanilla behavior
	}
	# build a local value and commit with a whole-struct assign at the
	# end: `ref viss[nvis]` COPIES the element instead of aliasing
	vis: Vissprite;
	vis.x1 = x1;
	if (vis.x1 < 0)
		vis.x1 = 0;
	vis.x2 = x2;
	if (vis.x2 >= w)
		vis.x2 = w - 1;
	vis.gx = mo.x;
	vis.gy = mo.y;
	vis.gz = mo.z;
	vis.gzt = mo.z + sp.yoff;
	vis.texturemid = vis.gzt - vz;
	vis.scale = xscale;
	iscale := int(16r100000000 / big(xscale));
	if (flip != 0) {
		vis.startfrac = (sp.w << 16) - 1;
		vis.xiscale = -iscale;
	} else {
		vis.startfrac = 0;
		vis.xiscale = iscale;
	}
	if (vis.x1 > x1)
		vis.startfrac += vis.xiscale * (vis.x1 - x1);
	vis.patch = lp;
	vis.mobjflags = mo.flags;

	# light (vanilla R_ProjectSprite): fuzz / fullbright / dim from the
	# thing's SECTOR lightnum (no orientation hack, that is walls only)
	if (mo.flags & Info->MF_SHADOW) {
		vis.light = -1;
	} else if (mo.frame & FF_FULLBRIGHT) {
		vis.light = 0;
	} else {
		sec := mo.subsector.sector;
		if (sec == nil) {
			pdrop("nosec", 0, 0, mo.sprite);
			return;
		}
		lnum := sec.lightlevel >> LIGHTSEGSHIFT;
		if (lnum < 0)
			lnum = 0;
		if (lnum >= LIGHTLEVELS)
			lnum = LIGHTLEVELS - 1;
		idx := xscale >> LIGHTSCALESHIFT;
		if (idx >= MAXLIGHTSCALE)
			idx = MAXLIGHTSCALE - 1;
		vis.light = scalelight[lnum][idx];
	}
	viss[nvis] = vis;
	if (dbgprints != 0 && (dbgframes % 2) == 0)
		sys->print("PROJ f=%d spr=%d fr=%d rot=%d flip=%d x1=%d x2=%d sc=%d tz=%d\n",
			dbgframes, mo.sprite, f, rot, flip, vis.x1, vis.x2,
			vis.scale, tz);
	nvis++;
}

# draw one vissprite through the clip arrays built by drawspscan
# (vanilla R_DrawVisSprite + R_DrawMaskedColumn)
drawvis(vis: ref Vissprite)
{
	if (vis.x1 > vis.x2)
		return;
	sp := sprpatch[vis.patch];
	if (sp == nil)
		return;
	frac := vis.startfrac;
	iscale := vis.xiscale;
	if (iscale < 0)
		iscale = -iscale;
	sprtop := (r.centery << 16) - rend->fixedmul(vis.texturemid, vis.scale);
	# TEMP clip profile: 'o' drew, 'c' had screen content all clipped
	# out, '.' no screen-visible post
	dbg := dbgprints != 0 && (dbgframes % 2) == 0;
	colst: array of byte;
	ccols := 0;
	nscr := 0;			# posts intersecting the screen rows
	if (dbg) {
		colst = array[vis.x2 - vis.x1 + 1] of byte;
		for (x := vis.x1; x <= vis.x2; x++)
			colst[x - vis.x1] = byte 16r2e;
	}
	for (x := vis.x1; x <= vis.x2; x++) {
		tc := frac >> 16;
		frac += vis.xiscale;
		if (tc < 0)
			tc = 0;
		if (tc >= sp.w)
			tc = sp.w - 1;
		pos := sp.colofs[tc];
		# walk the column's posts (vanilla: topdelta != 0xff)
		while (pos >= 0 && pos + 3 < len sp.raw) {
			td := int sp.raw[pos];
			if (td == 16rff)
				break;
			ln := int sp.raw[pos + 1];
			if (ln <= 0 || pos + 3 + ln > len sp.raw)
				break;
			topscreen := sprtop + vis.scale * td;
			bottomscreen := topscreen + vis.scale * ln;
			yl := (topscreen + 65535) >> 16;
			yh := (bottomscreen - 1) >> 16;
			yl0 := yl;
			yh0 := yh;
			if (yl0 < 0)
				yl0 = 0;
			if (yh0 > h - 1)
				yh0 = h - 1;
			if (yl0 <= yh0)
				nscr++;
			if (yl < sptop[x])
				yl = sptop[x];
			if (yh > spbot[x] - 1)
				yh = spbot[x] - 1;
			if (yl <= yh)
				maskpost(x, yl, yh, vis.light,
					vis.texturemid - (td << 16),
					iscale, sp.raw, pos + 3, ln);
			if (dbg) {
				if (yl <= yh)
					colst[x - vis.x1] = byte 16r6f;	# o
				else if (yl0 <= yh0 && colst[x - vis.x1] == byte 16r2e) {
					colst[x - vis.x1] = byte 16r63;	# c
					ccols++;
				}
			}
			pos += ln + 4;
		}
	}
	# TEMP report fully-clipped-out sprites with clip attribution
	if (dbg && ccols > 0) {
		sys->print("CMISS f=%d vx=%d vy=%d va=%d gx=%d gy=%d sc=%d x1=%d x2=%d c=%d %s\n",
			dbgframes, vx, vy, vangle, vis.gx, vis.gy, vis.scale,
			vis.x1, vis.x2, ccols, string colst);
		n := 0;
		for (x := vis.x1; x <= vis.x2 && n < 6; x++) {
			if (colst[x - vis.x1] != byte 16r63)
				continue;
			fi := cltopfrom[x];
			bi := clbotfrom[x];
			s1n := -1;
			s2n := -1;
			se1 := 0;
			se2 := 0;
			dx1 := 0;
			dx2 := 0;
			ds1 := 0;
			ds2 := 0;
			ox := 0;
			tsp := 1;
			ps := -1;
			if (fi >= 0) {
				s1n = dssegs[fi].segnum;
				se1 = evalscale(dssegs[fi], x);
				dx1 = dssegs[fi].x1;
				dx2 = dssegs[fi].x2;
				ds1 = dssegs[fi].s1;
				ds2 = dssegs[fi].s2;
				ox = dssegs[fi].ox1;
				tsp = dssegs[fi].tspan;
				ps = pointonsegside(vis.gx, vis.gy, dssegs[fi].segnum);
			}
			sys->print("  x=%d gz=%d gzt=%d top=%d fr=%d (seg %d s=%d dx=%d..%d ds=%d..%d ox=%d ts=%d ps=%d) bot=%d fr=%d\n",
				x, vis.gz, vis.gzt, sptop[x], fi, s1n, se1,
				dx1, dx2, ds1, ds2, ox, tsp, ps, spbot[x], bi);
			n++;
		}
	}
	# TEMP: projected sprite whose posts never touch the screen rows
	# (silent vanish: no CMISS record fires because ccols==0)
	if (dbg && nscr == 0)
		sys->print("POFF f=%d gx=%d gy=%d sc=%d x1=%d x2=%d gz=%d gzt=%d tmid=%d sprtop=%d\n",
			dbgframes, vis.gx, vis.gy, vis.scale, vis.x1, vis.x2,
			vis.gz, vis.gzt, vis.texturemid, sprtop);
}

# scan drawsegs for clipping, then draw (vanilla R_DrawSprite):
# newest seg first; behind-segs flush their masked mid and drop out;
# silhouette bits clear when the sprite is beyond them; first writer
# wins per column; remaining columns default to fully open.
drawspscan(vis: ref Vissprite)
{
	if (vis.x1 > vis.x2)
		return;
	for (x := vis.x1; x <= vis.x2; x++) {
		sptop[x] = -2;
		spbot[x] = -2;
		cltopfrom[x] = -1;
		clbotfrom[x] = -1;
	}
	for (i := nds - 1; i >= 0; i--) {
		ds := dssegs[i];
		if (ds.x1 > vis.x2 || ds.x2 < vis.x1
		    || (ds.sil == 0 && ds.midxex == nil))
			continue;
		r1 := ds.x1;
		if (r1 < vis.x1)
			r1 = vis.x1;
		r2 := ds.x2;
		if (r2 > vis.x2)
			r2 = vis.x2;
		e1 := evalscale(ds, ds.x1);
		e2 := evalscale(ds, ds.x2);
		scale := e1;
		lowscale := e2;
		if (e2 > e1) {
			scale = e2;
			lowscale = e1;
		}
		if (scale < vis.scale
		    || (lowscale < vis.scale
		        && pointonsegside(vis.gx, vis.gy, ds.segnum) == 0)) {
			# seg is behind the sprite: draw its masked mid first
			if (ds.midxex != nil)
				flushmask(i, r1, r2);
			continue;
		}
		sil := ds.sil;
		if (vis.gz >= ds.bsilh)
			sil &= ~SIL_BOTTOM;
		if (vis.gzt <= ds.tsilh)
			sil &= ~SIL_TOP;
		if ((sil & SIL_BOTTOM) != 0) {
			for (x = r1; x <= r2; x++)
				if (spbot[x] == -2) {
					spbot[x] = ds.bot[x];
					clbotfrom[x] = i;
				}
		}
		if ((sil & SIL_TOP) != 0) {
			for (x = r1; x <= r2; x++)
				if (sptop[x] == -2) {
					sptop[x] = ds.top[x];
					cltopfrom[x] = i;
				}
		}
	}
	for (x = vis.x1; x <= vis.x2; x++) {
		if (spbot[x] == -2)
			spbot[x] = h;
		if (sptop[x] == -2)
			sptop[x] = 0;
	}
	drawvis(vis);
}

# flush one drawseg's masked mid columns [x1..x2] (vanilla
# R_RenderMaskedSegRange): per-column scale/light from the shared
# basis, texturemid base set at claim time, mflag makes it idempotent
# (vanilla's maskedtexturecol = SHRT_MAX marker)
flushmask(dsidx, x1, x2: int)
{
	ds := dssegs[dsidx];
	if (ds.midxex == nil || ds.mcol == nil || x1 > x2)
		return;
	tex := ds.midxex;
	posts := tex.posts;
	if (posts == nil)
		return;
	for (x := x1; x <= x2; x++) {
		if (ds.mflag[x] != 1)
			continue;
		s := evalscale(ds, x);
		if (s <= 0)
			continue;
		lidx := s >> LIGHTSCALESHIFT;
		if (lidx >= MAXLIGHTSCALE)
			lidx = MAXLIGHTSCALE - 1;
		light := scalelight[ds.walllight][lidx];
		iscale := int(16r100000000 / big(s));
		col := ds.mcol[x];
		col %= tex.width;
		if (col < 0)
			col += tex.width;
		sprtop := (r.centery << 16)
			- rend->fixedmul(ds.tmidbase, s);
		p := posts[col];
		if (p == nil) {
			ds.mflag[x] = 2;
			continue;
		}
		for (j := 0; j + 1 < len p; j += 2) {
			td := p[j];
			ln := p[j + 1];
			topscreen := sprtop + s * td;
			bottomscreen := topscreen + s * ln;
			yl := (topscreen + 65535) >> 16;
			yh := (bottomscreen - 1) >> 16;
			if (yl < ds.top[x])
				yl = ds.top[x];
			if (yh > ds.bot[x] - 1)
				yh = ds.bot[x] - 1;
			if (yl <= yh)
				maskpost(x, yl, yh, light,
					ds.tmidbase - (td << 16),
					iscale, tex.data,
					col * tex.height + td, ln);
		}
		ds.mflag[x] = 2;
	}
}

# vanilla R_DrawMasked: sprites back-to-front (ascending scale, far
# first), then any masked mid not yet flushed.  psprites come later
# (weapon milestone).
drawmasked()
{
	if (nvis > 1) {
		ord := array[nvis] of int;
		for (i := 0; i < nvis; i++)
			ord[i] = i;
		for (i = 0; i < nvis; i++) {
			best := i;
			for (j := i + 1; j < nvis; j++)
				if (viss[ord[j]].scale < viss[ord[best]].scale)
					best = j;
			if (best != i) {
				t := ord[i];
				ord[i] = ord[best];
				ord[best] = t;
			}
		}
		for (i = 0; i < nvis; i++)
			drawspscan(ref viss[ord[i]]);
	} else if (nvis == 1) {
		drawspscan(ref viss[0]);
	}
	for (i := nds - 1; i >= 0; i--) {
		if (dssegs[i].midxex != nil) {
			flushmask(i, dssegs[i].x1, dssegs[i].x2);
			nmasked++;
		}
	}
}

# ---- sprite defs from the WAD (r_data.c R_InitSpriteDefs) ----

le16(d: array of byte, o: int): int
{
	return int d[o] | (int d[o + 1] << 8);
}

le16s(d: array of byte, o: int): int
{
	v := int d[o] | (int d[o + 1] << 8);
	if (v >= 32768)
		v -= 65536;
	return v;
}

le32(d: array of byte, o: int): int
{
	return int d[o] | (int d[o + 1] << 8)
		| (int d[o + 2] << 16) | (int d[o + 3] << 24);
}

# read + parse one sprite patch lump (header + column directory kept
# with the raw bytes: posts are walked from raw like vanilla)
loadsprpatch(idx: int): (string, ref SprPatch)
{
	(d, err) := wfile.read(idx);
	if (err != nil)
		return (err, nil);
	if (len d < 8)
		return ("short patch header", nil);
	pw := le16(d, 0);
	ph := le16(d, 2);
	if (pw <= 0 || ph <= 0 || pw > 1024 || ph > 1024)
		return ("bad patch size", nil);
	if (len d < 8 + 4 * pw)
		return ("short columnofs", nil);
	xoff := le16s(d, 4) << 16;	# leftoffset -> 16.16
	yoff := le16s(d, 6) << 16;	# topoffset -> 16.16
	colofs := array[pw] of int;
	for (i := 0; i < pw; i++) {
		colofs[i] = le32(d, 8 + 4 * i);
		if (colofs[i] < 8 + 4 * pw || colofs[i] >= len d)
			return ("bad columnofs", nil);
	}
	return (nil, ref SprPatch(pw, ph, xoff, yoff, colofs, d));
}

# vanilla R_InstallSpriteLump; errors degrade to skipping the entry
# (vanilla I_Errors -- our final completeness check drops the sprite)
instlump(frame, rot, lumpidx, flipped: int)
{
	if (frame < 0 || frame >= 29 || rot < 0 || rot > 8)
		return;
	if (frame > sprmaxf)
		sprmaxf = frame;
	if (rot == 0) {
		if (sprtemp[frame].rotate != -1)
			return;	# dup/conflict: keep the first (vanilla errors)
		sprtemp[frame].rotate = 0;
		for (ri := 0; ri < 8; ri++) {
			sprtemp[frame].lump[ri] = lumpidx;
			sprtemp[frame].flip[ri] = flipped;
		}
		return;
	}
	if (sprtemp[frame].rotate == 0)
		return;
	sprtemp[frame].rotate = 1;
	ri := rot - 1;
	if (sprtemp[frame].lump[ri] >= 0)
		return;		# duplicate rotation: keep first
	sprtemp[frame].lump[ri] = lumpidx;
	sprtemp[frame].flip[ri] = flipped;
}

# build sprdefs[] from S_START..S_END lumps vs Info->sprnames
# (vanilla R_InitSpriteDefs)
loadsprdefs(): string
{
	if (inf == nil) {
		inf = load Info Info->PATH;
		if (inf == nil)
			return "view: can't load Info module";
		# each load gets a fresh module value: build our tables
		ierr := inf->init();
		if (ierr != nil)
			return ierr;
	}
	names := inf->sprnames;
	if (names == nil || len names == 0)
		return "view: no sprnames in Info";
	s0 := wfile.find("S_START");
	s1 := wfile.find("S_END");
	if (s0 < 0 || s1 < 0 || s1 <= s0)
		return "view: no S_START/S_END markers in WAD";
	sprfirst = s0 + 1;
	nlumps := s1 - s0 - 1;
	sprpatch = array[nlumps] of ref SprPatch;
	for (i := 0; i < nlumps; i++) {
		(perr, p) := loadsprpatch(sprfirst + i);
		if (perr != nil)
			return sys->sprint("view: sprite lump %d: %s",
				sprfirst + i, perr);
		sprpatch[i] = p;
	}
	sprdefs = array[len names] of SprDef;
	sprtemp = array[29] of SpriteFrame;
	for (si := 0; si < len names; si++) {
		sprname = names[si];
		for (f := 0; f < 29; f++) {
			sprtemp[f].rotate = -1;
			sprtemp[f].lump = array[8] of int;
			sprtemp[f].flip = array[8] of int;
			for (ri := 0; ri < 8; ri++) {
				sprtemp[f].lump[ri] = -1;
				sprtemp[f].flip[ri] = 0;
			}
		}
		sprmaxf = -1;
		for (l := sprfirst; l < sprfirst + nlumps; l++) {
			ln := wfile.lumps[l].name;
			if (len ln < 6 || !samename(ln, sprname))
				continue;
			instlump(int ln[4] - int 'A',
				int ln[5] - int '0', l - sprfirst, 0);
			if (len ln > 7 && ln[6] != 0) {
				instlump(int ln[6] - int 'A',
					int ln[7] - int '0', l - sprfirst, 1);
			}
		}
		if (sprmaxf < 0) {
			sprdefs[si].frames = array[0] of SpriteFrame;
			continue;
		}
		# completeness: vanilla I_Errors; we drop the sprite (invisible)
		bad := 0;
		for (f = 0; f <= sprmaxf; f++) {
			if (sprtemp[f].rotate == -1)
				bad = 1;
			if (sprtemp[f].rotate == 1) {
				for (ri := 0; ri < 8; ri++)
					if (sprtemp[f].lump[ri] < 0)
						bad = 1;
			}
		}
		if (bad) {
			sys->print("view: sprite %s incomplete frames, skipped\n",
				sprname);
			sprdefs[si].frames = array[0] of SpriteFrame;
			continue;
		}
		frames := array[sprmaxf + 1] of SpriteFrame;
		for (f = 0; f <= sprmaxf; f++)
			frames[f] = sprtemp[f];
		sprdefs[si].frames = frames;
	}
	return nil;
}

# first 4 chars equal (lump name vs 4-char sprite name)
samename(s, p: string): int
{
	if (len p != 4 || len s < 4)
		return 0;
	return s[0] == p[0] && s[1] == p[1] && s[2] == p[2] && s[3] == p[3];
}

# Find or create a visplane for the given z/flat/light.  Returns the
# index into vps, or -1 if the table is full.  Planes are interned so
# many segs sharing a floor contribute to one plane.
findplane(z: int, flatname: string, light: int): int
{
	# vanilla R_FindPlane (r_plane.c:218): sky forces height=0 and
	# light=0 -- all skys map together into one plane, so sky-sky
	# portals join it seamlessly regardless of sector heights/lights.
	if (flatname == SKYFLAT) {
		z = 0;
		light = 0;
	}
	for (i := 0; i < nvp; i++) {
		if (vps[i].z == z && vps[i].flatname == flatname && vps[i].light == light)
			return i;
	}
	if (nvp >= MAXVISPLANES)
		return -1;
	vps[nvp].z = z;
	vps[nvp].flatname = flatname;
	vps[nvp].light = light;
	vps[nvp].minx = w;
	vps[nvp].maxx = -1;
	for (x := 0; x < MAXVISW; x++) {
		vps[nvp].top[x] = -1;
		vps[nvp].bottom[x] = -1;
	}
	return nvp++;
}

# Vanilla R_CheckPlane (r_plane.c): decide whether this seg's claims can
# join the interned visplane `pl` or need a fresh duplicate.  If the
# seg's column range [x1..x2] contains a column the plane already
# claims, a second claim in that column would overwrite the first, so
# spawn a copy with the same z/flat/light and claim into that instead.
# This keeps each plane's per-column strip exact (no min/max fusing of
# disjoint strips), which is what makes draw order irrelevant: every row
# of every column is claimed by exactly one plane.
checkplane(pl, x1, x2: int): int
{
	lo: int;
	hi: int;
	x: int;
	if (pl < 0)
		return pl;
	lo = x1;
	if (lo < vps[pl].minx)
		lo = vps[pl].minx;
	hi = x2;
	if (hi > vps[pl].maxx)
		hi = vps[pl].maxx;
	if (lo > hi)
		return pl;	# no overlap with claimed span: reuse
	for (x = lo; x <= hi; x++)
		if (vps[pl].top[x] >= 0)
			break;
	if (x > hi)
		return pl;	# span overlaps but no column claimed: reuse
	if (nvp >= MAXVISPLANES)
		return pl;	# table full: reuse (worst case, strips fuse)
	np := nvp;
	vps[np].z = vps[pl].z;
	vps[np].light = vps[pl].light;
	vps[np].flatname = vps[pl].flatname;
	vps[np].minx = x1;
	vps[np].maxx = x2;
	for (x = 0; x < MAXVISW; x++) {
		vps[np].top[x] = -1;
		vps[np].bottom[x] = -1;
	}
	nvp++;
	return np;
}

# Mark plane `pl` exposing screen rows [t..b] (inclusive) in column x.
# The strip is clamped to the column's open window solid[2*x]..
# solid[2*x+1]-1 -- the vanilla R_RenderSegLoop claim clamps against
# ceilingclip/floorclip -- so a plane can only claim rows no wall has
# covered: planes can never paint over walls.  Planes cannot paint over
# each other either: the front-to-back walk advances the clips at every
# wall and portal so each row of each column is offered to exactly one
# plane (vanilla's clip partition), and checkplane keeps same-plane
# re-claims from fusing disjoint strips.  Empty strips are dropped.
markplane(pl, x, t, b: int)
{
	if (pl < 0 || x < 0 || x >= w)
		return;
	if (t < solid[2*x])
		t = solid[2*x];
	if (b > solid[2*x+1] - 1)
		b = solid[2*x+1] - 1;
	if (t < 0)
		t = 0;
	if (b >= h)
		b = h - 1;
	if (t > b)
		return;
	if (x < vps[pl].minx)
		vps[pl].minx = x;
	if (x > vps[pl].maxx)
		vps[pl].maxx = x;
	vps[pl].top[x] = t;
	vps[pl].bottom[x] = b;
}

# Emit the spans for one plane: walk columns minx..maxx and, wherever a
# column has a marked [top,bottom], walk the row run and hand each row's
# x-run to mapplane.  Rows with no mark in this column close the run.
drawplanes()
{
	for (pl := 0; pl < nvp; pl++) {
		vp := vps[pl];
		if (vp.minx > vp.maxx)
			continue;
		# sky (vanilla R_DrawPlanes, r_plane.c:390): drawn as wall
		# texture columns, fullbright (colormap row 0), iscale =
		# pspriteiscale = FRACUNIT*SCREENWIDTH/viewwidth = 1.0 (one
		# texel per screen pixel), texturemid = skytexturemid =
		# 100*FRACUNIT which puts texture row 0 at screen row 0 when
		# centery = 100.  Column = (viewangle + xtoviewangle[x]) >>
		# 22 (r_sky.h ANGLETOSKYSHIFT) = ((vangle>>19)+xtofine[x])>>
		# 3 in fine units, wrapped by tex.width in rdrawcolumn: the
		# sky turns with the view, no parallax, vertical wrap every
		# tex.height rows (vanilla behavior on 200-line screens).
		if (vp.flatname == SKYFLAT) {
			sky := rend->rtexture(r, SKYTEX);
			if (sky != nil) {
				for (x := vp.minx; x <= vp.maxx; x++) {
					yl := vp.top[x];
					if (yl < 0)
						continue;
					col := ((vangle >> ANGLETOFINESHIFT) + xtofine[x]) >> 3;
					rend->rdrawcolumn(r, x, yl, vp.bottom[x], 0,
						sky, col, SKYMID, FRACUNIT);
				}
			}
			continue;
		}
		fl := rend->rflat(r, vp.flatname);
		if (fl == nil)
			continue;
		plfl = fl;
		# spanstart[y] = x where the current run on row y began; -1 = closed
		spanstart := array[h] of int;
		y := 0;
		for (y = 0; y < h; y++)
			spanstart[y] = -1;
		for (x := vp.minx; x <= vp.maxx; x++) {
			t := vp.top[x];
			b := vp.bottom[x];
			# close runs on rows that no longer expose this plane
			for (y = 0; y < h; y++) {
				if (spanstart[y] >= 0 && (t < 0 || y < t || y > b)) {
					mapplane(y, spanstart[y], x - 1, vp.z, vp.light);
					spanstart[y] = -1;
				}
			}
			if (t < 0)
				continue;
			# open or continue runs on rows that expose it
			for (y = t; y <= b; y++) {
				if (spanstart[y] < 0)
					spanstart[y] = x;
			}
		}
		# close any runs still open at maxx
		for (y = 0; y < h; y++) {
			if (spanstart[y] >= 0) {
				mapplane(y, spanstart[y], vp.maxx, vp.z, vp.light);
				spanstart[y] = -1;
			}
		}
	}
}

# Texture-map one flat span on screen row y, columns x1..x2 inclusive.
# Vanilla R_MapPlane (r_plane.c).  A flat's world position is recoverable
# from screen coords alone: depth = planeheight * yslope[y], and the ray
# through column x makes angle atan((x-centerx)/proj) with the view
# direction.  world offset = forward*depth + right*(depth*tan).
#
# planez: the plane's world z (16.16); light: the visplane's vanilla
# light index i (lightlevel>>4), NOT a colormap row -- the row is picked
# per distance band via zlight like vanilla R_MapPlane.
	mapplane(y, x1, x2, planez, light: int)
	{
		nspans++;
		if (y < 0 || y >= h)
		return;
	if (x1 < 0)
		x1 = 0;
	if (x2 >= w)
		x2 = w - 1;
	if (x1 > x2)
		return;
	fl := plfl;
	if (fl == nil)
		return;

	# eye-to-plane vertical distance, 16.16 (vanilla: abs(planeheight)).
	dz := planez - vz;
	if (dz < 0)
		dz = -dz;

	# depth from eye to the plane point on this row, 16.16.  yslope is
	# 16.16, so fixedmul(dz, yslope) = proj/|dy| * dz (both 16.16).
	distance := rend->fixedmul(dz, yslope[y]);
	if (distance <= 0)
		return;

	# vanilla R_MapPlane (r_plane.c:160-162): colormap row =
	# planezlight[distance >> LIGHTZSHIFT], band clamped to MAXLIGHTZ-1
	# (row 0 = fullbright near, startmap far).
	band := distance >> LIGHTZSHIFT;
	if (band >= MAXLIGHTZ)
		band = MAXLIGHTZ - 1;
	lv := light;
	if (lv < 0)
		lv = 0;
	if (lv >= LIGHTLEVELS)
		lv = LIGHTLEVELS - 1;
	row := zlight[lv][band];

	# vanilla R_MapPlane (r_plane.c:148-151): length is the scalar world
	# reach along the column's ray; the origin offset is a SINGLE fixedmul
	# per component from the column's absolute view angle.  The earlier
	# port composed a per-column ray (forward*cos(delta)+right*sin(delta))
	# and rotated length through it: mathematically the same, but three
	# rounded fixedmuls accumulate low-bit error that grows with delta, so
	# the texture origin drifted as the camera turned (shear at rotation,
	# none at the default angle where delta=0).  Vanilla does one fixedmul.
	length := rend->fixedmul(distance, distscale[x1]);	# = distance/cos
	# column angle = viewangle + xtoviewangle[x1]; the fine index of that
	# angle is vangle's fine part + the precomputed per-column xtofine[x1].
	idx := ((vangle >> ANGLETOFINESHIFT) + xtofine[x1]) & FINEMASK;
	# finecosine[idx] = finesine[idx+2048]; one fixedmul per component
	xfrac := vx + rend->fixedmul(fsine[(idx + 2048) & FINEMASK], length);
	yfrac := -vy - rend->fixedmul(fsine[idx], length);

	# Step along the same right axis as the start ray, scaled by distance:
	#   xstep = distance*basexscale, ystep = distance*baseyscale
	# (basexscale/baseyscale already carry the right-axis signs).
	xstep := rend->fixedmul(distance, basexscale);
	ystep := rend->fixedmul(distance, baseyscale);

	rend->rdrawspan(r, y, x1, x2, row, fl, xfrac, yfrac, xstep, ystep);
	nspans++;
}

# integer square root (for line length)
isqrt(n: int): int
{
	if (n <= 0)
		return 0;
	x := n;
	y := (x + 1) / 2;
	while (y < x) {
		x = y;
		y = (x + n / x) / 2;
	}
	return x;
}

# build local fine-sine table, replacing the Info.finesine dependency.
# EXACT Doom formula (verified against the real tables.c / info.b table,
# max error 2 over all 10240 entries):
#   finesine[k] = round(sin((k + 0.5) * PI/4096) * 65536)
# i.e. the argument step is PI/4096 (full circle at k=8192=FINEANGLES)
# with a half-step phase.  Then finecosine = &finesine[FINEANGLES/4]:
#   finecosine[k] = finesine[k+2048] = sin((k+2048.5)*PI/4096)
#                 = sin((k+0.5)*PI/4096 + PI/2) = cos((k+0.5)*PI/4096).
# The OLD generator used PI/2048 (DOUBLE frequency) with no half-step and
# a Taylor series truncated at x^7 (0.23 rad error at x=pi) -- the table
# was garbage, which is why no origin/step algebra fix ever helped:
# the shear was baked in before any sign mattered.
buildfsine()
{
	fsine = array[FINESINELEN] of int;
	FRAC := big(65536) * big(65536);	# 2^32, shifts 16.16 back down
	for (k := 0; k < FINESINELEN; k++) {
		# fold into [0, 2048] where sin is monotone:
		#   [4096,8192): sin(2pi-x)=-sin(x)  -> m=k-4096, sign=-1
		#   [2048,4096): sin(pi-x)=sin(x)    -> m=4095-k
		m := k % 8192;
		sign := 1;
		if (m >= 4096) {
			m -= 4096;
			sign = -1;
		}
		if (m >= 2048)
			m = 4095 - m;
		# x = (m + 0.5) * PI/4096 in 16.16, i.e. (2m+1)*PI/8192.
		# PI/8192 in 16.16 = 65536*pi/8192 = 25.1327412 -> 251327/10000.
		# x in [0, ~pi/2], where Taylor x^11 truncation error < 1 LSB.
		x := int(big(2 * m + 1) * big(251327) / big(10000));
		xb := big(x);
		x3 := xb * xb * xb / FRAC;	# x^3 in 16.16
		x5 := x3 * xb * xb / FRAC;
		x7 := x5 * xb * xb / FRAC;
		x9 := x7 * xb * xb / FRAC;
		x11 := x9 * xb * xb / FRAC;
		s := xb - x3 / big(6) + x5 / big(120) - x7 / big(5040)
			+ x9 / big(362880) - x11 / big(39916800);
		fsine[k] = int(s) * sign;
	}
}
