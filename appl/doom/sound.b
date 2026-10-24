# SFX engine (milestone 17): Doom mixer, 8 x 8-bit unsigned
# channels at 11025 Hz mono.  Reference: doomgeneric s_sound.c,
# sounds.c (GPL-2), chocolate-doom i_sdlsound.c DMX lump handling.
#
# Vanilla-faithful channel rules (S_GetChannel priority + cutoff,
# same-origin reuse, S_AdjustSoundParams distance/pan, link pitch)
# with mono output (left+right pan averages to vol exactly, so
# separation is computed for API fidelity/future stereo but not
# mixed).  No audio hardware in the test env: output goes to
# /dev/audio when present (enc pcm, bits 8, chans 1, rate 11025),
# else to doom.pcm (raw unsigned-8 mono 11025) for audit/playback
# elsewhere.  Music (MUS + synth) is out of scope for 17.

implement Sound;

include "sound.m";
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
include "wad.m";
	wad: Wad;
	File: import wad;
include "math.m";
	math: Math;

NCHAN: con 8;			# vanilla snd_channels
S_CLIPDIST: con 1200*65536;	# S_CLIPPING_DIST: beyond this, silent
S_CLOSEDIST: con 200*65536;	# S_CLOSE_DIST: inside this, full volume
S_ATTEN: con 1000;		# S_ATTENUATOR (clipping-close in map units)
S_SWING: con 96*65536;		# S_STEREO_SWING
NORM_PITCH: con 128;
NORM_SEP: con 128;
SFXVOL: con 64;			# vanilla default 8*8 on the 0-127 scale
MIXRATE: con 11025;
TICNS: con 315;			# MIXRATE/35 samples per tic, exact
LINKPITCH: con 150;		# chgun->pistol link pitch (vanilla SOUND_LINK)
LINKVOL: con 0;		# chgun link volume trim (a no-op, kept)

sfxname: array of string;	# lump suffixes (DS+sfxname)
sfxpri: array of int;		# vanilla priorities
sfxlink: array of int;		# link target id or -1 (chgun->pistol only)
sfxpool: array of byte;		# flat decoded-sample pool (no ref arrays)
sfxoffs: array of int;		# pool offset per sfx, -1 if lump missing
sfxlen: array of int;		# sample counts
sfxuse: array of int;		# usefulness refs (no eviction: preloaded)
chsfx: array of int;		# sfx id or -1 (free)
chox, choy: array of int;	# origin 16.16
chglob: array of int;		# 1 = global (0,0) origin
chpos: array of int;		# 16.16 playback position
chstep: array of int;		# 16.16 samples per output sample (pitch)
chvol, chsep: array of int;	# current volume 0-127 / sep 0-255
chstart: array of int;		# pool offset for this channel
chlen: array of int;		# sample count for this channel
mixacc: array of int;		# [TICNS] preallocated mix accumulator
outbuf: array of byte;		# [TICNS] preallocated output frame
audiofd, pcmfd: ref Sys->FD;
havemath: int;
ready: int;
lastlx, lastly, lastlang: int;	# last listener pos (for startsound)

fail(s: string)
{
	sys->fprint(sys->fildes(2), "sound: %s\n", s);
	raise "fail:error";
}

