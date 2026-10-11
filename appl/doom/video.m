# Video output for Doom: blit an RGB framebuffer straight onto the
# emu screen image (Display.image), the same direct-draw path wish.b
# uses.  No Tk in the pixel path; input can be layered on later.
#
# fb is XRGB32 (4 bytes/pixel, x8r8g8b8: little-endian byte order
# blue, green, red, x — matching the screen's native depth; emu's
# win-x11a forces 32bpp).

Video: module {

	PATH:	con "/dis/doom/video.dis";

	Context: adt {
		display:	ref Draw->Display;
		fb:	array of byte;	# width*height*4, BGRX order
		width:	int;
		height:	int;

		# blit fb to the top-left of the screen
		present:	fn(c: self ref Context);

		# paint the screen area black
		close:	fn(c: self ref Context);
	};

	# open a display; returns (ctx, nil) or (nil, error)
	open:	fn(width, height: int): (ref Context, string);

};
