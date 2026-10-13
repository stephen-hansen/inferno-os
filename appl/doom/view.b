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

# camera state (set at start of render)
vx, vy, vz:	int;	# 16.16
vangle:		int;	# BAM
vcos, vsin:	int;	# 16.16

# renderer state (set by init)
r:	ref Rend->Renderer;
lev:	ref Map->Level;
w, h:	int;
proj:	int;		# 16.16 focal length (= centerx for 90deg FOV)
solid:	array of int;	# per-column occlusion: solid[2*x]=ceilclip, solid[2*x+1]=floorclip

# Shared per-column floor/ceiling claiming lines for visplane occlusion.
# The walk is front-to-back, so each floor plane claims only rows below
# floorline[x] (the bottom of the nearest floor seen so far) and then
# raises the line; each ceiling plane claims only rows above ceilline[x]
# (the top of the nearest ceiling) and then lowers it.  A farther plane
# can thus never paint over a nearer one, which fixes the blue-over-gray
# floor overdraw and makes adjacent floor segments meet flush.  Reset to
# h/-1 each frame.
floorline:	array of int;
ceilline:	array of int;

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
centerx:	int;
basexscale:	int;	# world u step per unit depth along right axis (16.16)
baseyscale:	int;	# world v step per unit depth (16.16)
plfl:	ref Rend->Flat;	# flat bound for the mapplane call below

# plane params for the seg being drawn; addline/drawtwosided set these
# before marking, so markfloor/markceil know what to intern.
markz:	array of int;	# [0]=floor z, [1]=ceiling z, 16.16
marklight:	array of int;	# [0]=floor, [1]=ceiling, colormap 0..31
markflat:	array of string;	# [0]=floor, [1]=ceiling flat names

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
	r = rr;
	lev = l;
	w = width;
	h = height;
	proj = width / 2;		# 90-degree horizontal FOV (raw pixels)
	centerx = width / 2;
	solid = array[w * 2] of int;
	floorline = array[w] of int;
	ceilline = array[w] of int;

	# plane texture-mapping table.  yslope[y] = proj/|dy| (16.16) scales
	# the eye-to-plane vertical distance into a per-row depth; vanilla
	# r_main.c uses abs(dy).  distscale[x] = cos(ray through x), the
	# lateral (cosine) correction so edges don't stretch.
	yslope = array[h] of int;
	for (y := 0; y < h; y++) {
		dyp := y - r.centery;
		if (dyp < 0)
			dyp = -dyp;
		if (dyp < 1)
			dyp = 1;
		# yslope = proj/dyp as a 16.16 ratio (both raw pixels).  then
		# distance = fixedmul(dz, yslope) is a 16.16 depth.
		yslope[y] = int((big(proj) << 16) / big dyp);
	}
	distscale = array[w] of int;
	for (x := 0; x < w; x++) {
		td := ((x - centerx) << 16) / proj;	# tan(delta), 16.16
		if (td < 0)
			td = -td;
		# cos(delta) = 1/sqrt(1+tan^2), 16.16.  the sum 1+tan^2 overflows
		# int32 near the screen edge (tan ~1.0 -> sum ~2<<16, squared ~2^33),
		# so build it in big; isqrt returns 16.16 directly.
		t2 := int(big(td) * big(td) / big(16r10000));
		sum := 16r10000 + t2;
		sq := isqrt(sum << 16);		# sqrt(1+tan^2) = 1/cos, 16.16
		if (sq <= 0)
			distscale[x] = 16r10000;	# 1/cos = 1.0
		else
			distscale[x] = sq;	# 1/cos(delta), 16.16 -- vanilla r_main.c:736 distscale[i]=FRACUNIT/cosadj.  MUST be 1/cos, NOT cos: length=distance/cos so the cos in the unit direction cancels, giving a clean reach of `distance` along forward + lateral distance*tan.  Storing cos made the offset short by cos^2 -> edges shrank toward center = the rotation warp.
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
	markz = array[2] of int;
	marklight = array[2] of int;
	markflat = array[2] of string;
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
	# per-frame plane step axes (vanilla R_ClearPlanes):
	# Per-frame plane step axes (vanilla r_plane.c:200-201):
	#   basexscale = finecosine[angle] / centerxfrac
	#   baseyscale = -finesine[angle] / centerxfrac
	# with centerxfrac = centerx<<FRACBITS = proj<<16.  angle = viewangle-ANG90,
	# so finecosine[angle] = sin(viewangle) = vsin and finesine[angle] =
	# -cos(viewangle)... in the port's terms these reduce to vsin and -vcos,
	# each divided by (proj<<16) via fixeddiv.  mapplane applies
	# xstep = fixedmul(distance, basexscale) directly -- the /proj is REQUIRED
	# (removing it made the flat smear into diagonal noise).
	basexscale = rend->rfixeddiv(vsin, proj << 16);
	baseyscale = -rend->rfixeddiv(vcos, proj << 16);
	nsegs = ncolumns = nspans = 0;

	# clear to black
	rend->rclear(r, 0);

	# reset occlusion: full screen open in every column
	for (x := 0; x < w; x++) {
		solid[2*x] = -1;	# ceiling clip (top of open region)
		solid[2*x+1] = h;	# floor clip (bottom of open region)
		floorline[x] = h;	# no floor claimed yet
		ceilline[x] = -1;	# no ceiling claimed yet
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
		drawtwosided(sd, back, lx1, lx2, ox1, ox2, d1, d2, u1, u2,
			ceilz, floorz, back.ceilingheight, back.floorheight);
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

	# intern this sector's floor/ceiling planes for the column loop below
	curfloor = findplane(floorz, sec.floortexture, light);
	curceil = findplane(ceilz, sec.ceilingtexture, light);

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
			frac = ((x - ox1) << 16) / tspan;	# int-safe: |x-ox1|<=320, tspan<=~65536
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
		if (yt > yb)
			continue;

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
		if (yt > yb)
			continue;

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

		# mark floor/ceiling exposed by this solid wall: rows between the
		# open clip and the wall edges belong to the sector's planes.
		# a solid wall occludes everything from yt..yb, so ceiling fills
		# [cclip..yt-1] and floor fills [yb+1..fclip].
		markceil(curceil, x, cclip, yt - 1);
		markfloor(curfloor, x, yb + 1, fclip);

		# update occlusion for solid wall
		solid[2*x] = yb + 1;	# everything below is occluded
		solid[2*x+1] = yt;	# everything above is occluded
	}
}