init(path: string): string
{
	sys = load Sys Sys->PATH;
	if (sys == nil)
		return "can't load Sys";
	wad = load Wad Wad->PATH;
	if (wad == nil)
		wad = load Wad "wad.dis";
	if (wad == nil)
		return "can't load Wad module";
	math = load Math Math->PATH;
	havemath = 1;
	if (math == nil)
		havemath = 0;
	sfxname = array[] of {
"NONE","PISTOL","SHOTGN","SGCOCK","DSHTGN","DBOPN","DBCLS","DBLOAD","PLASMA",
"BFG","SAWUP","SAWIDL","SAWFUL","SAWHIT","RLAUNC","RXPLOD","FIRSHT","FIRXPL",
"PSTART","PSTOP","DOROPN","DORCLS","STNMOV","SWTCHN","SWTCHX","PLPAIN","DMPAIN",
"POPAIN","VIPAIN","MNPAIN","PEPAIN","SLOP","ITEMUP","WPNUP","OOF","TELEPT",
"POSIT1","POSIT2","POSIT3","BGSIT1","BGSIT2","SGTSIT","CACSIT","BRSSIT","CYBSIT",
"SPISIT","BSPSIT","KNTSIT","VILSIT","MANSIT","PESIT","SKLATK","SGTATK","SKEPCH",
"VILATK","CLAW","SKESWG","PLDETH","PDIEHI","PODTH1","PODTH2","PODTH3","BGDTH1",
"BGDTH2","SGTDTH","CACDTH","SKLDTH","BRSDTH","CYBDTH","SPIDTH","BSPDTH","VILDTH",
"KNTDTH","PEDTH","SKEDTH","POSACT","BGACT","DMACT","BSPACT","BSPWLK","VILACT",
"NOWAY","BAREXP","PUNCH","HOOF","METAL","CHGUN","TINK","BDOPN","BDCLS",
"ITMBK","FLAME","FLAMST","GETPOW","BOSPIT","BOSCUB","BOSSIT","BOSPN","BOSDTH",
"MANATK","MANDTH","SSSIT","SSDTH","KEENPN","KEENDT","SKEACT","SKESIT","SKEATK",
"RADIO"
	};
	sfxpri = array[] of {
0,64,64,64,64,64,64,64,64,
64,64,118,64,64,64,70,70,70,
100,100,100,100,119,78,78,96,96,
96,96,96,96,78,78,78,96,32,
98,98,98,98,98,98,98,94,92,
90,90,90,90,90,90,70,70,70,
70,70,70,32,32,70,70,70,70,
70,70,70,70,32,32,32,32,32,
32,32,32,120,120,120,100,100,100,
78,60,64,70,70,64,60,100,100,
100,32,32,60,70,70,70,70,70,
70,70,70,70,70,70,70,70,70,
60
	};
	sfxlink = array[] of {
-1,-1,-1,-1,-1,-1,-1,-1,-1,
-1,-1,-1,-1,-1,-1,-1,-1,-1,
-1,-1,-1,-1,-1,-1,-1,-1,-1,
-1,-1,-1,-1,-1,-1,-1,-1,-1,
-1,-1,-1,-1,-1,-1,-1,-1,-1,
-1,-1,-1,-1,-1,-1,-1,-1,-1,
-1,-1,-1,-1,-1,-1,-1,-1,-1,
-1,-1,-1,-1,-1,-1,-1,-1,-1,
-1,-1,-1,-1,-1,-1,-1,-1,-1,
-1,-1,-1,-1,-1,1,-1,-1,-1,
-1,-1,-1,-1,-1,-1,-1,-1,-1,
-1,-1,-1,-1,-1,-1,-1,-1,-1,
-1
	};
	# channel + mixer state: preallocate everything (GC rule: no
	# allocation per tic/mix)
	chsfx = array[NCHAN] of int;
	chox = array[NCHAN] of int;
	choy = array[NCHAN] of int;
	chglob = array[NCHAN] of int;
	chpos = array[NCHAN] of int;
	chstep = array[NCHAN] of int;
	chvol = array[NCHAN] of int;
	chsep = array[NCHAN] of int;
	chstart = array[NCHAN] of int;
	chlen = array[NCHAN] of int;
	for (ci := 0; ci < NCHAN; ci++)
		chsfx[ci] = -1;
	mixacc = array[TICNS] of int;
	outbuf = array[TICNS] of byte;
	for (mi := 0; mi < TICNS; mi++) {
		mixacc[mi] = 0;
		outbuf[mi] = byte 128;
	}
	sfxoffs = array[NUMSFX] of int;
	sfxlen = array[NUMSFX] of int;
	sfxuse = array[NUMSFX] of int;
	for (si := 0; si < NUMSFX; si++) {
		sfxoffs[si] = -1;
		sfxlen[si] = 0;
		sfxuse[si] = -1;
	}
	# load + decode every DS* lump once (135KB shareware).
	# two passes: size the flat pool, then fill it (no ref arrays).
	(w, err) := wad->open(path);
	if (w == nil)
		return err;
	poolsz := 0;
	for (li := 0; li < NUMSFX; li++) {
		ln := w.find(sys->sprint("DS%s", sfxname[li]));
		if (ln >= 0)
			poolsz = poolsz + w.lumps[ln].size;
	}
	sfxpool = array[poolsz] of byte;
	po := 0;
	nl := 0;
	nmiss := 0;
	for (li2 := 0; li2 < NUMSFX; li2++) {
		ln := w.find(sys->sprint("DS%s", sfxname[li2]));
		if (ln < 0) {
			nmiss++;
			continue;	# Doom2-only id: silent no-op when played
		}
		(b, rerr) := w.read(ln);
		if (b == nil) {
			w.close();
			return sys->sprint("read %s: %s", sfxname[li2], rerr);
		}
		(n, derr) := dmxlump(b, sfxname[li2], po);
		if (n < 0) {
			sys->print("sound: lump %s rejected (%s)\n",
				sfxname[li2], derr);
			nmiss++;
			continue;
		}
		sfxoffs[li2] = po;
		sfxlen[li2] = n;
		po = po + n;
		nl++;
	}
	w.close();
	sys->print("sound: %d lumps, %d samples, %d missing (shareware)\n",
		nl, po, nmiss);
	# output sink: /dev/audio if the emu has it, else doom.pcm
	audiofd = nil;
	pcmfd = nil;
	(afd, aerr) := audioopen();
	if (afd == nil)
		sys->print("sound: no /dev/audio (%s): writing doom.pcm\n", aerr);
	else {
		sys->print("sound: /dev/audio open (11025Hz mono u8)\n");
		audiofd = afd;
	}
	if (audiofd == nil) {
		pcmfd = sys->create("doom.pcm", Sys->OWRITE, 8r666);
		if (pcmfd == nil)
			return "can't create doom.pcm";
	}
	ready = 1;
	return nil;
}

