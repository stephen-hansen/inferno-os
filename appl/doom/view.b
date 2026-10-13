implement View;

include "sys.m";
	sys: Sys;
include "wad.m";
	wad: Wad;
include "rend.m";
	rend: Rend;
include "map.m";
	mapm: Map;
include "view.m";

# fine-angle table constants (mirror game.m; view.b does not import game.m).
# finesine[k] = sin(k*PI/2048) in 16.16; finecosine[k] = finesine[k+2048].
# view builds its own local table so it does not depend on Info.init().
ANGLETOFINESHIFT:	con 19;
FINEMASK:		con 8191;
FINEANGLES:		con 8192;
FINESINELEN:		con 10240;	# full sine + 1 extra quadrant for finecosine
fsine:	array of int;	# local sine table, built once in init()

# camera state (set at start of render)
vx, vy, vz:	int;	# 16.16
vangle:		int;	# BAM
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
	light:	int;		# colormap row 0..31
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

init(rr: ref Rend->Renderer, l: ref Map->Level, width, height: int): string
{
	if (sys == nil)
		sys = load Sys Sys->PATH;
	sys->print("view.init: start\n");
	if (rr == nil)
		return "view.init: nil renderer";
	if (l == nil)
		return "view.init: nil level";
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
	w = width;
	h = height;
	proj = width / 2;		# 90-degree horizontal FOV (raw pixels)
	centerx = width / 2;
	solid = array[w * 2] of int;

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

	# visplane slots
	vps = array[MAXVISPLANES] of Visplane;
	for (i := 0; i < MAXVISPLANES; i++) {
		vps[i] = Visplane(z := 0, light := 0, flatname := "",
			minx := w, maxx := -1,
			top := array[MAXVISW] of int,
			bottom := array[MAXVISW] of int);
		for (x := 0; x < MAXVISW; x++) {
			vps[i].top[x] = -1;
			vps[i].bottom[x] = -1;
		}
	}
	nvp = 0;
	curfloor = curceil = -1;
	return nil;
}

render(viewx, viewy, viewz, viewangle, viewcos, viewsin: int)
{
	if (r == nil || lev == nil)
		return;
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

	# clear to black
	rend->rclear(r, 0);

	# reset occlusion: full screen open in every column
	for (x := 0; x < w; x++) {
		solid[2*x] = -1;	# first open row (vanilla ceilingclip+1)
		solid[2*x+1] = h;	# one past last open row (vanilla floorclip)
	}

	# reset visplanes for this frame
	nvp = 0;
	curfloor = curceil = -1;

	# walk BSP front-to-back from the root
	if (len lev.nodes > 0)
		renderbsp(len lev.nodes - 1);
	else if (len lev.subsectors > 0)
		rendersubsector(0);

	# flush accumulated floor/ceiling spans to screen
	drawplanes();
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
	u1 = seg.offset;
	u2 = seg.offset + linelen;

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

	# choose texture
	texname := sd.midtexture;
	if (back != nil) {
		# two-sided: draw upper and lower, skip middle
		drawtwosided(sd, lx1, lx2, ox1, ox2, d1, d2, u1, u2,
			ceilz, floorz, back.ceilingheight, back.floorheight,
			back.ceilingtexture);
		return;
	}
	if (texname == "" || texname == "-")
		return;
	tex := rend->rtexture(r, texname);
	if (tex == nil)
		return;

	# light level (simplified: constant from sector)
	light := (sec.lightlevel * 31) / 255;
	if (light < 0)
		light = 0;
	if (light > 31)
		light = 31;

	# intern this sector's floor/ceiling planes for the column loop below.
	# vanilla R_Subsector only picks a floorplane below the eye and a
	# ceilingplane above it (or sky): outside those bounds the plane is
	# not visible and claiming with it paints garbage.  checkplane then
	# decides per seg whether claims join the interned visplane or a
	# duplicate (vanilla R_CheckPlane), keeping per-column strips exact.
	curfloor = -1;
	if (floorz < vz)
		curfloor = checkplane(findplane(floorz, sec.floortexture, light),
			lx1, lx2);
	curceil = -1;
	if (ceilz > vz || sec.ceilingtexture == SKYFLAT)
		curceil = checkplane(findplane(ceilz, sec.ceilingtexture, light),
			lx1, lx2);

	# perspective-correct: scale (px per world unit, 16.16) is linear
	# in screen x; depth is derived per column.  Vanilla steps
	# rw_scale linearly (r_segs.c).  Linear depth bends wall edges.
	# clamp depth so scale stays in int32 (near-plane clip can leave
	# tiny positive depths)
	dd1 := d1;
	dd2 := d2;
	if (dd1 < FRACUNIT / 4)
		dd1 = FRACUNIT / 4;
	if (dd2 < FRACUNIT / 4)
		dd2 = FRACUNIT / 4;
	s1 := int(big(FRACUNIT) * big(FRACUNIT) * big(proj) / big(dd1));
	s2 := int(big(FRACUNIT) * big(FRACUNIT) * big(proj) / big(dd2));
	# u is linear in wall-parameter, MOBIUS in screen x (vanilla
	# gets this right via finetangent per column).  u/depth and
	# 1/depth are both linear in screen x, so interp those and
	# divide.  big: u1<<16 overflows int32 (u up to 4000 units).
	ud1 := int((big(u1) << 16) / big(dd1));	# u/depth, 16.16
	ud2 := int((big(u2) << 16) / big(dd2));
	id1 := int(16r100000000 / big(dd1));	# 1/depth, 16.16
	id2 := int(16r100000000 / big(dd2));

	# draw columns lx1..lx2; frac spans the ORIGINAL x span
	tspan := ox2 - ox1;
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

		if (yt <= yb) {
			# texture mapping
			col := u >> 16;
			# iscale: 16.16 texture units per screen pixel = 2^32/scale.
			# int-safe when scale>=2^16 (result<=2^16); else big (rare: very close walls).
			iscale: int;
			if (scale >= 16r10000)
				iscale = int(big(16r100000000) / big(scale));
			else
				iscale = int(16r100000000 / big(scale));
			# texturemid: world z above eye, 16.16 texels (1 texel = 1 unit)
			tmid := z1t + rend->fixedmul(z2t - z1t, frac) - vz;
			rend->rdrawcolumn(r,x, yt, yb, light, tex, col, tmid, iscale);
			ncolumns++;
		}

		# a solid wall is terminal: close the column completely
		# (vanilla sets ceilingclip=viewheight, floorclip=-1).
		solid[2*x] = h;
		solid[2*x+1] = -1;
	}
}