# two-sided line: draw upper and lower textures where heights differ
drawtwosided(sd: ref Map->Side, back: ref Map->Sector,
	lx1, lx2, ox1, ox2, d1, d2, u1, u2: int,
	fceilz, ffloorz, bceilz, bfloorz: int)
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

	# intern front and back sector planes.  the front sector's floor and
	# ceiling fill the regions above the upper wall and below the lower
	# wall; the back sector's planes are seen through the portal opening
	# between them.  use each sector's own light so the two don't share
	# a visplane unless they truly match.
	fsec := sd.sector;
	flight := 0;
	clight := 0;
	if (fsec != nil) {
		flight = (fsec.lightlevel * 31) / 255;
		if (flight < 0) flight = 0;
		if (flight > 31) flight = 31;
		clight = flight;
	}
	frontfloor := findplane(ffloorz, fsec.floortexture, flight);
	frontceil := findplane(fceilz, fsec.ceilingtexture, clight);
	backfloor := -1;
	backceil := -1;
	if (back != nil) {
		blight := (back.lightlevel * 31) / 255;
		if (blight < 0) blight = 0;
		if (blight > 31) blight = 31;
		backfloor = findplane(bfloorz, back.floortexture, blight);
		backceil = findplane(bceilz, back.ceilingtexture, blight);
	}

	tspan := ox2 - ox1;
	for (x := lx1; x <= lx2; x++) {
		frac := 0;
		if (tspan > 0)
			frac = ((x - ox1) << 16) / tspan;	# int-safe
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

		# upper texture: from back ceiling to front ceiling
		if (bceilz < fceilz && sd.toptexture != "" && sd.toptexture != "-") {
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

		# portal: if back ceiling < front ceiling, occlude upper
		if (bceilz < fceilz) {
			yb := r.centery - int(big(bceilz - vz) * big(scale) >> 32);
			yb1 := yb + 1;
			if (yb1 < 0)
				yb1 = 0;
			if (yb1 > h)
				yb1 = h;
			if (yb1 > cclip)
				cclip = yb1;
		}
		# portal: if back floor > front floor, occlude lower
		if (bfloorz > ffloorz) {
			yt := r.centery - int(big(bfloorz - vz) * big(scale) >> 32);
			if (yt < 0)
				yt = 0;
			if (yt > h)
				yt = h;
			if (yt < fclip)
				fclip = yt;
		}

		# mark planes exposed by this portal.  screen y = centery-(z-vz)*proj/depth,
		# so higher z projects to smaller y.  the front ceiling fills the strip
		# between the open-clip top and the FRONT ceiling's edge; the front floor
		# fills the strip between the FRONT floor's edge and the open-clip bottom.
		# through the portal window [cclip..fclip] we see the BACK sector's planes:
		# the BACK ceiling (higher z than the front floor) fills [cclip..bctop-1]
		# and the BACK floor (lower z than the front ceiling) fills [blbot+1..fclip].
		# (was: the back strips used the front sector's z, so the back sector's
		# floor was marked starting at the front floor's edge -- painting the back
		# floor over the front floor and breaking flush seams.)
		fctop := r.centery - int(big(fceilz - vz) * big(scale) >> 32);
		markceil(frontceil, x, solid[2*x], fctop - 1);
		flbot := r.centery - int(big(ffloorz - vz) * big(scale) >> 32);
		markfloor(frontfloor, x, flbot + 1, solid[2*x+1]);
		bctop := r.centery - int(big(bceilz - vz) * big(scale) >> 32);
		markceil(backceil, x, cclip, bctop - 1);
		blbot := r.centery - int(big(bfloorz - vz) * big(scale) >> 32);
		markfloor(backfloor, x, blbot + 1, fclip);

		solid[2*x] = cclip;
		solid[2*x+1] = fclip;
	}
}

