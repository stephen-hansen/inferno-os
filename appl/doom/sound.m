# Sound stub: SFX interface with no audio output yet.  game.b
# calls startsound for doors/use feedback; real audio (and the
# full s_sound.c SFX table) comes with a later milestone.
#
# Reference: doomgeneric s_sound.c (GPL-2).

Sound: module {

	PATH:	con "/dis/doom/sound.dis";

	# door/use effects needed by the milestone 13 slice
	SFX_DOROPN, SFX_DORCLS, SFX_BDOPN, SFX_BDCLS,
	SFX_OOF: con iota;

	init:	fn(): string;

	# play an effect; srcx/srcy are 16.16 origin or 0 for global
	startsound:	fn(srcx, srcy, sfx: int);
};