# two-sided line: draw upper and lower textures where heights differ
drawtwosided(sd: ref Map->Side,
	lx1, lx2, ox1, ox2, d1, d2, u1, u2: int,
	fceilz, ffloorz, bceilz, bfloorz: int, bceiltex: string)
{
	nsegs++;
	dd1 := d1;
	dd2 := d2;
	if (dd1 < FRACUNIT / 4)
		dd1 = FRACUNIT / 4;
	if (dd2 < FRACUNIT / 4)
		dd2 = FRACUNIT / 4;
	s1 := int(big(FRACUNIT) * big(FRACUNIT) * big(proj) / big(dd1));
	s2 := int(big(FRACUNIT) * big(FRACUNIT) * big(proj) / big(dd2));
	# perspective-correct u via u/depth and 1/depth (linear in x)
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
	flight := 0;
	clight := 0;
	if (fsec != nil) {
		flight = (fsec.lightlevel * 31) / 255;
		if (flight < 0) flight = 0;
		if (flight > 31) flight = 31;
		clight = flight;
	}
	frontfloor := -1;
	if (ffloorz < vz)
		frontfloor = checkplane(findplane(ffloorz, fsec.floortexture, flight),
			lx1, lx2);
	frontceil := -1;
	if (fceilz > vz || fsec.ceilingtexture == SKYFLAT)
		frontceil = checkplane(findplane(fceilz, fsec.ceilingtexture, clight),
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

		cclip := solid[2*x];
		fclip := solid[2*x+1];
		light := 0;
		sec := sd.sector;
		if (sec != nil) {
			light = (sec.lightlevel * 31) / 255;
			if (light < 0) light = 0;
			if (light > 31) light = 31;
		}

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
					# upper texture anchored at the top:
					# texture row 0 at fceilz going down
					tmid := fceilz - vz;
					rend->rdrawcolumn(r,x, yt, yb, light, tex, col, tmid, iscale);
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
					# lower texture anchored at bottom:
					# texture row 0 at bfloorz going down... vanilla
					# uses (bfloorz - viewz) but offset by texture height
					tmid := bfloorz - vz;
					rend->rdrawcolumn(r,x, yt, yb, light, tex, col, tmid, iscale);
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
		# This mirrors vanilla's "no top/bottom wall" clip branches
		# (ceilingclip = yl-1, floorclip = yh+1); vanilla gates those on
		# markceiling/markfloor, but the gate only suppresses the advance
		# when both sides share the plane, and then the next seg claims
		# with identical z/flat/light and joins the same visplane anyway.
		if (fctop > cclip)
			cclip = fctop;
		if (flbot + 1 < fclip)
			fclip = flbot + 1;

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
# planez: the plane's world z (16.16); light: colormap row 0..31.
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

	rend->rdrawspan(r, y, x1, x2, light, fl, xfrac, yfrac, xstep, ystep);
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