# Find or create a visplane for the given z/flat/light.  Returns the
# index into vps, or -1 if the table is full.  Planes are interned so
# many segs sharing a floor contribute to one plane.
findplane(z: int, flatname: string, light: int): int
{
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

# Mark floor plane `pl` exposing screen rows [t..b] in column x.
# A floor may claim from its strip top down to the shared floorline (the
# bottom edge of the nearest floor already drawn in this column), so a
# farther floor can never paint over a nearer one; then the line rises to
# the top of what this floor claimed, so the next (farther) floor sits
# below it.  floorline starts at h (nothing claimed).
markfloor(pl, x, t, b: int)
{
	if (pl < 0 || x < 0 || x >= w)
		return;
	if (b > floorline[x])
		b = floorline[x];
	if (b >= h)
		b = h - 1;
	if (t < 0)
		t = 0;
	if (t > b)
		return;
	if (x < vps[pl].minx)
		vps[pl].minx = x;
	if (x > vps[pl].maxx)
		vps[pl].maxx = x;
	if (vps[pl].top[x] < 0 || t < vps[pl].top[x])
		vps[pl].top[x] = t;
	if (vps[pl].bottom[x] < 0 || b > vps[pl].bottom[x])
		vps[pl].bottom[x] = b;
	if (t < floorline[x])
		floorline[x] = t;
}

# Mark ceiling plane `pl` exposing screen rows [t..b] in column x.
# A ceiling may claim from the shared ceilline (the top edge of the
# nearest ceiling already drawn) down to its strip bottom, so a farther
# ceiling can never paint over a nearer one; then the line drops to the
# bottom of what this ceiling claimed, so the next (farther) ceiling sits
# above it.  ceilline starts at -1 (nothing claimed).
markceil(pl, x, t, b: int)
{
	if (pl < 0 || x < 0 || x >= w)
		return;
	if (t < ceilline[x])
		t = ceilline[x];
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
	if (vps[pl].top[x] < 0 || t < vps[pl].top[x])
		vps[pl].top[x] = t;
	if (vps[pl].bottom[x] < 0 || b > vps[pl].bottom[x])
		vps[pl].bottom[x] = b;
	if (b > ceilline[x])
		ceilline[x] = b;
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
	# reach; the column's world direction is a PLAIN UNIT vector applied
	# over that scalar, exactly once:
	#   length = distance * distscale[x1]      (distscale = 1/cos)
	#   ds_xfrac = viewx + cos(angle)*length
	#   ds_yfrac = -viewy - sin(angle)*length
	# the unit direction = forward*cos(delta) + right*sin(delta), right=(vsin,-vcos),
	# sin(delta)=tan(delta)*cos(delta).  with length=distance/cos the cos in the
	# unit vector cancels, leaving reach `distance` along forward + lateral
	# distance*tan -- matching the step.  (the warp was: distscale stored cos,
	# so the offset was short by cos^2 at the screen edges, shrinking toward
	# center as the camera rotated.)
	length := rend->fixedmul(distance, distscale[x1]);	# = distance/cos
	td := ((x1 - centerx) << 16) / proj;	# tan(delta), 16.16
	# cos(delta) = 1/distscale (distscale holds 1/cos), 16.16
	cd := int(16r100000000 / big distscale[x1]);
	sd := rend->fixedmul(td, cd);		# sin(delta), 16.16
	# column ray dir, PLAIN UNIT vector: forward*cos + right*sin
	rayx := rend->fixedmul(vcos, cd) + rend->fixedmul(vsin, sd);
	rayy := rend->fixedmul(vsin, cd) - rend->fixedmul(vcos, sd);
	# flat u,v = world x,y; v is negated (vanilla ds_yfrac=-viewy-...).
	xfrac := vx + rend->fixedmul(length, rayx);
	yfrac := -vy - rend->fixedmul(length, rayy);

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
