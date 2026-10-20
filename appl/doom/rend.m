# Doom renderer primitives: palette, colormap, flats, wall textures,
# and the vanilla column/span drawers.  Rendering targets an 8-bit
# indexed framebuffer (fb8); convert() maps it to BGR triplets for
# the video module's RGB24 framebuffer.
#
# Reference: doomgeneric r_data.c / r_draw.c (GPL-2).

Rend: module {

	PATH:	con "/dis/doom/rend.dis";

	Texture: adt {
		name:	string;
		width, height:	int;
		mask:	int;		# largest power of two <= width, minus 1
		data:	array of byte;	# column-major composite; col c at c*height
		posts:	array of array of int;	# per column: (topdelta, length) pairs,
					# opaque runs in texture space (for masked mids)
	};

	Flat: adt {
		name:	string;
		data:	array of byte;	# 64x64 row-major palette indices
	};

	Anim: adt {
		istex, base, numpics, speed:	int;
	};

	Renderer: adt {
		w, h:	int;
		centery:	int;
		fb8:	array of byte;		# w*h palette indices
		zerofb:	array of byte;		# w*h pre-zeroed; clear(0)
						# memmoves it (C speed) instead of
						# a 64k interpreted loop
		palr, palg, palb:	array of byte;	# 256 entries, PLAYPAL palette 0
		colormap:	array of byte;	# 34*256 light tables
		flats:	array of ref Flat;
		textures:	array of ref Texture;

		# animation tables (vanilla P_InitPicAnims state): per
		# Renderer, NOT module globals — module loads are
		# per-instance, so globals set by one module's init are
		# invisible to ticks/reads through another's (this
		# silently froze all flat/texture animation).
		anims:	array of Anim;	# built by animinit
		nanims:	int;
		texanim:	array of int;	# [len textures], identity unless animated
		flatanim:	array of int;	# [len flats], identity unless animated

		# load PLAYPAL, COLORMAP, flats and textures from w;
		# returns nil or an error
		init:	fn(r: self ref Renderer, w: ref Wad->File, width, height: int): string;

		flat:	fn(r: self ref Renderer, name: string): ref Flat;
		texture:	fn(r: self ref Renderer, name: string): ref Texture;

		clear:	fn(r: self ref Renderer, color: int);

		# vanilla R_DrawColumn: screen column x, rows yl..yh inclusive,
		# light = colormap row 0..31, texture column col, 16.16
		# texturemid/iscale relative to centery
		drawcolumn:	fn(r: self ref Renderer, x, yl, yh, light: int,
					tex: ref Texture, col, texturemid, iscale: int);

		# vanilla R_DrawSpan: row y, columns x1..x2 inclusive,
		# flat sampled at 16.16 u,v stepping xstep/ystep
		drawspan:	fn(r: self ref Renderer, y, x1, x2, light: int,
					fl: ref Flat, xfrac, yfrac, xstep, ystep: int);

		# vanilla R_DrawFuzzColumn: rows yl..yh at column x, no source;
		# samples fb8 at +-w offsets through colormap row 6 (r_draw.c)
		drawfuzz:	fn(r: self ref Renderer, x, yl, yh: int);

		# palette-map fb8 into dst as BGRX quadruplets for XRGB32
		# (len dst >= w*h*4)
		convert:	fn(r: self ref Renderer, dst: array of byte);

		# vanilla V_DrawPatch: blit a raw patch lump (post columns)
		# to fb8 at (x, y); x -= leftoffset, y -= topoffset.
		# Pixels outside fb are skipped (vanilla I_Errors; the
		# port never aborts — callers always draw on-screen).
		drawpatch:	fn(r: self ref Renderer, x, y: int,
					pd: array of byte);

		# drawpatch centered on column cx (x = cx - width/2)
		drawpatchcentered:	fn(r: self ref Renderer, cx, y: int,
					pd: array of byte);

		# vanilla V_DrawBlock: blit a w*h linear rect to fb8
		drawblock:	fn(r: self ref Renderer, x, y, w, h: int,
					src: array of byte);

		# vanilla V_DrawFilledBox: fill an fb8 rect with a palette
		# index
		fillrect:	fn(r: self ref Renderer, x, y, w, h, c: int);

		# vanilla hu_lib HUlib_drawTextLine (no cursor): string in
		# a patch font (lumps indexed c - sc, sc = HU_FONTSTART
		# for STCFN); space/out-of-range advances 4, stops at the
		# right edge.  Returns the end x.
		drawtext:	fn(r: self ref Renderer, x, y: int, s: string,
					font: array of array of byte, sc: int): int;
	};

	# 16.16 fixed-point multiply, exact 64-bit intermediate
	# (Limbo has no int64, so split into 16-bit halves)
	fixedmul:	fn(a, b: int): int;

	# 16.16 fixed-point divide: (a<<16)/b, done in big to avoid overflow
	fixeddiv:	fn(a, b: int): int;

	# module-level wrappers for Renderer methods (for callers
	# that don't import the Renderer adt)
	rclear:		fn(r: ref Renderer, color: int);
	rtexture:	fn(r: ref Renderer, name: string): ref Texture;
	rflat:		fn(r: ref Renderer, name: string): ref Flat;
	rfixeddiv:	fn(a, b: int): int;
	rdrawcolumn:	fn(r: ref Renderer, x, yl, yh, light: int,
				tex: ref Texture, col, texturemid, iscale: int);
	rdrawspan:	fn(r: ref Renderer, y, x1, x2, light: int,
				fl: ref Flat, xfrac, yfrac, xstep, ystep: int);
	rdrawfuzz:	fn(r: ref Renderer, x, yl, yh: int);
	animtic:	fn(r: ref Renderer, lvltime: int);
	rpatchwidth:	fn(pd: array of byte): int;
	rpatchheight:	fn(pd: array of byte): int;
	rdrawpatch:	fn(r: ref Renderer, x, y: int,
				pd: array of byte);
	rdrawpatchcentered:	fn(r: ref Renderer, cx, y: int,
				pd: array of byte);
	rdrawblock:	fn(r: ref Renderer, x, y, w, h: int,
				src: array of byte);
	rfillrect:	fn(r: ref Renderer, x, y, w, h, c: int);
	rdrawtext:	fn(r: ref Renderer, x, y: int, s: string,
				font: array of array of byte, sc: int): int;
};
