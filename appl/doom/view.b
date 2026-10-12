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
	proj = width / 2;		# 90-degree horizontal FOV
	solid = array[w * 2] of int;
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
	nsegs = ncolumns = nspans = 0;

	# clear to black
	rend->rclear(r, 0);

	# reset occlusion: full screen open in every column
	for (x := 0; x < w; x++) {
		solid[2*x] = -1;	# ceiling clip (top of open region)
		solid[2*x+1] = h;	# floor clip (bottom of open region)
	}

	# walk BSP front-to-back from the root
	if (len lev.nodes > 0)
		renderbsp(len lev.nodes - 1);
	else if (len lev.subsectors > 0)
		rendersubsector(0);
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
	left := rend->fixedmul(nd.dy, dx);
	right := rend->fixedmul(dy, nd.dx);
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
	if (depth <= FRACUNIT / 4)
		return 16r7fffffff;	# behind or too close
	return (w / 2) - int(big(lateral) * big(proj) / big(depth));
}

# screen y from world z and depth: centery - (z-viewz)*proj/depth
projy(z, depth: int): int
{
	if (depth <= FRACUNIT / 4)
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

	# clip endpoints behind the near plane
	if (d1 <= 0) {
		# interpolate: t = d1 / (d1 - d2), new point = v1 + t*(v2-v1)
		# since d1 <= 0 < d2 (we already handled both <= 0)
		if (d2 <= 0)
			return;
		# ratio = d1 / (d1 - d2) is negative, we want the clip point
		# t = 0 - d1 = -d1 (distance from v1 to near plane)
		# total = d2 - d1
		# fraction along v1->v2 = -d1 / (d2 - d1)
		frac := (-d1 << 16) / (d2 - d1);	# 16.16
		l1 = l1 + rend->fixedmul(l2 - l1, frac);
		d1 = FRACUNIT / 4;	# small positive depth
		u1 = u1 + rend->fixedmul(u2 - u1, frac);
		x1 = projx(l1, d1);
		z1t = ceilz;
		z1b = floorz;
	} else {
		x1 = projx(l1, d1);
		z1t = ceilz;
		z1b = floorz;
	}

	if (d2 <= 0) {
		frac := (-d2 << 16) / (d1 - d2);
		l2 = l2 + rend->fixedmul(l1 - l2, frac);
		d2 = FRACUNIT / 4;
		u2 = u2 + rend->fixedmul(u1 - u2, frac);
		x2 = projx(l2, d2);
		z2t = ceilz;
		z2b = floorz;
	} else {
		x2 = projx(l2, d2);
		z2t = ceilz;
		z2b = floorz;
	}

	# ensure x1 <= x2 (swap if needed)
	sx := 0;
	sd_ := 0;
	sl := 0;
	su := 0;
	st := 0;
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
		st = z1t;
		z1t = z2t;
		z2t = st;
		st = z1b;
		z1b = z2b;
		z2b = st;
	}

	# clip to screen bounds
	if (x2 < 0 || x1 >= w)
		return;
	if (x1 < 0)
		x1 = 0;
	if (x2 >= w)
		x2 = w - 1;

	# choose texture
	texname := sd.midtexture;
	if (back != nil) {
		# two-sided: draw upper and lower, skip middle
		drawtwosided(sd, back, x1, x2, d1, d2, l1, l2, u1, u2,
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

	# draw columns x1..x2
	nsegs++;
	for (x := x1; x <= x2; x++) {
		# interpolate depth and u at this column
		# t = (x - x1) / (x2 - x1) in 16.16
		tspan := x2 - x1;
		frac := 0;
		if (tspan > 0)
			frac = ((x - x1) << 16) / tspan;
		depth := d1 + rend->fixedmul(d2 - d1, frac);
		u := u1 + rend->fixedmul(u2 - u1, frac);
		if (depth <= FRACUNIT / 4)
			continue;

		yt := projy(z1t + rend->fixedmul(z2t - z1t, frac), depth);
		yb := projy(z1b + rend->fixedmul(z2b - z1b, frac), depth);
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
		# scale: 16.16 texture units per screen pixel
		# iscale = depth / proj (depth is 16.16 world units, proj is pixels)
		iscale := depth / proj;
		# texturemid: z at centery, relative to viewz
		# at y=centery, frac_t = 0, z = z1 + (z2-z1)*0.5... actually
		# texturemid = (z_top - viewz) scaled to 16.16 texture units
		# texture top maps to yt, so texturemid = (z_top - viewz) * scale
		# But vanilla uses: texturemid = (z_top - viewz) in world 16.16
		# then frac = texturemid + (y - centery) * iscale
		tmid := z1t + rend->fixedmul(z2t - z1t, frac) - vz;
		# scale tmid to texture space: world 16.16 -> tex 16.16
		# texture is drawn at 1:1 world scale, so tmid stays as-is
		rend->rdrawcolumn(r,x, yt, yb, light, tex, col, tmid, iscale);
		ncolumns++;

		# update occlusion for solid wall
		solid[2*x] = yb + 1;	# everything below is occluded
		solid[2*x+1] = yt;	# everything above is occluded
	}
}

# two-sided line: draw upper and lower textures where heights differ
drawtwosided(sd: ref Map->Side, back: ref Map->Sector,
	x1, x2, d1, d2, l1, l2, u1, u2: int,
	fceilz, ffloorz, bceilz, bfloorz: int)
{
	nsegs++;
	for (x := x1; x <= x2; x++) {
		tspan := x2 - x1;
		frac := 0;
		if (tspan > 0)
			frac = ((x - x1) << 16) / tspan;
		depth := d1 + rend->fixedmul(d2 - d1, frac);
		u := u1 + rend->fixedmul(u2 - u1, frac);
		if (depth <= FRACUNIT / 4)
			continue;

		cclip := solid[2*x];
		fclip := solid[2*x+1];
		light := 0;
		sec := sd.sector;
		if (sec != nil) {
			light = (sec.lightlevel * 31) / 255;
			if (light < 0) light = 0;
			if (light > 31) light = 31;
		}

		iscale := depth / proj;

		# upper texture: from back ceiling to front ceiling
		if (bceilz < fceilz && sd.toptexture != "" && sd.toptexture != "-") {
			tex := rend->rtexture(r,sd.toptexture);
			if (tex != nil) {
				yt := projy(fceilz, depth);
				yb := projy(bceilz, depth);
				if (yt < cclip) yt = cclip;
				if (yt < 0) yt = 0;
				if (yb >= fclip) yb = fclip - 1;
				if (yb >= h) yb = h - 1;
				if (yt <= yb) {
					col := u >> 16;
					# upper texture is anchored at the top:
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
				yt := projy(bfloorz, depth);
				yb := projy(ffloorz, depth);
				if (yt < cclip) yt = cclip;
				if (yt < 0) yt = 0;
				if (yb >= fclip) yb = fclip - 1;
				if (yb >= h) yb = h - 1;
				if (yt <= yb) {
					col := u >> 16;
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
			yb := projy(bceilz, depth);
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
			yt := projy(bfloorz, depth);
			if (yt < 0)
				yt = 0;
			if (yt > h)
				yt = h;
			if (yt < fclip)
				fclip = yt;
		}

		solid[2*x] = cclip;
		solid[2*x+1] = fclip;
	}
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
