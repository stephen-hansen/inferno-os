implement Wad;

include "sys.m";
	sys: Sys;

include "wad.m";

HDRLEN:	con 12;			# 4 magic + 4 numlumps + 4 infotableofs
DIRENTLEN:	con 16;		# 8 name + 4 filepos + 4 size
MAXLUMPS:	con 1<<16;	# sanity bound; doom2.wad has ~2400

le32(b: array of byte, i: int): int
{
	return int b[i]
		| (int b[i+1] << 8)
		| (int b[i+2] << 16)
		| (int b[i+3] << 24);
}

lumpname(b: array of byte, i: int): string
{
	s := "";
	for (j := 0; j < 8 && b[i+j] != byte 0; j++)
		s += sys->sprint("%c", int b[i+j]);
	return s;
}

pread(fd: ref Sys->FD, buf: array of byte, off: int): string
{
	n := sys->pread(fd, buf, len buf, big off);
	if (n != len buf)
		return sys->sprint("short read at %d: %r", off);
	return nil;
}

open(path: string): (ref File, string)
{
	if (sys == nil)
		sys = load Sys Sys->PATH;
	fd := sys->open(path, Sys->OREAD);
	if (fd == nil)
		return (nil, sys->sprint("can't open %s: %r", path));

	err: string;
	hdr := array[HDRLEN] of byte;
	if ((err = pread(fd, hdr, 0)) != nil) {
		fd = nil;
		return (nil, err);
	}

	wtype := string hdr[0:4];
	if (wtype != "IWAD" && wtype != "PWAD") {
		fd = nil;
		return (nil, sys->sprint("%s: not a WAD (bad magic)", path));
	}

	numlumps := le32(hdr, 4);
	infotableofs := le32(hdr, 8);
	if (numlumps <= 0 || numlumps > MAXLUMPS || infotableofs < HDRLEN) {
		fd = nil;
		return (nil, sys->sprint("%s: corrupt WAD header", path));
	}

	dir := array[numlumps*DIRENTLEN] of byte;
	if ((err = pread(fd, dir, infotableofs)) != nil) {
		fd = nil;
		return (nil, err);
	}

	lumps := array[numlumps] of Lump;
	for (i := 0; i < numlumps; i++) {
		o := i*DIRENTLEN;
		lumps[i] = Lump(lumpname(dir, o+8), le32(dir, o), le32(dir, o+4));
	}

	return (ref File(fd, wtype, numlumps, infotableofs, lumps), nil);
}

File.close(w: self ref File)
{
	w.fd = nil;
}

File.read(w: self ref File, i: int): (array of byte, string)
{
	if (sys == nil)
		sys = load Sys Sys->PATH;
	if (i < 0 || i >= w.numlumps)
		return (nil, sys->sprint("lump index %d out of range", i));
	l := w.lumps[i];
	if (l.size < 0)
		return (nil, sys->sprint("lump %s has negative size", l.name));
	b := array[l.size] of byte;
	if (l.size > 0 && (err := pread(w.fd, b, l.filepos)) != nil)
		return (nil, sys->sprint("reading lump %s: %s", l.name, err));
	return (b, nil);
}

# case-insensitive 8-char compare, vanilla W_CheckNumForName style
eq8(a, b: string): int
{
	na := len a;
	nb := len b;
	if (na > 8)
		na = 8;
	if (nb > 8)
		nb = 8;
	if (na != nb)
		return 0;
	for (i := 0; i < na; i++) {
		ca := int a[i];
		cb := int b[i];
		if (ca >= 16r61 && ca <= 16r7a)
			ca -= 16r20;
		if (cb >= 16r61 && cb <= 16r7a)
			cb -= 16r20;
		if (ca != cb)
			return 0;
	}
	return 1;
}

# last match wins, as vanilla searches the directory backwards
File.find(w: self ref File, name: string): int
{
	for (i := w.numlumps - 1; i >= 0; i--)
		if (eq8(w.lumps[i].name, name))
			return i;
	return -1;
}