# open audio: try #A/ (always works when the emu has devaudio),
# then /dev/ (other Inferno configurations), else file fallback.
# Returns (fd, nil) or (nil, reason).
audioopen(): (ref Sys->FD, string)
{
	for (i := 0; i < 2; i++) {
		pre := "#A/";
		if (i == 1)
			pre = "/dev/";
		ctl := sys->open(pre + "audioctl", Sys->OWRITE);
		if (ctl == nil)
			continue;
		# NB: bits first — the emu's choosefmt() derives the OSS
		# format from (bits, enc), so enc-before-bits is rejected.
		if (sys->fprint(ctl, "bits 8\n") < 0)
			continue;
		if (sys->fprint(ctl, "enc pcm\n") < 0)
			continue;
		if (sys->fprint(ctl, "chans 1\n") < 0)
			continue;
		if (sys->fprint(ctl, "rate 11025\n") < 0)
			continue;
		fd := sys->open(pre + "audio", Sys->OWRITE);
		if (fd == nil)
			continue;
		return (fd, nil);
	}
	return (nil, "no audio device");
}

# DMX lump -> flat pool at doff: 8-byte header, validate, skip 16+8
# head bytes, drop 16 tail bytes, discard lumps with <=48 samples,
# 22050Hz decimated.  Returns (samples, nil) or (-1, reason).
dmxlump(b: array of byte, name: string, doff: int): (int, string)
{
	if (len b < 8)
		return (-1, "short");
	if (int b[0] != 16r03 || int b[1] != 16r00)
		return (-1, sys->sprint("bad magic %s", name));
	rate := int b[2] | (int b[3] << 8);
	length := int b[4] | (int b[5] << 8) | (int b[6] << 16) | (int b[7] << 24);
	if (length > len b - 8 || length <= 48)
		return (-1, sys->sprint("bad length %d", length));
	n := length - 32;
	for (di := 0; di < n; di++)
		sfxpool[doff+di] = b[24+di];
	if (rate == MIXRATE)
		return (n, nil);
	if (rate == 2*MIXRATE) {
		# 2:1 decimate (DSITMBK, the only 22050 lump)
		m := n / 2;
		for (dj := 0; dj < m; dj++)
			sfxpool[doff+dj] = sfxpool[doff+2*dj];
		return (m, nil);
	}
	return (-1, sys->sprint("rate %d", rate));
}

