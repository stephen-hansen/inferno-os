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
	tex := ref Texture(name, width, height, j-1, nil);
	r.textures[idx] = tex;
	return gentex(tex, prefs, w);
}

# compose a texture from its patches into a dense column-major block
# (vanilla R_GenerateComposite, but eager rather than on first use)
gentex(tex: ref Texture, prefs: array of Patchref,
		w: ref Wad->File): string
{
	data := array[tex.width * tex.height] of byte;
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
		}
	}
	tex.data = data;
	return nil;
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
	return loadtextures(r, w);
}

Renderer.flat(r: self ref Renderer, name: string): ref Flat
{
	for (i := 0; i < len r.flats; i++)
		if (r.flats[i].name == name)
			return r.flats[i];
	return nil;
}

Renderer.texture(r: self ref Renderer, name: string): ref Texture
{
	for (i := 0; i < len r.textures; i++)
		if (r.textures[i].name == name)
			return r.textures[i];
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
{
	count := x2 - x1;
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

rdrawcolumn(r: ref Renderer, x, yl, yh, light: int,
	tex: ref Texture, col, texturemid, iscale: int)
{
	r.drawcolumn(x, yl, yh, light, tex, col, texturemid, iscale);
}
