# Video output for Doom.
#
# Two modes:
#  - open(): full-screen direct blit onto the emu screen image
#    (Display.image), used when doom.dis is started standalone.
#  - openwm(): a wm-managed Tk toplevel window ("Doom" in the Games
#    menu) with a Resize titlebar button; the panel is resizable.
#
# The game renders its 320x200 indexed frame into fb8; Rend.convert
# produces the source XRGB32 image in Context.fb (sw x sh).  Both
# output modes scale that image to the destination (screen or panel)
# with nearest-neighbour sampling, preserving the 320:200 aspect and
# centring the result (black letterbox).  When the destination is
# exactly 320x200 the blit is direct (no scaling).  In wm mode the
# panel size is polled once per present, so dragging the window
# resize button scales the game live.
#
# fb is XRGB32 (4 bytes/pixel, x8r8g8b8: little-endian byte order
# blue, green, red, x — matching the screen's native depth; emu's
# win-x11a forces 32bpp).
#
# NOTE: like the other .m files here, this module does not #include
# draw.m/tk.m itself — the including command must include them first
# (doom.b does: draw.m, tk.m, ... video.m).

Video: module {

	PATH:	con "/dis/doom/video.dis";

	Context: adt {
		display:	ref Draw->Display;
		buf:		ref Draw->Image;	# wm window buffer (nil = full screen)
		tkwin:		ref Tk->Toplevel;	# wm toplevel (nil = full screen)

		fb:	array of byte;	# sw*sh*4 game frame, BGRX order
		sw, sh:	int;		# source (game) dimensions
		winw, winh:	int;	# destination image dimensions

		x0, y0:	int;		# top-left of the scaled game rect
		dw, dh:	int;		# scaled game dimensions
		dst:	array of byte;	# dw*dh*4 scaled output
		xmap, ymap:	array of int;	# nearest-neighbour byte offsets

		# blit fb to the window (or the top-left of the screen),
		# scaling to the destination and polling for wm resizes
		present:	fn(c: self ref Context);

		# re-layout for a new destination size; wm mode also
		# allocates the new panel image and attaches it
		resize:	fn(c: self ref Context, w, h: int);

		# paint the area black
		close:	fn(c: self ref Context);
	};

	# open a full-screen display, scaled to fit the emu screen;
	# width/height are the source (game) dimensions
	open:	fn(width, height: int): (ref Context, string);

	# open a wm-managed window showing the sw x sh game frame in a
	# window of width x height pixels (the frame is scaled into it);
	# returns (ctx, keyevents, nil) or (nil, nil, error).  keyevents
	# delivers "k <keysym>" (press), "r <keysym>" (release) and
	# "quit" (window deleted) strings.  kbd/ptr/wmctl pumping into Tk
	# happens in a background pump.
	openwm:	fn(ctxt: ref Draw->Context, sw, sh, width, height: int,
			title: string): (ref Context, chan of string, string);
};
