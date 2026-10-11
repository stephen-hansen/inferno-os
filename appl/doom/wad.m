# WAD file interface: the container format for Doom game data.
# An IWAD contains the complete game; a PWAD holds overrides.
# All multi-byte integers in the file are little-endian.

Wad: module {

	PATH:	con "/dis/doom/wad.dis";

	Lump: adt {
		name:	string;		# up to 8 chars, NUL padded, stored uppercase
		filepos:	int;		# offset of lump data in the file
		size:	int;		# bytes of lump data
	};

	File: adt {
		fd:	ref Sys->FD;
		wtype:	string;		# "IWAD" or "PWAD"
		numlumps:	int;
		infotableofs:	int;
		lumps:	array of Lump;

		# close the underlying file
		close:	fn(w: self ref File);

		# read the whole of lump i (suitable for small/medium lumps;
		# the engine loads map geometry one lump at a time)
		read:	fn(w: self ref File, i: int): (array of byte, string);

		# find a lump by name (case sensitive, stored uppercase);
		# returns index or -1
		find:	fn(w: self ref File, name: string): int;
	};

	# open a WAD file; returns (wad, nil) or (nil, error)
	open:	fn(path: string): (ref File, string);

};
