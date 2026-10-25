# HUD messages (milestone 19): hu_stuff.c + hu_lib.c, single-player
# path.  One-line message window at the top-left (HU_MSGHEIGHT 1,
# HU_MSGTIMEOUT 4*TICRATE, messages replace each other), HUD font
# STCFN033..STCFN095 ('!'..'_'), lowercase folded to uppercase and
# unknown chars rendered as a 4px gap exactly like HUlib_drawTextLine.
# The level title is built at start and shown only on the automap
# (vanilla HU_Drawer); M20 wires the automap flag.

implement Hu;

include "sys.m";
include "wad.m";
	File: import wad;
include "rend.m";
include "map.m";
include "info.m";
	inf: Info;
	MobjInfo: import inf;
include "sound.m";
include "game.m";
include "hu.m";

sys: Sys;
wad: Wad;
rend: Rend;
game: Game;

FONTSTART:	con '!';
FONTEND:	con '_';
FONTSIZE:	con 63;		# FONTEND - FONTSTART + 1
MSGTIMEOUT:	con 4 * 35;	# HU_MSGTIMEOUT (4 seconds at 35Hz)
TITLEY:		con 167;	# HU_TITLEY = 167 - font height

# Limbo rejects `array of byte` as an allocation element type
Patch: adt {
	d:	array of byte;
};

font:		array of Patch;
fonth:		int;		# hud font height (STCFN033)
message:	string;
message_on:	int;
message_counter:	int;
title:		string;
automapactive:	int;
showmessages:	int;	# menu Messages option (vanilla showMessages)
force:		int;	# one-shot message_dontfuckwithme (menu toggle)

# vanilla HUSTR_E1M1..E1M9 (d_englsh.h)
maptitles := array[] of {
	"E1M1: Hangar",
	"E1M2: Nuclear Plant",
	"E1M3: Toxin Refinery",
	"E1M4: Command Control",
	"E1M5: Phobos Lab",
	"E1M6: Central Processing",
	"E1M7: Computer Station",
	"E1M8: Phobos Anomaly",
	"E1M9: Military Base",
};

getpatch(w: ref Wad->File, name: string): array of byte
{
	i := w.find(name);
	if (i < 0)
		return nil;
	(b, err) := w.read(i);
	if (b == nil)
		return nil;
	return b;
}

init(w: ref Wad->File): string
{
	sys = load Sys Sys->PATH;
	wad = load Wad Wad->PATH;	# File methods dispatch through it
	if (wad == nil)
		return "can't load Wad module";
	rend = load Rend Rend->PATH;
	if (rend == nil)
		return "can't load Rend module";
	font = array[FONTSIZE] of Patch;
	for (i := 0; i < FONTSIZE; i++) {
		font[i].d = getpatch(w, sys->sprint("STCFN%.3d", int FONTSTART + i));
		if (font[i].d == nil)
			return "missing STCFN font patch";
	}
	fonth = rend->rpatchheight(font[0].d);
	message = "";
	message_on = 0;
	message_counter = 0;
	title = "";
	automapactive = 0;
	showmessages = 1;
	force = 0;
	return nil;
}

start(mapname: string)
{
	# vanilla HU_Start: hide any message still on screen from the
	# previous level (the line itself is kept, as in vanilla)
	message_on = 0;
	# title from mapnames[(episode-1)*9+map-1]
	title = mapname;
	if (len mapname == 4 && mapname[0] == 'E' && mapname[2] == 'M') {
		m := int mapname[3] - int '0';
		if (m >= 1 && m <= len maptitles)
			title = maptitles[m - 1];
	}
}

noteerror(s: string)
{
	sys->print("hu: %s\n", s);
}

ticker(p: ref Game->Player)
{
	if (p == nil)
		return;
	# tick down the message timer (HU_Ticker)
	if (message_counter != 0) {
		message_counter--;
		if (message_counter == 0)
			message_on = 0;
	}
	# new message replaces the line (HU_MSGHEIGHT 1).  Vanilla
	# shows player messages only while showMessages is on, except
	# one-shot messages marked message_dontfuckwithme (the menu's
	# Messages toggle uses that to confirm MSGOFF/MSGON).
	if (p.message != "") {
		if (showmessages == 0 && force == 0)
			return;
		message = p.message;
		p.message = "";
		message_on = 1;
		message_counter = MSGTIMEOUT;
		force = 0;
	}
}

upper(c: int): int
{
	if (c >= 'a' && c <= 'z')
		return c - ('a' - 'A');
	return c;
}

# vanilla HUlib_drawTextLine: in-font chars drawn at x and advance by
# the patch width; spaces/unknown advance 4; stop when past the edge.
drawline(r: ref Rend->Renderer, s: string, x0, y: int)
{
	x := x0;
	for (i := 0; i < len s; i++) {
		c := upper(int s[i]);
		if (c != ' ' && c >= FONTSTART && c <= FONTEND) {
			pd := font[c - int FONTSTART].d;
			w := rend->rpatchwidth(pd);
			if (x + w > r.w)
				break;
			rend->rdrawpatch(r, x, y, pd);
			x += w;
		} else {
			x += 4;
			if (x >= r.w)
				break;
		}
	}
}

drawer(r: ref Rend->Renderer)
{
	if (message_on)
		drawline(r, message, 0, 0);
	if (automapactive)
		drawline(r, title, 0, TITLEY - fonth);
}

setautomap(on: int)
{
	automapactive = on;
}

setmessages(on: int)
{
	showmessages = on;
}

forcemsg()
{
	force = 1;
}
