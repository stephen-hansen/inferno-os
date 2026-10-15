# Sound stub: startsound is a no-op until audio output exists.
# Reference: doomgeneric s_sound.c (GPL-2).

implement Sound;

include "sound.m";

init(): string
{
	return nil;
}

startsound(srcx, srcy, sfx: int)
{
	srcx = srcx;
	srcy = srcy;
	sfx = sfx;
}
