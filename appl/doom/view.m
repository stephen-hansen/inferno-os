# First-person world view renderer: walks the BSP tree front-to-
# back from the camera, projects segs into screen columns, draws
# textured walls with vanilla R_DrawColumn, and fills floor/ceiling
# planes with vanilla R_DrawSpan.  Occlusion uses the classic
# solid[] array (top/bottom clip per screen column).
#
# Reference: doomgeneric r_bsp.c r_segs.c r_plane.c r_main.c (GPL-2).

View: module {

	PATH:	con "/dis/doom/view.dis";

	# allocate solid[] clip arrays for width w; call once after
	# Renderer.init.  w,h are the render resolution.
	init:	fn(w: ref Rend->Renderer, l: ref Map->Level,
				width, height: int): string;

	# render one frame from the given camera state (all 16.16
	# fixed point; viewangle is BAM).  Clears fb8, walks BSP,
	# draws walls.  Caller does convert() + present().
	render:	fn(viewx, viewy, viewz, viewangle, viewcos, viewsin: int);

	# debug stats from the last render
	nsegs, ncolumns, nspans:	int;
};
