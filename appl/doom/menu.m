# Menu system (milestone 21): m_menu.c, shareware Doom 1.9 path.
# Menus are data (item tables + descriptors); item routines are action
# ids dispatched by the module.  Drawing is direct into the 320x200
# framebuffer over whatever is already there (world view or title
# page), with the M_* patches, skull cursor, thermometers and the HU
# font for messages.  Load/Save menus are deferred to milestone 26
# (they are not part of this milestone's scope); quicksave F-keys and
# gamma are likewise later.
#
# The host (doom.b) polls take() for NewGame/EndGame/Quit actions and
# drives the title state; this module only owns the menu state
# machine.
# Reference: doomgeneric m_menu.c (GPL-2).

Menu: module {

	PATH:	con "/dis/doom/menu.dis";

	# pending action kinds from take()
	None, NewGame, EndGame, Quit: con iota;

	# load menu patches and the HUD font; g is doom.b's live Game,
	# snd the shared SFX instance, hu the HUD (forced messages)
	init:	fn(w: ref Wad->File, g: Game, snd: Sound, hu: Hu): string;

	# vanilla M_StartControlPanel / M_ClearMenus
	start:	fn();
	active:	fn(): int;
	clear:	fn();

	# host game-state flag (End Game only works in a game)
	setusergame:	fn(on: int);

	# edge-triggered key event, doom.b encoding (ASCII/Esc/arrows).
	# Returns 1 if the menu ate it (vanilla M_Responder).
	# QuitReq is the window-close request (vanilla ev_quit).
	keydown:	fn(k: int): int;

	# vanilla M_Ticker: skull animation; also advances gametic
	ticker:	fn();

	# draw over the current frame
	drawer:	fn(r: ref Rend->Renderer);

	# host polls and clears the pending action: (kind, episode, skill)
	take:	fn(): (int, int, int);

	QuitReq:	con 16rF000;
	Enter:	con 13;
	Back:	con 127;
};
