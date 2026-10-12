# Map geometry loader: THINGS/LINEDEFS/SIDEDEFS/VERTEXES/SECTORS
# from an IWAD, as Limbo adts.  Runtime layout mirrors vanilla
# p_setup.c: coordinates are 16.16 fixed point; sector refs are
# shared so movers can mutate heights in place.
#
# Reference: doomgeneric p_setup.c / doomdata.h (GPL-2).

Map: module {

	PATH:	con "/dis/doom/map.dis";

	# linedef slopetypes (doomdef.h)
	ST_HORIZONTAL, ST_VERTICAL, ST_POSITIVE, ST_NEGATIVE: con iota;

	# node children[] flag: value is a subsector index, not a node
	NF_SUBSECTOR:	con 16r8000;

	Vertex: adt {
		x, y:	int;		# 16.16 fixed point
	};

	Sector: adt {
		floorheight, ceilingheight:	int;	# 16.16
		floortexture, ceilingtexture:	string;
		lightlevel, special, tag:	int;
	};

	Side: adt {
		textureoffset, rowoffset:	int;	# 16.16
		toptexture, bottomtexture, midtexture:	string;
		sector:	ref Sector;
	};

	Line: adt {
		v1, v2:	int;		# vertex indices
		dx, dy:	int;		# 16.16, v2 - v1
		flags, special, tag:	int;
		sides:	array of ref Side;	# [2]; nil when sidenum is -1
		frontsector, backsector:	ref Sector;	# nil if absent
		slopetype:	int;
		bbox:	array of int;	# BOXTOP, BOXBOTTOM, BOXLEFT, BOXRIGHT
	};

	Thing: adt {
		x, y:	int;		# 16.16
		angle:	int;		# degrees
		typ, options:	int;
	};

	# SEGS lump record (doomdata.h mapseg_t): partition-line
	# segments used by subsectors.
	Seg: adt {
		v1, v2:	int;		# vertex indices
		angle:	int;		# BAM (tantoangle input)
		linedef:	int;
		side:	int;		# 0 front, 1 back
		offset:	int;		# 16.16 distance along the line
	};

	# SSECTORS lump record; sector resolved from segs[firstseg].
	Subsector: adt {
		numsegs, firstseg:	int;
		sector:		ref Sector;
	};

	# NODES lump record (mapnode_t): BSP partition.  Children
	# are node indices with NF_SUBSECTOR set when a subsector.
	Node: adt {
		x, y, dx, dy:	int;		# 16.16 (stored <<16 from int16)
		bbox:	array of array of int;	# [2][4]: BOXTOP..BOXRIGHT
		children:	array of int;	# [2], raw incl. NF_SUBSECTOR
	};

	Level: adt {
		name:	string;
		vertices:	array of Vertex;
		sectors:	array of ref Sector;
		sides:	array of ref Side;
		lines:	array of Line;
		things:	array of Thing;
		segs:	array of Seg;
		subsectors:	array of Subsector;
		nodes:	array of Node;

		# R_PointInSubsector: descend the BSP from node
		# numnodes-1; always returns non-nil (node 0 if
		# single-subsector map).  x,y are 16.16 fixed.
		pointsubsector:	fn(l: self ref Level, x, y: int): ref Subsector;
	};

	# load a map by marker name ("E1M1"); returns (level, nil) or
	# (nil, error).  Index ranges are validated; sector refs on
	# sides/lines alias the Level.sectors entries.
	# (named open, not load: load is a Limbo keyword)
	open:	fn(w: ref Wad->File, mapname: string): (ref Level, string);

};
