# Video output for Doom.
#
# Two modes:
#  - open(): full-screen direct blit onto the emu screen image
#    (Display.image), used when doom.dis is started standalone.
#  - openwm(): a wm-managed Tk toplevel window ("Doom" in the Games
#    menu): fixed-size buffer shown in a panel widget via putimage;
#    present() blits the fb into the buffer and marks the panel dirty.
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
		fb:	array of byte;	# width*height*4, BGRX order
		width:	int;
		height:	int;

		# blit fb to the window (or the top-left of the screen)
		present:	fn(c: self ref Context);

		# paint the area black
		close:	fn(c: self ref Context);
	};

	# open a full-screen display; returns (ctx, nil) or (nil, error)
	open:	fn(width, height: int): (ref Context, string);

	# open a wm-managed window; returns (ctx, keyevents, nil) or
	# (nil, nil, error).  keyevents delivers "k <keysym>" (press),
	# "r <keysym>" (release) and "quit" (window deleted) strings.
	# kbd/ptr/wmctl pumping into Tk happens in a background pump.
	openwm:	fn(ctxt: ref Draw->Context, width, height: int, title: string):
			(ref Context, chan of string, string);
};
