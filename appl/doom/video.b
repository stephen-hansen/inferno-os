implement Video;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;
include "tk.m";
	tk: Tk;
include "video.m";

open(width, height: int): (ref Context, string)
{
	if (sys == nil)
		sys = load Sys Sys->PATH;
	if (draw == nil)
		draw = load Draw Draw->PATH;
	if (tk == nil)
		tk = load Tk Tk->PATH;

	display := Display.allocate(nil);
	if (display == nil)
		return (nil, sys->sprint("can't allocate Display: %r"));

	t := tk->toplevel(display, "");
	if (t == nil)
		return (nil, sys->sprint("can't create toplevel: %r"));

	tk->cmd(t, "canvas .c -width " + string width + " -height " + string height);
	tk->cmd(t, "pack .c");
	tk->cmd(t, "update");

	img := display.newimage(Rect((0, 0), (width, height)), Draw->RGB24, 0, Draw->Black);
	if (img == nil)
		return (nil, sys->sprint("can't create framebuffer image: %r"));

	tk->putimage(t, ".c", img, nil);
	tk->cmd(t, ".c dirty");
	tk->cmd(t, "update");

	fb := array[width * height * 3] of byte;

	return (ref Context(display, t, img, fb, width, height), nil);
}

Context.present(c: self ref Context)
{
	c.img.writepixels(c.img.r, c.fb);
	tk->cmd(c.t, ".c dirty");
	tk->cmd(c.t, "update");
}

Context.close(c: self ref Context)
{
	tk->cmd(c.t, ". destroy");
}
