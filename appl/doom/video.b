implement Video;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "tk.m";
	Toplevel: import tk;
include "tkclient.m";
	tkclient: Tkclient;
include "video.m";

tk: Tk;

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

	return (ref Context(display, nil, nil, fb, width, height), nil);
}

openwm(ctxt: ref Draw->Context, width, height: int, title: string):
	(ref Context, chan of string, string)
{
	if (sys == nil)
		sys = load Sys Sys->PATH;
	if (draw == nil)
		draw = load Draw Draw->PATH;
	if (tkclient == nil) {
		tkclient = load Tkclient Tkclient->PATH;
		if (tkclient == nil)
			return (nil, nil, sys->sprint("can't load Tkclient: %r"));
		tkclient->init();
	}
	tk = load Tk Tk->PATH;
	if (tk == nil)
		return (nil, nil, sys->sprint("can't load Tk: %r"));

	(win, menubut) := tkclient->toplevel(ctxt, "", title, 0);
	if (win == nil)
		return (nil, nil, sys->sprint("openwm: can't create toplevel: %r"));
	if (ctxt.display == nil)
		return (nil, nil, "openwm: wm context has no display");

	# c4.b pattern: size the panel explicitly, then create our own
	# image for it (getimage fails because the panel has no image
	# until putimage attaches one).
	tk->cmd(win, "panel .p -width " + string width
		+ " -height " + string height);
	tk->cmd(win, "pack .p -side top -fill both -expand 1");
	tk->cmd(win, "pack propagate . 0");
	tk->cmd(win, "update");
	tkclient->startinput(win, "kbd"::"ptr"::nil);
	tkclient->onscreen(win, nil);

	# read the panel's actual laid-out size (c4.b reads cget -actwidth)
	pw := int tk->cmd(win, ".p cget -actwidth");
	ph := int tk->cmd(win, ".p cget -actheight");
	if (pw <= 0 || ph <= 0)
		return (nil, nil, sys->sprint("openwm: bad panel size %dx%d", pw, ph));

	buf := ctxt.display.newimage(Rect((0, 0), (pw, ph)),
		ctxt.display.image.chans, 0, Draw->Black);
	if (buf == nil)
		return (nil, nil, sys->sprint("openwm: can't alloc %dx%d image: %r",
			pw, ph));
	tk->putimage(win, ".p", buf, nil);
	tk->cmd(win, ".p dirty; update");

	# unbuffered chan, but keybuf makes it non-blocking for wmpump so a
	# busy play loop (tic+render ~20ms) can't stall the Tk event pump.
	rawkeys := chan of string;
	keys := chan of string;
	tk->namechan(win, rawkeys, "user");
	tk->cmd(win, "bind . <ButtonRelease-1> {focus .}");
	tk->cmd(win, "bind .Wm_t <ButtonRelease-1> +{focus .}");
	tk->cmd(win, "focus .");

	spawn wmpump(tk, win, menubut, rawkeys);
	spawn keybuf(rawkeys, keys);

	fb := array[pw * ph * 4] of byte;
	return (ref Context(ctxt.display, buf, win, fb, pw, ph), keys, nil);
}

# pump wm channels into Tk; forward window deletion as "quit" on keys
wmpump(t: Tk, win: ref Toplevel, menubut: chan of string, keys: chan of string)
{
	for (;;) alt {
	s := <-win.ctxt.kbd =>
			keys <-= "k " + string s;
	p := <-win.ctxt.ptr =>
		t->pointer(win, *p);
	s := <-win.ctxt.ctl or
	s = <-win.wreq or
	s = <-menubut =>
		if (s == "del" || s == "exit")
			keys <-= "quit";
		tkclient->wmctl(win, s);
	}
}

# drain raw key events so wmpump never blocks on the play loop.
# coalesce: a held key's repeat presses collapse into one entry; the
# play loop polls keystate every tic, so only the last press/release
# of a burst matters.
keybuf(src, dst: chan of string)
{
	pending: string;
	have := 0;
	for (;;) {
		if (have) {
			alt {
			dst <-= pending =>
				have = 0;
			s := <-src =>
				pending = s;	# latest wins
				have = 1;
			}
		} else {
			pending = <-src;
			have = 1;
		}
	}
}

Context.present(c: self ref Context)
{
	img := c.buf;
	if (img == nil)
		img = c.display.image;
	r := Rect((0, 0), (c.width, c.height));
	n := img.writepixels(r, c.fb);
	if (n < 0)
		sys->print("present: writepixels failed: %r\n");
	if (c.tkwin != nil)
		tk->cmd(c.tkwin, sys->sprint(".p dirty %d %d %d %d; update",
			0, 0, c.width, c.height));
}

Context.close(c: self ref Context)
{
	blank := array[c.width * c.height * 4] of byte;
	img := c.buf;
	if (img == nil)
		img = c.display.image;
	o := img.r.min;
	r := Rect((o.x, o.y), (o.x + c.width, o.y + c.height));
	img.writepixels(r, blank);
	if (c.tkwin != nil)
		tk->cmd(c.tkwin, ".p dirty; update");
}
