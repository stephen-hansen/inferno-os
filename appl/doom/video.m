# Video output for Doom: a Tk window with a raw framebuffer
# blitted via Draw->Image.writepixels.
#
# The framebuffer fb is RGB24 (3 bytes/pixel, blue-green-red byte
# order per pixel as required by writepixels on an RGB24 image;
# see image(6): "r8g8b8 pixels have byte ordering blue, green,
# and red").

Video: module {

	PATH:	con "/dis/doom/video.dis";

	Context: adt {
		display:	ref Draw->Display;
		t:	ref Tk->Toplevel;
		img:	ref Draw->Image;
		fb:	array of byte;	# width*height*3, BGR order
		width:	int;
		height:	int;

		# blit fb to the window image and process pending Tk events
		present:	fn(c: self ref Context);

		# tear down the window
		close:	fn(c: self ref Context);
	};

	# open a window; returns (ctx, nil) or (nil, error)
	open:	fn(width, height: int): (ref Context, string);

};
