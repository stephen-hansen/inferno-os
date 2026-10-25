# Menu system (milestone 21): m_menu.c, shareware Doom 1.9 path.
# Reference: doomgeneric m_menu.c (GPL-2).

implement Menu;

include "sys.m";
include "wad.m";
	File: import wad;
include "rend.m";
	Renderer: import rend;
include "map.m";
include "info.m";
	inf: Info;
	MobjInfo: import inf;
include "sound.m";
include "game.m";
include "hu.m";
include "menu.m";

sys: Sys;
wad: Wad;
rend: Rend;
game: Game;
sound: Sound;
hu: Hu;

# menu line geometry (m_menu.c)
SKULLXOFF:	con -32;
LINEHEIGHT:	con 16;

# keys (doomkeys.h values / our encoding)
Esc:	con 27;
Space:	con 32;
Y:	con 'y';
N:	con 'n';
# Arrow keys: module/keyboard.m View = Spec|16r10, Up = View|2.
# (doom.b's Up..Right use the same encoding.)
KU:	con 16rE012;
KD:	con 16rE013;
KL:	con 16rE014;
KR:	con 16rE015;

# menu indices
MMain, MEpisode, MSkill, MOptions, MRead1, MRead2, MSound: con iota;
NMENUS:	con 7;

# item routine ids (M_* from m_menu.c)
ActNone, ActNewGame, ActEpisode, ActSkill, ActOptions, ActEndGame,
ActEndGameConfirm, ActReadThis, ActReadThis2, ActFinishRead,
ActQuit, ActQuitConfirm, ActMessages, ActDetail, ActSize, ActSens,
ActSfxVol, ActMusVol, ActSound, ActVerifyNightmare: con iota;

# Limbo rejects `array of byte` as an allocation element type
Patch: adt {
	d:	array of byte;
};

Item: adt {
	status:	int;		# -1 blank, 0 none, 1 normal, 2 slider
	nameidx:	int;		# index into patches, -1 = ""
	act:	int;
	key:	int;		# hotkey
};

MenuDef: adt {
	first, n:	int;		# range in items
	prev:	int;		# previous menu, -1 = none
	x, y:	int;
	laston:	int;
};

items:	array of Item;
icursor:	int;
menus:	array of MenuDef;

patches:	array of Patch;
font:		array of Patch;
fonth:		int;

menuactive:	int;
current:	int;
itemOn:		int;
skullAnimCounter:	int;
whichSkull:	int;
gametic:		int;
usergame:	int;

messageToPrint:	int;
messageString:	string;
messageAct:	int;
messageNeedsInput:	int;
messageLastActive:	int;

showMessages:	int;
detailLevel:	int;
screenblocks:	int;
screenSize:	int;
mouseSensitivity:	int;
sfxVolume:	int;
musicVolume:	int;

epi:	int;

# pending host action
actKind, actEpi, actSkill: int;

# vanilla strings (d_englsh.h / dstrings.c)
SWSTRING:	con "this is the shareware version of doom.\n\nyou need to order the entire trilogy.\n\npress a key.";
NIGHTMARE:	con "are you sure? this skill level\nisn't even remotely fair.\n\npress y or n.";
ENDGAME:	con "are you sure you want to end the game?\n\npress y or n.";
DOSY:		con "(press y to quit to dos.)";
MSGOFF:		con "Messages OFF";
MSGON:		con "Messages ON";
DETAILHI:	con "High detail";
DETAILLO:	con "Low detail";

endmsgs := array[] of {
	"are you sure you want to\nquit this great game?",
	"please don't leave, there's more\ndemons to toast!",
	"let's beat it -- this is turning\ninto a bloodbath!",
	"i wouldn't leave if i were you.\ndos is much worse.",
	"you're trying to say you like dos\nbetter than me, right?",
	"don't leave yet -- there's a\ndemon around that corner!",
	"ya know, next time you come in here\ni'm gonna toast ya.",
	"go ahead and leave. see if i care.",
};