# vanilla S_Start (level start): kill all playing channels.
start()
{
	if (!ready)
		return;
	for (ci := 0; ci < NCHAN; ci++)
		if (chsfx[ci] >= 0)
			stopchannel(ci);
}

# test/diagnostic: number of busy channels.
nchan(): int
{
	n := 0;
	for (ci := 0; ci < NCHAN; ci++)
		if (chsfx[ci] >= 0)
			n++;
	return n;
}

# vanilla S_StopChannel: stop + usefulness-- (no eviction: preloaded).
stopchannel(c: int)
{
	id := chsfx[c];
	if (id < 0)
		return;
	if (sfxuse[id] > 0)
		sfxuse[id] = sfxuse[id] - 1;
	chsfx[c] = -1;
}

# vanilla S_StopSound: stop the FIRST channel with this origin.
stopsound(ox, oy, glob: int)
{
	for (ci := 0; ci < NCHAN; ci++)
		if (chsfx[ci] >= 0 && chglob[ci] == glob
		    && chox[ci] == ox && choy[ci] == oy) {
			stopchannel(ci);
			break;
		}
}

# vanilla S_GetChannel: free slot; else same-origin reuse; else
# kick the first channel with priority >= the new one; else -1.
# (The >= comparison is vanilla's, quirks and all.)
getchannel(ox, oy, glob, sfx: int): int
{
	for (ci := 0; ci < NCHAN; ci++) {
		if (chsfx[ci] < 0)
			break;
		if (!glob && !chglob[ci]
		    && chox[ci] == ox && choy[ci] == oy) {
			stopchannel(ci);
			break;
		}
	}
	if (ci == NCHAN) {
		for (ci = 0; ci < NCHAN; ci++)
			if (sfxpri[chsfx[ci]] >= sfxpri[sfx])
				break;
		if (ci == NCHAN)
			return -1;
		stopchannel(ci);
	}
	return ci;
}

# vanilla S_AdjustSoundParams (integer math, bit-exact): audibility
# + volume (0-127) from approx distance; separation via heading.
# Returns (audible, vol, sep); sep is best-effort (Math atan2/sin)
# and unused by the mono mix (pan averages out to vol exactly).
adjust(lx, ly, lang, ox, oy: int): (int, int, int)
{
	adx := ox - lx;
	if (adx < 0)
		adx = -adx;
	ady := oy - ly;
	if (ady < 0)
		ady = -ady;
	mn := adx;
	if (ady < mn)
		mn = ady;
	approx := adx + ady - (mn >> 1);
	if (approx > S_CLIPDIST)
		return (0, 0, NORM_SEP);
	vol := SFXVOL;
	if (approx >= S_CLOSEDIST)
		vol = (SFXVOL * ((S_CLIPDIST - approx) >> 16)) / S_ATTEN;
	sep := NORM_SEP;
	if (havemath) {
		# source bearing minus listener heading -> stereo position
		sang := math->atan2(real(oy - ly), real(ox - lx));
		langr := real(lang) * (2.0 * 3.14159265358979 / 4294967296.0);
		rel := sang - langr;
		sep = NORM_SEP - (((S_SWING>>16) * int(math->sin(rel) * 65536.0)) >> 16);
		if (sep < 0)
			sep = 0;
		if (sep > 255)
			sep = 255;
	}
	if (vol <= 0)
		return (0, 0, sep);
	return (1, vol, sep);
}

