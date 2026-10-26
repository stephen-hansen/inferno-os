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

newctx(display: ref Display, buf: ref Image, tkwin: ref Toplevel,
	sw, sh, winw, winh: int): ref Context
{
	c := ref Context(display, buf, tkwin,
		array[sw * sh * 4] of byte, sw, sh, winw, winh,
		0, 0, 0, 0, nil, nil, nil);
	c.resize(winw, winh);
	return c;
}

# Largest 320:200 rectangle centred in w x h (integer arithmetic,
# nearest-neighbour sampling; the letterbox stays black).
Context.resize(c: self ref Context, w, h: int)
{
	if (w < 1)
		w = 1;
	if (h < 1)
		h = 1;
	dw := w;
	dh := w * c.sh / c.sw;
	if (dh > h) {
		dh = h;
		dw = h * c.sw / c.sh;
	}
	if (dw < 1)
		dw = 1;
	if (dh < 1)
		dh = 1;
	c.winw = w;
	c.winh = h;
	c.dw = dw;
	c.dh = dh;
	c.x0 = (w - dw) / 2;
	c.y0 = (h - dh) / 2;

	c.dst = array[dw * dh * 4] of byte;
	c.xmap = array[dw] of int;
	for (x := 0; x < dw; x++)
		c.xmap[x] = (x * c.sw / dw) * 4;
	c.ymap = array[dh] of int;
	for (y := 0; y < dh; y++)
		c.ymap[y] = (y * c.sh / dh) * c.sw * 4;

	# wm mode: give the panel a fresh window-sized image (black
	# fills the letterbox); the old image is released by GC
	if (c.tkwin != nil) {
		img := c.display.newimage(Rect((0, 0), (w, h)),
			c.display.image.chans, 0, Draw->Black);
		if (img == nil) {
			sys->print("video: can't allocate %dx%d window image: %r\n",
				w, h);
			return;
		}
		c.buf = img;
		tk->putimage(c.tkwin, ".p", img, nil);
		tk->cmd(c.tkwin, ".p dirty; update");
	}
}

open(width, height: int): (ref Context, string)
{
	if (sys == nil)
		sys = load Sys Sys->PATH;
	if (draw == nil)
		draw = load Draw Draw->PATH;

	display := Display.allocate(nil);
	if (display == nil || display.image == nil)
		return (nil, sys->sprint("can't allocate Display: %r"));

	# full-screen mode scales to the whole emu screen
	w := display.image.r.dx();
	h := display.image.r.dy();
	if (w < 1 || h < 1) {
		w = width;
		h = height;
	}
	c := newctx(display, nil, nil, width, height, w, h);
	# clear the screen once so the letterbox is black
	display.image.draw(display.image.r, display.black, nil, (0, 0));
	return (c, nil);
}

openwm(ctxt: ref Draw->Context, sw, sh, width, height: int, title: string):
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

	(win, menubut) := tkclient->toplevel(ctxt, "", title,
		Tkclient->Resize);
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

	return (newctx(ctxt.display, buf, win, sw, sh, pw, ph), keys, nil);
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

# nearest-neighbour upscale/downscale of the game frame
scalefb(c: ref Context)
{
	src := c.fb;
	dst := c.dst;
	xm := c.xmap;
	ym := c.ymap;
	dw := c.dw;
	dh := c.dh;
	for (y := 0; y < dh; y++) {
		so := ym[y];
		doff := y * dw * 4;
		for (x := 0; x < dw; x++) {
			si := so + xm[x];
			di := doff + x * 4;
			dst[di] = src[si];
			dst[di+1] = src[si+1];
			dst[di+2] = src[si+2];
			dst[di+3] = src[si+3];
		}
	}
}

# poll the panel size; the wm's resize button reshapes the window and
# Tk repacks the panel at its actual size
checkwmresize(c: ref Context)
{
	pw := int tk->cmd(c.tkwin, ".p cget -actwidth");
	ph := int tk->cmd(c.tkwin, ".p cget -actheight");
	if (pw > 0 && ph > 0 && (pw != c.winw || ph != c.winh))
		c.resize(pw, ph);
}

Context.present(c: self ref Context)
{
	if (c.tkwin != nil)
		checkwmresize(c);
	img := c.buf;
	if (img == nil)
		img = c.display.image;
	if (img == nil)
		return;
	o := img.r.min;
	if (c.dw == c.sw && c.dh == c.sh && c.x0 == 0 && c.y0 == 0) {
		n := img.writepixels(Rect(o, (o.x + c.sw, o.y + c.sh)), c.fb);
		if (n < 0)
			sys->print("present: writepixels failed: %r\n");
	} else {
		scalefb(c);
		n := img.writepixels(
			Rect((o.x + c.x0, o.y + c.y0),
				(o.x + c.x0 + c.dw, o.y + c.y0 + c.dh)), c.dst);
		if (n < 0)
			sys->print("present: writepixels failed: %r\n");
	}
	if (c.tkwin != nil)
		tk->cmd(c.tkwin, sys->sprint(".p dirty %d %d %d %d; update",
			c.x0, c.y0, c.x0 + c.dw, c.y0 + c.dh));
}

Context.close(c: self ref Context)
{
	img := c.buf;
	if (img == nil)
		img = c.display.image;
	if (img == nil)
		return;
	img.draw(img.r, c.display.black, nil, img.r.min);
	if (c.tkwin != nil)
		tk->cmd(c.tkwin, ".p dirty; update");
}