# menu patch lumps (all present in doom1.wad)
patchNames := array[] of {
	"M_DOOM", "M_NGAME", "M_OPTION", "M_RDTHIS", "M_QUITG",
	"M_EPI1", "M_EPI2", "M_EPI3",
	"M_JKILL", "M_ROUGH", "M_HURT", "M_ULTRA", "M_NMARE",
	"M_NEWG", "M_SKILL", "M_EPISOD",
	"M_OPTTTL", "M_ENDGAM", "M_MESSG", "M_DETAIL", "M_SCRNSZ",
	"M_MSENS", "M_SVOL", "M_SFXVOL", "M_MUSVOL",
	"M_GDHIGH", "M_GDLOW", "M_MSGOFF", "M_MSGON",
	"M_THERML", "M_THERMM", "M_THERMR", "M_THERMO",
	"M_SKULL1", "M_SKULL2",
	"HELP1", "HELP2", "CREDIT",
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

pidx(name: string): int
{
	for (i := 0; i < len patchNames; i++)
		if (patchNames[i] == name)
			return i;
	return -1;
}

pd(name: string): array of byte
{
	i := pidx(name);
	if (i < 0)
		return nil;
	return patches[i].d;
}

additem(status: int, name: string, act: int, key: int)
{
	items[icursor] = Item(status, pidx(name), act, key);
	icursor++;
}

init(w: ref Wad->File, g: Game, snd: Sound, h: Hu): string
{
	sys = load Sys Sys->PATH;
	wad = load Wad Wad->PATH;
	if (wad == nil)
		return "can't load Wad module";
	rend = load Rend Rend->PATH;
	if (rend == nil)
		rend = load Rend "rend.dis";
	if (rend == nil)
		return "can't load Rend module";
	game = g;
	sound = snd;
	hu = h;

	patches = array[len patchNames] of Patch;
	for (i := 0; i < len patchNames; i++) {
		patches[i].d = getpatch(w, patchNames[i]);
		if (patches[i].d == nil)
			return "missing menu lump " + patchNames[i];
	}

	# message font: same STCFN range as HU (menu messages use M_WriteText)
	font = array[63] of Patch;
	for (j := 0; j < 63; j++) {
		font[j].d = getpatch(w, sys->sprint("STCFN%.3d", int '!' + j));
		if (font[j].d == nil)
			return "missing menu font patch";
	}
	fonth = rend->rpatchheight(font[0].d);

	# item tables, transcribed from m_menu.c.  Shareware has three
	# episodes (M_EPI4 is retail/ultimate only, M_Init drops it);
	# Load/Save are milestone 26 and omitted from this table.
	items = array[26] of Item;
	icursor = 0;
	# main
	additem(1, "M_NGAME", ActNewGame, 'n');
	additem(1, "M_OPTION", ActOptions, 'o');
	additem(1, "M_RDTHIS", ActReadThis, 'r');
	additem(1, "M_QUITG", ActQuit, 'q');
	# episode
	additem(1, "M_EPI1", ActEpisode, 'k');
	additem(1, "M_EPI2", ActEpisode, 't');
	additem(1, "M_EPI3", ActEpisode, 'i');
	# skill
	additem(1, "M_JKILL", ActSkill, 'i');
	additem(1, "M_ROUGH", ActSkill, 'h');
	additem(1, "M_HURT", ActSkill, 'h');
	additem(1, "M_ULTRA", ActSkill, 'u');
	additem(1, "M_NMARE", ActSkill, 'n');
	# options
	additem(1, "M_ENDGAM", ActEndGame, 'e');
	additem(1, "M_MESSG", ActMessages, 'm');
	additem(1, "M_DETAIL", ActDetail, 'g');
	additem(2, "M_SCRNSZ", ActSize, 's');
	additem(-1, "", ActNone, 0);
	additem(2, "M_MSENS", ActSens, 'm');
	additem(-1, "", ActNone, 0);
	additem(1, "M_SVOL", ActSound, 's');
	# read this (empty items: the skull is the only marker)
	additem(1, "", ActReadThis2, 0);
	additem(1, "", ActFinishRead, 0);
	# sound
	additem(2, "M_SFXVOL", ActSfxVol, 's');
	additem(-1, "", ActNone, 0);
	additem(2, "M_MUSVOL", ActMusVol, 'm');
	additem(-1, "", ActNone, 0);

	menus = array[NMENUS] of MenuDef;
	menus[MMain] = MenuDef(0, 4, -1, 97, 64, 0);
	menus[MEpisode] = MenuDef(4, 3, MMain, 48, 63, 0);
	menus[MSkill] = MenuDef(7, 5, MEpisode, 48, 63, 2);
	menus[MOptions] = MenuDef(12, 8, MMain, 60, 37, 0);
	menus[MRead1] = MenuDef(20, 1, MMain, 280, 185, 0);
	menus[MRead2] = MenuDef(21, 1, MRead1, 330, 175, 0);
	menus[MSound] = MenuDef(22, 4, MOptions, 80, 64, 0);

	menuactive = 0;
	current = MMain;
	itemOn = 0;
	skullAnimCounter = 10;
	whichSkull = 0;
	gametic = 0;
	usergame = 0;
	messageToPrint = 0;
	messageLastActive = 0;
	showMessages = 1;
	detailLevel = 0;
	screenblocks = 10;
	screenSize = screenblocks - 3;
	mouseSensitivity = 5;
	sfxVolume = 8;
	musicVolume = 8;
	epi = 0;
	actKind = None;
	actEpi = 0;
	actSkill = 0;
	hu->setmessages(showMessages);
	sound->setvolume(sfxVolume * 8);
	return nil;
}

setaction(kind, e, sk: int)
{
	actKind = kind;
	actEpi = e;
	actSkill = sk;
}

viewsize(): (int, int)
{
	return (screenblocks, detailLevel);
}

take(): (int, int, int)
{
	k := actKind;
	e := actEpi;
	s := actSkill;
	actKind = None;
	return (k, e, s);
}

setusergame(on: int)
{
	usergame = on;
}

start()
{
	# vanilla M_StartControlPanel: intro might call repeatedly
	if (menuactive != 0)
		return;
	menuactive = 1;
	current = MMain;
	itemOn = menus[MMain].laston;
}

active(): int
{
	return menuactive;
}

clear()
{
	menuactive = 0;
}

# vanilla M_StartMessage
startmessage(s: string, act, needsinput: int)
{
	messageLastActive = menuactive;
	messageToPrint = 1;
	messageString = s;
	messageAct = act;
	messageNeedsInput = needsinput;
	menuactive = 1;
}

quitstring(): string
{
	return endmsgs[gametic % len endmsgs] + "\n\n" + DOSY;
}

# message routines that only need the response key
messageact(act, key: int)
{
	case act {
	ActVerifyNightmare =>
		if (key == Y) {
			setaction(NewGame, epi + 1, 4);
			clear();
		}
	ActEndGameConfirm =>
		if (key == Y) {
			setaction(EndGame, 0, 0);
			clear();
		}
	ActQuitConfirm =>
		if (key == Y) {
			setaction(Quit, 0, 0);
			clear();
		}
	ActQuit =>
		startmessage(quitstring(), ActQuitConfirm, 1);
	}
}

doact(act, choice: int)
{
	case act {
	ActNewGame =>
		current = MEpisode;
		itemOn = menus[MEpisode].laston;
	ActEpisode =>
		if (choice != 0) {
			# shareware: episode 2/3 advertises the full game
			startmessage(SWSTRING, ActNone, 0);
			current = MRead1;
			itemOn = menus[MRead1].laston;
			return;
		} else {
			epi = choice;
			current = MSkill;
			itemOn = menus[MSkill].laston;
		}
	ActSkill =>
		if (choice == 4) {
			startmessage(NIGHTMARE, ActVerifyNightmare, 1);
			return;
		} else {
			setaction(NewGame, epi + 1, choice);
			clear();
		}
	ActOptions =>
		current = MOptions;
		itemOn = menus[MOptions].laston;
	ActEndGame =>
		if (usergame == 0) {
			sound->startsound(0, 0, Sound->SFX_OOF);
			return;
		}
		startmessage(ENDGAME, ActEndGameConfirm, 1);
	ActReadThis =>
		current = MRead1;
		itemOn = menus[MRead1].laston;
	ActReadThis2 =>
		current = MRead2;
		itemOn = menus[MRead2].laston;
	ActFinishRead =>
		current = MMain;
		itemOn = menus[MMain].laston;
	ActQuit =>
		startmessage(quitstring(), ActQuitConfirm, 1);
	ActMessages =>
		showMessages = 1 - showMessages;
		hu->setmessages(showMessages);
		p := game->consoleplayer();
		if (p != nil) {
			if (showMessages != 0)
				p.message = MSGON;
			else
				p.message = MSGOFF;
			hu->forcemsg();
		}
	ActDetail =>
		detailLevel = 1 - detailLevel;
		p := game->consoleplayer();
		if (p != nil) {
			if (detailLevel != 0)
				p.message = DETAILLO;
			else
				p.message = DETAILHI;
		}
	ActSize =>
		if (choice == 0) {
			if (screenSize > 0) {
				screenblocks--;
				screenSize--;
			}
		} else if (screenSize < 8) {
			screenblocks++;
			screenSize++;
		}
	ActSens =>
		if (choice == 0) {
			if (mouseSensitivity > 0)
				mouseSensitivity--;
		} else if (mouseSensitivity < 9)
			mouseSensitivity++;
	ActSfxVol =>
		if (choice == 0) {
			if (sfxVolume > 0)
				sfxVolume--;
		} else if (sfxVolume < 15)
			sfxVolume++;
		sound->setvolume(sfxVolume * 8);
	ActMusVol =>
		if (choice == 0) {
			if (musicVolume > 0)
				musicVolume--;
		} else if (musicVolume < 15)
			musicVolume++;
	ActSound =>
		current = MSound;
		itemOn = menus[MSound].laston;
	}
}

# vanilla M_Responder, key events only (no joystick/mouse yet)
keydown(k: int): int
{
	# window close: first request opens the quit message, a second
	# one confirms it (vanilla ev_quit handling)
	if (k == QuitReq) {
		if (menuactive != 0 && messageToPrint != 0 &&
		    messageAct == ActQuitConfirm) {
			messageToPrint = 0;
			messageact(ActQuitConfirm, Y);
			menuactive = 0;
			sound->startsound(0, 0, Sound->SFX_SWTCHX);
		} else
			doact(ActQuit, 0);
		return 1;
	}

	if (messageToPrint != 0) {
		if (messageNeedsInput != 0 &&
		    k != Space && k != Esc && k != Y && k != N)
			return 0;
		menuactive = messageLastActive;
		messageToPrint = 0;
		if (messageAct != ActNone)
			messageact(messageAct, k);
		menuactive = 0;
		sound->startsound(0, 0, Sound->SFX_SWTCHX);
		return 1;
	}

	if (menuactive == 0) {
		if (k == Esc) {
			start();
			sound->startsound(0, 0, Sound->SFX_SWTCHN);
			return 1;
		}
		return 0;
	}

	d := menus[current];
	n := d.n;

	if (k == KD) {
		do {
			if (itemOn + 1 > n - 1)
				itemOn = 0;
			else
				itemOn++;
			sound->startsound(0, 0, Sound->SFX_PSTOP);
		} while (items[d.first + itemOn].status == -1);
		return 1;
	}
	if (k == KU) {
		do {
			if (itemOn == 0)
				itemOn = n - 1;
			else
				itemOn--;
			sound->startsound(0, 0, Sound->SFX_PSTOP);
		} while (items[d.first + itemOn].status == -1);
		return 1;
	}
	if (k == KL) {
		it := items[d.first + itemOn];
		if (it.act != ActNone && it.status == 2) {
			sound->startsound(0, 0, Sound->SFX_STNMOV);
			doact(it.act, 0);
		}
		return 1;
	}
	if (k == KR) {
		it := items[d.first + itemOn];
		if (it.act != ActNone && it.status == 2) {
			sound->startsound(0, 0, Sound->SFX_STNMOV);
			doact(it.act, 1);
		}
		return 1;
	}
	if (k == Enter) {
		it := items[d.first + itemOn];
		if (it.status > 0) {
			menus[current].laston = itemOn;
			if (it.status == 2) {
				doact(it.act, 1);
				sound->startsound(0, 0, Sound->SFX_STNMOV);
			} else {
				doact(it.act, itemOn);
				sound->startsound(0, 0, Sound->SFX_PISTOL);
			}
		}
		return 1;
	}
	if (k == Esc) {
		menus[current].laston = itemOn;
		clear();
		sound->startsound(0, 0, Sound->SFX_SWTCHX);
		return 1;
	}
	if (k == Back) {
		menus[current].laston = itemOn;
		if (d.prev >= 0) {
			current = d.prev;
			itemOn = menus[current].laston;
			sound->startsound(0, 0, Sound->SFX_SWTCHN);
		}
		return 1;
	}

	# keyboard shortcut (vanilla: next items first, then wrap)
	ch := 0;
	if (k >= 32 && k < 127)
		ch = k;
	if (ch != 0) {
		for (i := itemOn + 1; i < n; i++)
			if (items[d.first + i].key == ch) {
				itemOn = i;
				sound->startsound(0, 0, Sound->SFX_PSTOP);
				return 1;
			}
		for (j := 0; j <= itemOn; j++)
			if (items[d.first + j].key == ch) {
				itemOn = j;
				sound->startsound(0, 0, Sound->SFX_PSTOP);
				return 1;
			}
	}
	return 0;
}

ticker()
{
	gametic++;
	if (--skullAnimCounter <= 0) {
		whichSkull = 1 - whichSkull;
		skullAnimCounter = 8;
	}
}

# --- drawing ---------------------------------------------------------

drawpatch(r: ref Renderer, x, y: int, pd: array of byte)
{
	if (pd != nil)
		rend->rdrawpatch(r, x, y, pd);
}

thermo(r: ref Renderer, x, y, width, dot: int)
{
	xx := x;
	drawpatch(r, xx, y, pd("M_THERML"));
	xx += 8;
	for (i := 0; i < width; i++) {
		drawpatch(r, xx, y, pd("M_THERMM"));
		xx += 8;
	}
	drawpatch(r, xx, y, pd("M_THERMR"));
	drawpatch(r, (x + 8) + dot*8, y, pd("M_THERMO"));
}

upper(c: int): int
{
	if (c >= 'a' && c <= 'z')
		return c - ('a' - 'A');
	return c;
}

# vanilla M_StringWidth
strwidth(s: string): int
{
	w := 0;
	for (i := 0; i < len s; i++) {
		c := upper(int s[i]) - int '!';
		if (c < 0 || c >= len font)
			w += 4;
		else
			w += rend->rpatchwidth(font[c].d);
	}
	return w;
}

# vanilla M_StringHeight (font height per line)
strheight(s: string): int
{
	h := fonth;
	for (i := 0; i < len s; i++)
		if (s[i] == '\n')
			h += fonth;
	return h;
}

# vanilla M_WriteText for one line (no '\n')
writeline(r: ref Renderer, x0, y: int, s: string)
{
	x := x0;
	for (i := 0; i < len s; i++) {
		c := upper(int s[i]) - int '!';
		if (c < 0 || c >= len font) {
			x += 4;
			continue;
		}
		pd := font[c].d;
		w := rend->rpatchwidth(pd);
		if (x + w > r.w)
			break;
		rend->rdrawpatch(r, x, y, pd);
		x += w;
	}
}

drawmessage(r: ref Renderer)
{
	start := 0;
	y := 100 - strheight(messageString)/2;
	while (start < len messageString) {
		i := start;
		while (i < len messageString && messageString[i] != '\n')
			i++;
		line := messageString[start:i];
		writeline(r, 160 - strwidth(line)/2, y, line);
		y += fonth;
		if (i < len messageString && messageString[i] == '\n')
			i++;
		start = i;
	}
}

drawmenu(r: ref Renderer)
{
	case current {
	MMain =>
		drawpatch(r, 94, 2, pd("M_DOOM"));
	MEpisode =>
		drawpatch(r, 54, 38, pd("M_EPISOD"));
	MSkill =>
		drawpatch(r, 96, 14, pd("M_NEWG"));
		drawpatch(r, 54, 38, pd("M_SKILL"));
	MOptions =>
		drawpatch(r, 108, 15, pd("M_OPTTTL"));
		d := menus[MOptions];
		if (detailLevel != 0)
			drawpatch(r, d.x + 175, d.y + LINEHEIGHT*2,
				pd("M_GDLOW"));
		else
			drawpatch(r, d.x + 175, d.y + LINEHEIGHT*2,
				pd("M_GDHIGH"));
		if (showMessages != 0)
			drawpatch(r, d.x + 120, d.y + LINEHEIGHT*1,
				pd("M_MSGON"));
		else
			drawpatch(r, d.x + 120, d.y + LINEHEIGHT*1,
				pd("M_MSGOFF"));
		thermo(r, d.x, d.y + LINEHEIGHT*(5+1), 10, mouseSensitivity);
		thermo(r, d.x, d.y + LINEHEIGHT*(3+1), 9, screenSize);
	MRead1 =>
		drawpatch(r, 0, 0, pd("HELP2"));
	MRead2 =>
		drawpatch(r, 0, 0, pd("HELP1"));
	MSound =>
		drawpatch(r, 60, 38, pd("M_SVOL"));
		d := menus[MSound];
		thermo(r, d.x, d.y + LINEHEIGHT*(0+1), 16, sfxVolume);
		thermo(r, d.x, d.y + LINEHEIGHT*(2+1), 16, musicVolume);
	}
}

drawer(r: ref Renderer)
{
	if (messageToPrint != 0) {
		drawmessage(r);
		return;
	}
	if (menuactive == 0)
		return;
	d := menus[current];
	drawmenu(r);
	for (i := 0; i < d.n; i++) {
		it := items[d.first + i];
		if (it.nameidx >= 0)
			drawpatch(r, d.x, d.y + i*LINEHEIGHT,
				patches[it.nameidx].d);
	}
	skull := "M_SKULL1";
	if (whichSkull != 0)
		skull = "M_SKULL2";
	drawpatch(r, d.x + SKULLXOFF, d.y - 5 + itemOn*LINEHEIGHT,
		pd(skull));
}
