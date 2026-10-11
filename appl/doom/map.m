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

	Level: adt {
		name:	string;
		vertices:	array of Vertex;
		sectors:	array of ref Sector;
		sides:	array of ref Side;
		lines:	array of Line;
		things:	array of Thing;
	};

	# load a map by marker name ("E1M1"); returns (level, nil) or
	# (nil, error).  Index ranges are validated; sector refs on
	# sides/lines alias the Level.sectors entries.
	# (named open, not load: load is a Limbo keyword)
	open:	fn(w: ref Wad->File, mapname: string): (ref Level, string);

};
