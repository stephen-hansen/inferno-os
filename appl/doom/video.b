implement Video;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;
include "video.m";

open(width, height: int): (ref Context, string)
{
	if (sys == nil)
		sys = load Sys Sys->PATH;
	if (draw == nil)
		draw = load Draw Draw->PATH;

	display := Display.allocate(nil);
	if (display == nil)
		return (nil, sys->sprint("can't allocate Display: %r"));

	fb := array[width * height * 4] of byte;

	return (ref Context(display, fb, width, height), nil);
}

Context.present(c: self ref Context)
{
	o := c.display.image.r.min;
	r := Rect((o.x, o.y), (o.x + c.width, o.y + c.height));
	n := c.display.image.writepixels(r, c.fb);
	if (n < 0)
		sys->print("present: writepixels failed: %r\n");
}

Context.close(c: self ref Context)
{
	o := c.display.image.r.min;
	r := Rect((o.x, o.y), (o.x + c.width, o.y + c.height));
	c.display.image.writepixels(r, array[c.width * c.height * 4] of byte);
}