# vanilla S_StartSound (at the current tic volume/sep; per-tic
# S_UpdateSounds re-tracks).  src (0,0) = global (vanilla nil).
startsound(srcx, srcy, sfx: int)
{
	if (!ready)
		return;
	if (sfx < 1 || sfx >= NUMSFX)
		fail(sys->sprint("sound: bad sfx %d", sfx));
	glob := 0;
	if (srcx == 0 && srcy == 0)
		glob = 1;
	vol := SFXVOL;
	sep := NORM_SEP;
	pitch := NORM_PITCH;
	if (sfxlink[sfx] >= 0) {
		# linked lump (chgun->pistol): pitch shift + volume trim
		vol = vol + LINKVOL;
		pitch = LINKPITCH;
		if (vol < 1)
			return;
		if (vol > SFXVOL)
			vol = SFXVOL;
	}
	lid := sfx;
	if (sfxlink[sfx] >= 0)
		lid = sfxlink[sfx];
	if (sfxoffs[lid] < 0)
		return;		# shareware-missing lump: silent no-op
	if (!glob && (srcx != lastlx || srcy != lastly)) {
		# same-spot-as-listener stays full/center (vanilla rule)
		(ok, v, s) := adjust(lastlx, lastly, lastlang, srcx, srcy);
		if (!ok)
			return;
		vol = v;
		sep = s;
	}
	# kill old sound from this origin (vanilla order: before alloc)
	stopsound(srcx, srcy, glob);
	c := getchannel(srcx, srcy, glob, sfx);
	if (c < 0)
		return;
	if (sfxuse[sfx] < 0)
		sfxuse[sfx] = 1;
	else
		sfxuse[sfx] = sfxuse[sfx] + 1;
	chsfx[c] = sfx;
	chox[c] = srcx;
	choy[c] = srcy;
	chglob[c] = glob;
	chpos[c] = 0;
	if (sfxlink[sfx] >= 0) {
		chstart[c] = sfxoffs[sfxlink[sfx]];
		chlen[c] = sfxlen[sfxlink[sfx]];
		chstep[c] = (pitch << 16) / NORM_PITCH;
	} else {
		chstart[c] = sfxoffs[sfx];
		chlen[c] = sfxlen[sfx];
		chstep[c] = 1 << 16;
	}
	chvol[c] = vol;
	chsep[c] = sep;
}

# vanilla S_UpdateSounds + per-tic mix+emit (315 samples = 1 tic).
updatesounds(lx, ly, angle: int)
{
	if (!ready)
		return;
	lastlx = lx;
	lastly = ly;
	lastlang = angle;
	# retrack live channels (link trim, audibility, params)
	for (ci := 0; ci < NCHAN; ci++) {
		if (chsfx[ci] < 0)
			continue;
		id := chsfx[ci];
		if ((chpos[ci] >> 16) >= chlen[ci]) {
			stopchannel(ci);	# finished: free it
			continue;
		}
		vol := SFXVOL;
		sep := NORM_SEP;
		if (sfxlink[id] >= 0) {
			vol = vol + LINKVOL;
			if (vol < 1) {
				stopchannel(ci);
				continue;
			}
			if (vol > SFXVOL)
				vol = SFXVOL;
		}
		if (!chglob[ci] && (chox[ci] != lx || choy[ci] != ly)) {
			# same-spot-as-listener stays full/center (defaults)
			(ok, v, s) := adjust(lx, ly, angle, chox[ci], choy[ci]);
			if (!ok) {
				stopchannel(ci);
				continue;
			}
			vol = v;
			sep = s;
		}
		chvol[ci] = vol;
		chsep[ci] = sep;
	}
	# mix one tic (SDL_mixer-equivalent: sum (s-128)*vol, /128, clamp)
	for (zi := 0; zi < TICNS; zi++)
		mixacc[zi] = 0;
	for (ci = 0; ci < NCHAN; ci++) {
		if (chsfx[ci] < 0)
			continue;
		st := chstart[ci];
		n := chlen[ci];
		pos := chpos[ci];
		step := chstep[ci];
		v := chvol[ci];
		for (mi := 0; mi < TICNS; mi++) {
			p := pos >> 16;
			if (p >= n)
				break;
			mixacc[mi] = mixacc[mi] + (int sfxpool[st+p] - 128) * v;
			pos = pos + step;
		}
		chpos[ci] = pos;
		if ((pos >> 16) >= n)
			stopchannel(ci);
	}
	for (oi := 0; oi < TICNS; oi++) {
		s := 128 + mixacc[oi] / 128;
		if (s < 0)
			s = 0;
		else if (s > 255)
			s = 255;
		outbuf[oi] = byte s;
	}
	if (audiofd != nil)
		sys->write(audiofd, outbuf, TICNS);
	else if (pcmfd != nil)
		sys->write(pcmfd, outbuf, TICNS);
}
