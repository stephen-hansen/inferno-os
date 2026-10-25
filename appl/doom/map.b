implement Map;

include "sys.m";
	sys: Sys;
include "wad.m";
	wad: Wad;
	File: import wad;
include "rend.m";
	rend: Rend;
include "map.m";

le16(b: array of byte, o: int): int
{
	v := int b[o] | int b[o+1] << 8;
	if (v >= 16r8000)		# vanilla SHORT(): sign extend
		v -= 16r10000;
	return v;
}

le16u(b: array of byte, o: int): int
{
	return int b[o] | int b[o+1] << 8;	# unsigned (node children)
}

name8(b: array of byte, o: int): string
{
	s := "";
	for (i := 0; i < 8; i++) {
		c := int b[o+i];
		if (c == 0)
			break;
		s += sys->sprint("%c", c);
	}
	return s;
}

open(w: ref Wad->File, mapname: string): (ref Level, string)
{
	if (sys == nil) {
		sys = load Sys Sys->PATH;
		if (sys == nil)
			return (nil, "can't load Sys");
	}
	if (wad == nil) {		# File methods dispatch through it
		wad = load Wad Wad->PATH;
		if (wad == nil)
			return (nil, "can't load Wad module");
	}
	if (rend == nil) {		# pointonside uses fixedmul
		rend = load Rend Rend->PATH;
		if (rend == nil)
			rend = load Rend "rend.dis";
		if (rend == nil)
			return (nil, "can't load Rend module");
	}

	m := w.find(mapname);
	if (m < 0)
		return (nil, sys->sprint("map %s not found", mapname));
	if (m + 10 >= w.numlumps)
		return (nil, sys->sprint("map %s: lumps truncated", mapname));

	# vanilla fixed lump order after the marker (ML_* in doomdata.h)
	lnames := "THINGS" :: "LINEDEFS" :: "SIDEDEFS" :: "VERTEXES" ::
		"SEGS" :: "SSECTORS" :: "NODES" :: "SECTORS" :: "REJECT" ::
		"BLOCKMAP" :: nil;
	i := 0;
	for (p := lnames; p != nil; p = tl p) {
		if (w.lumps[m+1+i].name != hd p)
			return (nil, sys->sprint("map %s: lump %d is %s, want %s",
				mapname, i+1, w.lumps[m+1+i].name, hd p));
		i++;
	}

	l := ref Level(mapname, nil, nil, nil, nil, nil, nil, nil, nil, nil, 0, 0);
	b := array[0] of byte;
	err := "";

	# VERTEXES (m+4): int16 x, int16 y per vertex
	(b, err) = w.read(m+4);
	if (b == nil)
		return (nil, err);
	if (len b % 4 != 0)
		return (nil, "VERTEXES size not a multiple of 4");
	nv := len b / 4;
	verts := array[nv] of Vertex;
	for (i = 0; i < nv; i++)
		verts[i] = Vertex(le16(b, 4*i) << 16, le16(b, 4*i+2) << 16);
	l.vertices = verts;

	# SECTORS (m+8): 26-byte records
	(b, err) = w.read(m+8);
	if (b == nil)
		return (nil, err);
	if (len b % 26 != 0)
		return (nil, "SECTORS size not a multiple of 26");
	ns := len b / 26;
	sectors := array[ns] of ref Sector;
	for (i = 0; i < ns; i++) {
		o := 26 * i;
		sectors[i] = ref Sector(
			le16(b, o) << 16, le16(b, o+2) << 16,
			name8(b, o+4), name8(b, o+12),
			le16(b, o+20), le16(b, o+22), le16(b, o+24),
			-1);	# specialdata: no active thinker
	}
	l.sectors = sectors;

	# SIDEDEFS (m+3): 30-byte records; sector index validated here
	(b, err) = w.read(m+3);
	if (b == nil)
		return (nil, err);
	if (len b % 30 != 0)
		return (nil, "SIDEDEFS size not a multiple of 30");
	nsd := len b / 30;
	sides := array[nsd] of ref Side;
	for (i = 0; i < nsd; i++) {
		o := 30 * i;
		si := le16(b, o+28);
		if (si < 0 || si >= ns)
			return (nil, sys->sprint("sidedef %d: sector %d out of range 0..%d",
				i, si, ns-1));
		sides[i] = ref Side(le16(b, o) << 16, le16(b, o+2) << 16,
			name8(b, o+4), name8(b, o+12), name8(b, o+20),
			sectors[si]);
	}
	l.sides = sides;

	# LINEDEFS (m+2): 14-byte records; derived dx/dy/bbox/slopetype
	# and front/back sector refs computed as in P_LoadLineDefs
	(b, err) = w.read(m+2);
	if (b == nil)
		return (nil, err);
	if (len b % 14 != 0)
		return (nil, "LINEDEFS size not a multiple of 14");
	nl := len b / 14;
	lines := array[nl] of Line;
	for (i = 0; i < nl; i++) {
		o := 14 * i;
		v1 := le16(b, o);
		v2 := le16(b, o+2);
		if (v1 < 0 || v1 >= nv || v2 < 0 || v2 >= nv)
			return (nil, sys->sprint("linedef %d: vertex %d,%d out of range 0..%d",
				i, v1, v2, nv-1));
		s0 := le16(b, o+10);
		s1 := le16(b, o+12);
		sd := array[2] of ref Side;
		if (s0 >= 0) {
			if (s0 >= nsd)
				return (nil, sys->sprint("linedef %d: front side %d out of range", i, s0));
			sd[0] = sides[s0];
		}
		if (s1 >= 0) {
			if (s1 >= nsd)
				return (nil, sys->sprint("linedef %d: back side %d out of range", i, s1));
			sd[1] = sides[s1];
		}
		dx := verts[v2].x - verts[v1].x;
		dy := verts[v2].y - verts[v1].y;
		# slopetype: sign of dy/dx without needing FixedDiv
		st := ST_HORIZONTAL;
		if (dx == 0)
			st = ST_VERTICAL;
		else if (dy != 0) {
			if ((dy > 0) == (dx > 0))
				st = ST_POSITIVE;
			else
				st = ST_NEGATIVE;
		}
		bbox := array[4] of int;
		if (verts[v1].y < verts[v2].y) {
			bbox[0] = verts[v2].y;
			bbox[1] = verts[v1].y;
		} else {
			bbox[0] = verts[v1].y;
			bbox[1] = verts[v2].y;
		}
		if (verts[v1].x < verts[v2].x) {
			bbox[2] = verts[v1].x;
			bbox[3] = verts[v2].x;
		} else {
			bbox[2] = verts[v2].x;
			bbox[3] = verts[v1].x;
		}
		fs: ref Sector;
		bs: ref Sector;
		if (sd[0] != nil)
			fs = sd[0].sector;
		if (sd[1] != nil)
			bs = sd[1].sector;
		lines[i] = Line(v1, v2, dx, dy,
			le16(b, o+4), le16(b, o+6), le16(b, o+8),
			sd, fs, bs, st, bbox);
	}
	l.lines = lines;

	# THINGS (m+1): 10-byte records
	(b, err) = w.read(m+1);
	if (b == nil)
		return (nil, err);
	if (len b % 10 != 0)
		return (nil, "THINGS size not a multiple of 10");
	nth := len b / 10;
	things := array[nth] of Thing;
	for (i = 0; i < nth; i++) {
		o := 10 * i;
		things[i] = Thing(le16(b, o) << 16, le16(b, o+2) << 16,
			le16(b, o+4), le16(b, o+6), le16(b, o+8));
	}
	l.things = things;

	# SEGS (m+5): 12-byte records
	(b, err) = w.read(m+5);
	if (b == nil)
		return (nil, err);
	if (len b % 12 != 0)
		return (nil, "SEGS size not a multiple of 12");
	nsgtot := len b / 12;
	segs := array[nsgtot] of Seg;
	for (i = 0; i < nsgtot; i++) {
		o := 12 * i;
		segs[i] = Seg(le16(b, o), le16(b, o+2),
			le16(b, o+4), le16(b, o+6), le16(b, o+8),
			le16(b, o+10) << 16);	# offset is 16.16 like every
						# other map coordinate
	}
	l.segs = segs;

	# SSECTORS (m+6): 4-byte records; sector from first seg
	(b, err) = w.read(m+6);
	if (b == nil)
		return (nil, err);
	if (len b % 4 != 0)
		return (nil, "SSECTORS size not a multiple of 4");
	nss := len b / 4;
	subsectors := array[nss] of Subsector;
	for (i = 0; i < nss; i++) {
		o := 4 * i;
		nsg := le16u(b, o);
		fsg := le16u(b, o+2);
		subsectors[i] = Subsector(nsg, fsg, nil);
	}
	for (i = 0; i < nss; i++) {
		fsg := subsectors[i].firstseg;
		if (fsg < 0 || fsg >= nsgtot)
			return (nil, sys->sprint("subsector %d: firstseg %d out of range", i, fsg));
		sg := segs[fsg];
		if (sg.linedef < 0 || sg.linedef >= nl)
			return (nil, sys->sprint("seg %d: linedef %d out of range", fsg, sg.linedef));
		ld := lines[sg.linedef];
		if (sg.side != 0 && sg.side != 1)
			return (nil, sys->sprint("seg %d: side %d not 0/1", fsg, sg.side));
		if (ld.sides[sg.side] == nil)
			return (nil, sys->sprint("seg %d: side %d missing on linedef %d",
				fsg, sg.side, sg.linedef));
		subsectors[i].sector = ld.sides[sg.side].sector;
	}
	l.subsectors = subsectors;

	# NODES (m+7): 28-byte records; coords stored <<16 to fixed
	(b, err) = w.read(m+7);
	if (b == nil)
		return (nil, err);
	if (len b % 28 != 0)
		return (nil, "NODES size not a multiple of 28");
	nn := len b / 28;
	nodes := array[nn] of Node;
	for (i = 0; i < nn; i++) {
		o := 28 * i;
		bbox := array[2] of array of int;
		for (j := 0; j < 2; j++) {
			bo := o + 8 + j * 8;
			bbox[j] = array[4] of int;
			bbox[j][0] = le16(b, bo) << 16;		# BOXTOP
			bbox[j][1] = le16(b, bo+2) << 16;	# BOXBOTTOM
			bbox[j][2] = le16(b, bo+4) << 16;	# BOXLEFT
			bbox[j][3] = le16(b, bo+6) << 16;	# BOXRIGHT
		}
		ch := array[2] of int;
		ch[0] = le16u(b, o+24);
		ch[1] = le16u(b, o+26);
		nodes[i] = Node(le16(b, o) << 16, le16(b, o+2) << 16,
			le16(b, o+4) << 16, le16(b, o+6) << 16, bbox, ch);
	}
	l.nodes = nodes;

	# REJECT (m+9): sector-pair visibility bit matrix for the fast
	# P_CheckSight reject.  WAD size must cover all pairs; short
	# lumps degrade to no rejects (always visible), never to
	# wrong rejects.
	(b, err) = w.read(m+9);
	if (b == nil)
		return (nil, err);
	rn := (ns * ns + 7) / 8;
	reject := array[rn] of int;
	for (i = 0; i < rn; i++)
		reject[i] = 0;
	if (len b >= rn)
		for (i = 0; i < rn; i++)
			reject[i] = int b[i];
	l.reject = reject;

	# BLOCKMAP (m+10): only the origin is needed (automap grid
	# alignment, am_map.c AM_drawGrid); the port never uses the
	# blockmap chains.
	(b, err) = w.read(m+10);
	if (b == nil)
		return (nil, err);
	if (len b >= 4) {
		l.bmaporgx = le16(b, 0) << 16;
		l.bmaporgy = le16(b, 2) << 16;
	}

	return (l, nil);
}

