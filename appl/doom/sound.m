# SFX engine (milestone 17): Doom mixer, 8 x 8-bit unsigned
# channels at 11025 Hz mono.  Reference: doomgeneric s_sound.c,
# sounds.c (GPL-2), chocolate-doom i_sdlsound.c DMX lump handling.
#
# Vanilla-faithful channel rules (S_GetChannel priority + cutoff,
# same-origin reuse, S_AdjustSoundParams distance/pan, link pitch)
# with mono output (pan averages out exactly, so separation is
# computed for API fidelity/future stereo but not mixed).
# No audio hardware in the test env: output goes to /dev/audio when
# present (enc pcm, bits 8, chans 1, rate 11025), else to doom.pcm
# (raw unsigned-8 mono 11025) for audit/playback elsewhere.  Music
# (MUS + synth) is out of scope for 17 (needs audio hardware anyway).

Sound: module {

	PATH:	con "/dis/doom/sound.dis";

# SFX ids match doomgeneric sounds.h order exactly, so mobjinfo
# seesound/deathsound ids (transcribed vanilla numbers) can be
# passed straight through.
	SFX_NONE,
	SFX_PISTOL, SFX_SHOTGN, SFX_SGCOCK, SFX_DSHTGN,
	SFX_DBOPN, SFX_DBCLS, SFX_DBLOAD, SFX_PLASMA,
	SFX_BFG, SFX_SAWUP, SFX_SAWIDL, SFX_SAWFUL,
	SFX_SAWHIT, SFX_RLAUNC, SFX_RXPLOD, SFX_FIRSHT,
	SFX_FIRXPL, SFX_PSTART, SFX_PSTOP, SFX_DOROPN,
	SFX_DORCLS, SFX_STNMOV, SFX_SWTCHN, SFX_SWTCHX,
	SFX_PLPAIN, SFX_DMPAIN, SFX_POPAIN, SFX_VIPAIN,
	SFX_MNPAIN, SFX_PEPAIN, SFX_SLOP, SFX_ITEMUP,
	SFX_WPNUP, SFX_OOF, SFX_TELEPT, SFX_POSIT1,
	SFX_POSIT2, SFX_POSIT3, SFX_BGSIT1, SFX_BGSIT2,
	SFX_SGTSIT, SFX_CACSIT, SFX_BRSSIT, SFX_CYBSIT,
	SFX_SPISIT, SFX_BSPSIT, SFX_KNTSIT, SFX_VILSIT,
	SFX_MANSIT, SFX_PESIT, SFX_SKLATK, SFX_SGTATK,
	SFX_SKEPCH, SFX_VILATK, SFX_CLAW, SFX_SKESWG,
	SFX_PLDETH, SFX_PDIEHI, SFX_PODTH1, SFX_PODTH2,
	SFX_PODTH3, SFX_BGDTH1, SFX_BGDTH2, SFX_SGTDTH,
	SFX_CACDTH, SFX_SKLDTH, SFX_BRSDTH, SFX_CYBDTH,
	SFX_SPIDTH, SFX_BSPDTH, SFX_VILDTH, SFX_KNTDTH,
	SFX_PEDTH, SFX_SKEDTH, SFX_POSACT, SFX_BGACT,
	SFX_DMACT, SFX_BSPACT, SFX_BSPWLK, SFX_VILACT,
	SFX_NOWAY, SFX_BAREXP, SFX_PUNCH, SFX_HOOF,
	SFX_METAL, SFX_CHGUN, SFX_TINK, SFX_BDOPN,
	SFX_BDCLS, SFX_ITMBK, SFX_FLAME, SFX_FLAMST,
	SFX_GETPOW, SFX_BOSPIT, SFX_BOSCUB, SFX_BOSSIT,
	SFX_BOSPN, SFX_BOSDTH, SFX_MANATK, SFX_MANDTH,
	SFX_SSSIT, SFX_SSDTH, SFX_KEENPN, SFX_KEENDT,
	SFX_SKEACT, SFX_SKESIT, SFX_SKEATK, SFX_RADIO: con iota;

	NUMSFX:	con 109;

	init:	fn(path: string): string;

	# vanilla S_Start (level start): kill all playing channels.
	start:	fn();

	# play an effect; srcx/srcy are 16.16 origin, (0,0) = global
	# (vanilla nil origin).  positional sounds attenuate/pan by
	# listener; global sounds play full/center.
	startsound:	fn(srcx, srcy, sfx: int);

	# per-tic: S_UpdateSounds listener tracking (vol/sep recompute,
	# stop inaudible/finished), then mix+emit one tic (315 samples).
	# lx/ly 16.16 listener pos, angle BAM listener heading.
	updatesounds:	fn(lx, ly, angle: int);

	# test/diagnostic: number of busy channels (0..8).
	nchan:	fn(): int;
};
