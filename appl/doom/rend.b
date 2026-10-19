implement Rend;

include "sys.m";
	sys: Sys;
include "wad.m";
	wad: Wad;
	File: import wad;
include "rend.m";

# on-disk reference from a texture definition to a patch lump
Patchref: adt {
	originx, originy:	int;
	lump:	int;		# lump index, or -1 if the patch is missing
};

le16(b: array of byte, o: int): int
{
	v := int b[o] | int b[o+1] << 8;
	if (v >= 16r8000)		# vanilla SHORT(): sign extend
		v -= 16r10000;
	return v;
}

le32(b: array of byte, o: int): int
{
	return int b[o] | int b[o+1] << 8 | int b[o+2] << 16 | int b[o+3] << 24;
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

# vanilla FixedMul with an exact 64-bit intermediate, done in 16-bit
# halves because Limbo has no int64; result is low 32 bits of a*b>>16
fixedmul(a, b: int): int
{
	ah := a >> 16;
	al := a & 16rFFFF;
	bh := b >> 16;
	bl := b & 16rFFFF;
	return ((ah * bh) << 16) + ah * bl + al * bh + (((al * bl) >> 16) & 16rFFFF);
}

# vanilla FixedDiv: (a<<16)/b in 64-bit; Limbo has no int64, so use big
fixeddiv(a, b: int): int
{
	if (b == 0)
		return 0;
	return int((big(a) << 16) / big b);
}

# vanilla R_DrawColumnInCache: clip one patch column of posts into a
# dense cache column (post: topdelta, length, pad, data[length], pad,
# terminated by topdelta == 0xff)
drawcolincache(pd: array of byte, pofs: int, cache: array of byte,
		coff, originy, cacheheight: int)
{
	while (pofs >= 0 && pofs + 1 < len pd && int pd[pofs] != 16rff) {
		length := int pd[pofs+1];
		position := originy + int pd[pofs];
		count := length;
		source := pofs + 3;
		if (position < 0) {
			count += position;
			position = 0;
		}
		if (position + count > cacheheight)
			count = cacheheight - position;
		if (source + count > len pd)
			count = len pd - source;
		for (i := 0; i < count; i++)
			cache[coff + position + i] = pd[source + i];
		pofs += length + 4;
	}
}

loadflats(r: ref Renderer, w: ref Wad->File): string
{
	fs := w.find("F_START");
	fe := w.find("F_END");
	if (fs < 0 || fe < 0 || fe <= fs)
		return "no F_START/F_END";
	n := 0;
	for (i := fs+1; i < fe; i++)
		if (w.lumps[i].size == 4096)
			n++;
	r.flats = array[n] of ref Flat;
	k := 0;
	for (i = fs+1; i < fe; i++) {
		if (w.lumps[i].size != 4096)
			continue;		# marker lumps such as F_SKY1
		(b, err) := w.read(i);
		if (b == nil)
			return err;
		if (len b != 4096)
			return sys->sprint("flat %s: %d bytes, want 4096",
				w.lumps[i].name, len b);
		r.flats[k++] = ref Flat(w.lumps[i].name, b);
	}
	return nil;
}

loadtextures(r: ref Renderer, w: ref Wad->File): string
{
	j := 0;
	pd := array[0] of byte;
	t1 := array[0] of byte;
	t2 := array[0] of byte;
	err := "";

	# PNAMES: int32 count, then count 8-byte patch lump names
	i := w.find("PNAMES");
	if (i < 0)
		return "no PNAMES lump";
	(pd, err) = w.read(i);
	if (pd == nil)
		return err;
	if (len pd < 4)
		return "PNAMES too short";
	np := le32(pd, 0);
	if (np < 0 || len pd < 4 + np*8)
		return "PNAMES truncated";
	patchlump := array[np] of int;
	for (j = 0; j < np; j++)
		patchlump[j] = w.find(name8(pd, 4 + j*8));

	# TEXTURE1, plus TEXTURE2 when present
	i1 := w.find("TEXTURE1");
	if (i1 < 0)
		return "no TEXTURE1 lump";
	(t1, err) = w.read(i1);
	if (t1 == nil)
		return err;
	if (len t1 < 4)
		return "TEXTURE1 too short";
	n1 := le32(t1, 0);
	if (n1 < 0 || len t1 < 4 + n1*4)
		return "TEXTURE1 truncated";
	n2 := 0;
	i2 := w.find("TEXTURE2");
	if (i2 >= 0) {
		(t2, err) = w.read(i2);
		if (t2 == nil)
			return err;
		if (len t2 < 4)
			return "TEXTURE2 too short";
		n2 = le32(t2, 0);
		if (n2 < 0 || len t2 < 4 + n2*4)
			return "TEXTURE2 truncated";
	}

	r.textures = array[n1+n2] of ref Texture;
	for (j = 0; j < n1; j++) {
		err = parsetexture(r, t1, le32(t1, 4 + 4*j), j, patchlump, w);
		if (err != nil)
			return err;
	}
	for (j = 0; j < n2; j++) {
		err = parsetexture(r, t2, le32(t2, 4 + 4*j), n1 + j, patchlump, w);
		if (err != nil)
			return err;
	}
	return nil;
}

parsetexture(r: ref Renderer, d: array of byte, ofs, idx: int,
		patchlump: array of int, w: ref Wad->File): string
{
	if (ofs < 0 || len d - ofs < 22)
		return sys->sprint("texture %d: bad offset %d", idx, ofs);
	name := name8(d, ofs);
	width := le16(d, ofs+12);
	height := le16(d, ofs+14);
	pc := le16(d, ofs+20);
	if (width <= 0 || height <= 0 || pc <= 0 || len d - ofs < 22 + pc*10)
		return sys->sprint("texture %s: bad header", name);
	prefs := array[pc] of Patchref;
	j := 0;
	for (j = 0; j < pc; j++) {
		o := ofs + 22 + j*10;
		pn := le16(d, o+4);
		lump := -1;
		if (pn >= 0 && pn < len patchlump)
			lump = patchlump[pn];
		prefs[j] = Patchref(le16(d, o), le16(d, o+2), lump);
	}
	j = 1;
	while (j * 2 <= width)
		j <<= 1;
	tex := ref Texture(name, width, height, j-1, nil, nil);
	r.textures[idx] = tex;
	return gentex(tex, prefs, w);
}

# compose a texture from its patches into a dense column-major block
# (vanilla R_GenerateComposite, but eager rather than on first use).
# Also derives per-column opaque post runs (topdelta, length in texture
# space) from write coverage: masked midtextures draw through posts,
# and gap rows must stay transparent.
gentex(tex: ref Texture, prefs: array of Patchref,
		w: ref Wad->File): string
{
	data := array[tex.width * tex.height] of byte;
	cov := array[tex.width * tex.height] of byte;
	for (j := 0; j < len prefs; j++) {
		p := prefs[j];
		if (p.lump < 0)
			return sys->sprint("texture %s: missing patch lump", tex.name);
		(pd, err) := w.read(p.lump);
		if (pd == nil)
			return err;
		if (len pd < 8)
			return sys->sprint("texture %s: short patch", tex.name);
		pw := le16(pd, 0);
		x1 := p.originx;
		x2 := x1 + pw;
		if (x1 < 0)
			x1 = 0;
		if (x2 > tex.width)
			x2 = tex.width;
		for (x := x1; x < x2; x++) {
			cofs := le32(pd, 8 + 4*(x - p.originx));
			if (cofs < 0 || cofs >= len pd)
				continue;
			drawcolincache(pd, cofs, data, x * tex.height,
				p.originy, tex.height);
			markcov(pd, cofs, cov, x * tex.height,
				p.originy, tex.height);
		}
	}
	tex.data = data;
	# derive posts: maximal opaque runs per column from coverage
	tex.posts = array[tex.width] of array of int;
	for (x := 0; x < tex.width; x++) {
		base := x * tex.height;
		np := 0;
		for (i := 0; i < tex.height; ) {
			if (int cov[base+i] == 0) {
				i++;
				continue;
			}
			jj := i;
			while (jj < tex.height && int cov[base+jj] != 0)
				jj++;
			np += 2;
			i = jj;
		}
		posts := array[np] of int;
		k := 0;
		for (i = 0; i < tex.height; ) {
			if (int cov[base+i] == 0) {
				i++;
				continue;
			}
			start := i;
			while (i < tex.height && int cov[base+i] != 0)
				i++;
			posts[k++] = start;
			posts[k++] = i - start;
		}
		tex.posts[x] = posts;
	}
	return nil;
}

# mark coverage for one patch column, same clip rules as drawcolincache
markcov(pd: array of byte, pofs: int, cov: array of byte,
		coff, originy, cacheheight: int)
{
	while (pofs >= 0 && pofs + 1 < len pd && int pd[pofs] != 16rff) {
		length := int pd[pofs+1];
		position := originy + int pd[pofs];
		count := length;
		source := pofs + 3;
		if (position < 0) {
			count += position;
			position = 0;
		}
		if (position + count > cacheheight)
			count = cacheheight - position;
		if (source + count > len pd)
			count = len pd - source;
		for (i := 0; i < count; i++)
			cov[coff + position + i] = byte 1;
		pofs += length + 4;
	}
}

# ---- animated textures/flats (vanilla P_InitPicAnims + the
# P_UpdateSpecials animate block, p_spec.c) ----
# animdefs (istexture, endname, startname, speed), transcribed exactly;
# shareware doom1.wad only contains NUKAGE1-3, everything else skips.
# Frames are contiguous index ranges (TEXTURE1 order / flat WAD order).
# Rendering resolves names through texanim/flatanim (identity unless
# animated), so wall/plane code needs no changes.
AnimDef: adt {
	istex:	int;
	endname, startname:	string;
	speed:	int;
};
# (Anim lives in rend.m: the Renderer adt holds anim tables.)
animdefs := array[] of {
	AnimDef(0, "NUKAGE3", "NUKAGE1", 8),
	AnimDef(0, "FWATER4", "FWATER1", 8),
	AnimDef(0, "SWATER4", "SWATER1", 8),
	AnimDef(0, "LAVA4", "LAVA1", 8),
	AnimDef(0, "BLOOD3", "BLOOD1", 8),
	AnimDef(0, "RROCK08", "RROCK05", 8),
	AnimDef(0, "SLIME04", "SLIME01", 8),
	AnimDef(0, "SLIME08", "SLIME05", 8),
	AnimDef(0, "SLIME12", "SLIME09", 8),
	AnimDef(1, "BLODGR4", "BLODGR1", 8),
	AnimDef(1, "SLADRIP3", "SLADRIP1", 8),
	AnimDef(1, "BLODRIP4", "BLODRIP1", 8),
	AnimDef(1, "FIREWALL", "FIREWALA", 8),
	AnimDef(1, "GSTFONT3", "GSTFONT1", 8),
	AnimDef(1, "FIRELAVA", "FIRELAV3", 8),
	AnimDef(1, "FIREMAG3", "FIREMAG1", 8),
	AnimDef(1, "FIREBLU2", "FIREBLU1", 8),
	AnimDef(1, "ROCKRED3", "ROCKRED1", 8),
	AnimDef(1, "BFALL4", "BFALL1", 8),
	AnimDef(1, "SFALL4", "SFALL1", 8),
	AnimDef(1, "WFALL4", "WFALL1", 8),
	AnimDef(1, "DBRAIN4", "DBRAIN1", 8),
};
# (animation tables live on the Renderer adt: module loads are
# per-instance, so module globals would be invisible across the
# init/tick/read modules.  See rend.m.)

# build the anim list + identity maps (vanilla P_InitPicAnims: skip
# when the start lump is missing; skip bad cycles instead of I_Error)
animinit(r: ref Renderer)
{
	r.anims = array[len animdefs] of Anim;
	r.nanims = 0;
	r.texanim = array[len r.textures] of int;
	r.flatanim = array[len r.flats] of int;
	i, j: int;
	for (i = 0; i < len r.textures; i++)
		r.texanim[i] = i;
	for (i = 0; i < len r.flats; i++)
		r.flatanim[i] = i;
	for (i = 0; i < len animdefs; i++) {
		d := animdefs[i];
		base := -1;
		picnum := -1;
		if (d.istex) {
			for (j = 0; j < len r.textures; j++)
				if (r.textures[j].name == d.startname)
					base = j;
			if (base < 0)
				continue;
			for (j = 0; j < len r.textures; j++)
				if (r.textures[j].name == d.endname)
					picnum = j;
		} else {
			for (j = 0; j < len r.flats; j++)
				if (r.flats[j].name == d.startname)
					base = j;
			if (base < 0)
				continue;
			for (j = 0; j < len r.flats; j++)
				if (r.flats[j].name == d.endname)
					picnum = j;
		}
		if (picnum < 0)
			continue;
		n := picnum - base + 1;
		if (n < 2)
			continue;
		r.anims[r.nanims] = Anim(d.istex, base, n, d.speed);
		r.nanims++;
	}
}

# advance animations one leveltic (vanilla P_UpdateSpecials block:
# pic = base + ((leveltime/speed + i) % numpics))
animtic(r: ref Renderer, lvltime: int)
{
	if (r.anims == nil)
		return;
	for (k := 0; k < r.nanims; k++) {
		a := r.anims[k];
		for (i := 0; i < a.numpics; i++) {
			pic := a.base + (lvltime / a.speed + i) % a.numpics;
			if (a.istex)
				r.texanim[a.base + i] = pic;
			else
				r.flatanim[a.base + i] = pic;
		}
	}
}

Renderer.init(r: self ref Renderer, w: ref Wad->File, width, height: int): string
{
	if (sys == nil)
		sys = load Sys Sys->PATH;
	if (wad == nil) {		# File methods dispatch through it
		wad = load Wad Wad->PATH;
		if (wad == nil)
			return sys->sprint("can't load Wad module: %r");
	}

	r.w = width;
	r.h = height;
	r.centery = height / 2;
	r.fb8 = array[width * height] of byte;

	# PLAYPAL: palette 0 is the first 768 bytes, RGB triplets
	i := w.find("PLAYPAL");
	if (i < 0)
		return "no PLAYPAL lump";
	(b, err) := w.read(i);
	if (b == nil)
		return err;
	if (len b < 768)
		return "PLAYPAL too short";
	r.palr = array[256] of byte;
	r.palg = array[256] of byte;
	r.palb = array[256] of byte;
	for (j := 0; j < 256; j++) {
		r.palr[j] = b[j*3];
		r.palg[j] = b[j*3+1];
		r.palb[j] = b[j*3+2];
	}

	# COLORMAP: 34 rows of 256 bytes (32 light levels + extras)
	i = w.find("COLORMAP");
	if (i < 0)
		return "no COLORMAP lump";
	(b, err) = w.read(i);
	if (b == nil)
		return err;
	if (len b < 32*256)
		return "COLORMAP too short";
	r.colormap = b;

	err = loadflats(r, w);
	if (err != nil)
		return err;
	err = loadtextures(r, w);
	if (err != nil)
		return err;
	animinit(r);
	return nil;
}

Renderer.flat(r: self ref Renderer, name: string): ref Flat
{
	for (i := 0; i < len r.flats; i++)
		if (r.flats[i].name == name) {
			if (r.flatanim != nil && i < len r.flatanim)
				return r.flats[r.flatanim[i]];
			return r.flats[i];
		}
	return nil;
}

Renderer.texture(r: self ref Renderer, name: string): ref Texture
{
	for (i := 0; i < len r.textures; i++)
		if (r.textures[i].name == name) {
			if (r.texanim != nil && i < len r.texanim)
				return r.textures[r.texanim[i]];
			return r.textures[i];
		}
	return nil;
}

Renderer.clear(r: self ref Renderer, color: int)
{
	c := byte color;
	for (i := 0; i < len r.fb8; i++)
		r.fb8[i] = c;
}

# vanilla R_DrawColumn.  Row wraps by tex.height (vanilla &127 works
# only for 128-tall textures; shorter ones need a real modulo or the
# last column reads past the composite).
Renderer.drawcolumn(r: self ref Renderer, x, yl, yh, light: int,
		tex: ref Texture, col, texturemid, iscale: int)
{
	count := yh - yl;
	if (count < 0)
		return;
	cm := light * 256;
	c := col % tex.width;
	if (c < 0)
		c += tex.width;
	src := c * tex.height;
	dest := yl * r.w + x;
	fracstep := iscale;
	frac := texturemid + (yl - r.centery) * fracstep;
	th := tex.height;
	for (i := 0; i <= count; i++) {
		row := (frac >> 16) % th;
		if (row < 0)
			row += th;
		r.fb8[dest] = r.colormap[cm + int tex.data[src + row]];
		dest += r.w;
		frac += fracstep;
	}
}

# vanilla R_DrawSpan (flat is always 64x64)
Renderer.drawspan(r: self ref Renderer, y, x1, x2, light: int,
		fl: ref Flat, xfrac, yfrac, xstep, ystep: int)
{	count := x2 - x1;
	if (count < 0)
		return;
	cm := light * 256;
	dest := y * r.w + x1;
	fx := xfrac;
	fy := yfrac;
	for (i := 0; i <= count; i++) {
		spot := ((fy >> 16) & 63) * 64 + ((fx >> 16) & 63);
		r.fb8[dest] = r.colormap[cm + int fl.data[spot]];
		dest++;
		fx += xstep;
		fy += ystep;
	}
}

# vanilla R_DrawFuzzColumn (r_draw.c): spectre/invisibility draw.  Reads
# fb8 at +-w (FUZZOFF) from the current dest through colormap row 6 and
# writes back; border rows are adjusted (yl 0 -> 1, yh h-1 -> h-2) so the
# +-w sample never leaves the framebuffer.  fuzzpos advances globally
# across calls/frames like vanilla.  Signs are vanilla fuzzoffset[], the
# magnitude is the framebuffer pitch (FUZZOFF = SCREENWIDTH).
FUZZTABLE:	con 50;
fuzzsign:	array of int;
fuzzpos:	int;

initfuzz()
{
	fuzzsign = array[] of {1, -1, 1, -1, 1, 1, -1,
		1, 1, -1, 1, 1, 1, -1,
		1, 1, 1, -1, -1, -1, -1,
		1, -1, -1, 1, 1, 1, 1, -1,
		1, -1, 1, 1, -1, -1, 1,
		1, -1, -1, -1, -1, 1, 1,
		1, 1, -1, 1, 1, -1, 1};
	fuzzpos = 0;
}

Renderer.drawfuzz(r: self ref Renderer, x, yl, yh: int)
{
	if (fuzzsign == nil)
		initfuzz();
	if (yl == 0)
		yl = 1;
	if (yh == r.h - 1)
		yh = r.h - 2;
	if (yl > yh)
		return;
	dest := yl * r.w + x;
	for (i := yl; i <= yh; i++) {
		src := dest + fuzzsign[fuzzpos] * r.w;
		if (src >= 0 && src < len r.fb8)
			r.fb8[dest] = r.colormap[6*256 + int r.fb8[src]];
		fuzzpos++;
		if (fuzzpos == FUZZTABLE)
			fuzzpos = 0;
		dest += r.w;
	}
}

# palette-map fb8 to BGRX quadruplets for the XRGB32 screen format
Renderer.convert(r: self ref Renderer, dst: array of byte)
{
	j := 0;
	for (i := 0; i < len r.fb8; i++) {
		c := int r.fb8[i];
		dst[j] = r.palb[c];
		dst[j+1] = r.palg[c];
		dst[j+2] = r.palr[c];
		dst[j+3] = byte 0;
		j += 4;
	}
}

# module-level wrappers for callers that don't import Renderer
rclear(r: ref Renderer, color: int)
{
	r.clear(color);
}

rtexture(r: ref Renderer, name: string): ref Texture
{
	return r.texture(name);
}

rflat(r: ref Renderer, name: string): ref Flat
{
	return r.flat(name);
}

rfixeddiv(a, b: int): int
{
	return fixeddiv(a, b);
}

rdrawcolumn(r: ref Renderer, x, yl, yh, light: int,
	tex: ref Texture, col, texturemid, iscale: int)
{
	r.drawcolumn(x, yl, yh, light, tex, col, texturemid, iscale);
}

rdrawspan(r: ref Renderer, y, x1, x2, light: int,
	fl: ref Flat, xfrac, yfrac, xstep, ystep: int)
{
	r.drawspan(y, x1, x2, light, fl, xfrac, yfrac, xstep, ystep);
}

rdrawfuzz(r: ref Renderer, x, yl, yh: int)
{
	r.drawfuzz(x, yl, yh);
}