# vanilla R_PointOnSide: 0 front, 1 back.  node.x/y/dx/dy are
# 16.16 fixed; sign-bit trick first, then FixedMul fallback.
# node indices are used so the arrays need not be re-fetched.
pointonside(l: ref Level, x, y, n: int): int
{
	if (rend == nil) {
		rend = load Rend Rend->PATH;
		if (rend == nil)
			rend = load Rend "rend.dis";
	}
	nd := l.nodes[n];
	dx := 0;
	dy := 0;
	if (nd.dx == 0) {
		if (x <= nd.x)
			return nd.dy > 0;	# Limbo relational yields int 0/1
		return nd.dy < 0;
	}
	if (nd.dy == 0) {
		if (y <= nd.y)
			return nd.dx < 0;
		return nd.dx > 0;
	}

	dx = x - nd.x;
	dy = y - nd.y;

	# quick decide by sign bits (vanilla (a^b^c^d)&0x80000000)
	if (((nd.dy ^ nd.dx) ^ (dx ^ dy)) & ~2147483647) {
		if ((nd.dy ^ dx) & ~2147483647)
			return 1;
		return 0;
	}

	left := rend->fixedmul(nd.dy >> 16, dx);
	right := rend->fixedmul(dy, nd.dx >> 16);
	if (right < left)
		return 0;
	return 1;
}

Level.pointsubsector(l: self ref Level, x, y: int): ref Subsector
{
	if (len l.nodes == 0) {
		if (len l.subsectors == 0)
			return nil;
		return ref l.subsectors[0];
	}
	nodenum := len l.nodes - 1;
	while ((nodenum & NF_SUBSECTOR) == 0) {
		side := pointonside(l, x, y, nodenum);
		nodenum = l.nodes[nodenum].children[side];
	}
	i := nodenum & ~NF_SUBSECTOR;
	if (i < 0 || i >= len l.subsectors)
		return nil;
	return ref l.subsectors[i];
}
