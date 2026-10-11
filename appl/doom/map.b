implement Map;

include "sys.m";
	sys: Sys;
include "wad.m";
	wad: Wad;
	File: import wad;
include "map.m";

le16(b: array of byte, o: int): int
{
	v := int b[o] | int b[o+1] << 8;
	if (v >= 16r8000)		# vanilla SHORT(): sign extend
		v -= 16r10000;
	return v;
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

	l := ref Level(mapname, nil, nil, nil, nil, nil);
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
			le16(b, o+20), le16(b, o+22), le16(b, o+24));
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
		fs := ref Sector;
		bs := ref Sector;
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

	return (l, nil);
}
