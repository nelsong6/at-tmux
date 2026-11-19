/* $OpenBSD$ */

/*
 * Copyright (c) 2026 Nelson Grip
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
 * IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
 * OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <sys/types.h>

#include <stdlib.h>
#include <string.h>

#include "tmux.h"

/*
 * Unicode placeholders (kitty graphics, TMUX-215): a program transmits an
 * image as a virtual placement (a=T with U=1, c and r the cells it fills),
 * which draws nothing by itself, and then writes placeholder characters
 * wherever the image is to show: U+10EEEE, its foreground colour the image
 * ID, followed by a diacritic for the row and one for the column of the
 * image cell. The position is part of the text, so a resize, a scroll, a
 * redraw or a window switch carries it like any character, and tmux keeps no
 * list of positions to fall out of step with the grid. A placeholder cell is
 * blank to the terminal, and the image's cell is drawn over it as sixel.
 */

/* The images a screen keeps as virtual placements. */
#define MAX_VIRTUAL_IMAGE_COUNT 20

/* U+10EEEE in UTF-8. */
static const u_char placeholder_bytes[] = { 0xf4, 0x8e, 0xbb, 0xae };

/*
 * The row and column diacritics, in kitty's order: the combining characters
 * of class 230 without a decomposition, from Unicode 6.0.0
 * (kitty's gen/rowcolumn-diacritics.txt).
 */
static const uint32_t placeholder_diacritics[] = {
	0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
	0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357,
	0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
	0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484,
	0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
	0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
	0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611,
	0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657, 0x0658,
	0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
	0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
	0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733,
	0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
	0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE,
	0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817, 0x0818, 0x0819,
	0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
	0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C,
	0x082D, 0x0951, 0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86, 0x0F87,
	0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
	0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D,
	0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
	0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
	0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1,
	0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5, 0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9,
	0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
	0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1,
	0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7,
	0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
	0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA,
	0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2,
	0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
	0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D,
	0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5,
	0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED,
	0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7,
	0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23,
	0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
	0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243,
	0x1D244,
};

/* Decode one UTF-8 character; the bytes it took, or 0 if malformed. */
static u_int
placeholder_decode(const u_char *p, u_int left, uint32_t *cp)
{
	u_int	n, i;

	if (left == 0)
		return (0);
	if (p[0] < 0x80) {
		*cp = p[0];
		return (1);
	}
	if ((p[0] & 0xe0) == 0xc0) {
		n = 2;
		*cp = p[0] & 0x1f;
	} else if ((p[0] & 0xf0) == 0xe0) {
		n = 3;
		*cp = p[0] & 0x0f;
	} else if ((p[0] & 0xf8) == 0xf0) {
		n = 4;
		*cp = p[0] & 0x07;
	} else
		return (0);
	if (left < n)
		return (0);
	for (i = 1; i < n; i++) {
		if ((p[i] & 0xc0) != 0x80)
			return (0);
		*cp = (*cp << 6) | (p[i] & 0x3f);
	}
	return (n);
}

/* A diacritic's index in kitty's table, or -1. */
static int
placeholder_diacritic(uint32_t cp)
{
	u_int	i;

	for (i = 0; i < nitems(placeholder_diacritics); i++) {
		if (placeholder_diacritics[i] == cp)
			return (i);
	}
	return (-1);
}

/*
 * Whether a cell is a placeholder, and if so which image cell it shows: the
 * image ID from its foreground colour, the row and column from its first two
 * diacritics. A placeholder still missing a diacritic is one (blank to the
 * terminal) but shows nothing, so complete says whether to draw it.
 */
int
image_placeholder_cell(const struct grid_cell *gc, u_int *id, u_int *row,
    u_int *col, int *complete)
{
	const u_char	*p = gc->data.data;
	u_int		 left = gc->data.size, n;
	uint32_t	 cp;
	int		 idx[2], i;

	if (left < sizeof placeholder_bytes ||
	    memcmp(p, placeholder_bytes, sizeof placeholder_bytes) != 0)
		return (0);
	p += sizeof placeholder_bytes;
	left -= sizeof placeholder_bytes;

	if (gc->fg & COLOUR_FLAG_RGB)
		*id = gc->fg & 0xffffff;
	else if (gc->fg & COLOUR_FLAG_256)
		*id = gc->fg & 0xff;
	else
		*id = 0;

	for (i = 0; i < 2; i++) {
		idx[i] = -1;
		n = placeholder_decode(p, left, &cp);
		if (n == 0)
			break;
		idx[i] = placeholder_diacritic(cp);
		if (idx[i] < 0)
			break;
		p += n;
		left -= n;
	}
	*complete = (*id != 0 && idx[0] >= 0 && idx[1] >= 0);
	*row = idx[0] >= 0 ? (u_int)idx[0] : 0;
	*col = idx[1] >= 0 ? (u_int)idx[1] : 0;
	return (1);
}

/* The cell as the terminal gets it: a blank with the same background. */
void
image_placeholder_blank(const struct grid_cell *gc, struct grid_cell *out)
{
	memcpy(out, gc, sizeof *out);
	utf8_set(&out->data, ' ');
	out->fg = 8;
	out->us = 8;
	out->attr = 0;
	out->link = 0;
}

static void
image_virtual_free(struct image *im)
{
	struct screen	*s = im->s;

#ifdef HAVE_AT_PROTOCOL
	tty_at_drop(im);
#endif
	TAILQ_REMOVE(&s->virtual_images, im, entry);
	s->virtual_image_count--;
	sixel_free(im->data);
	free(im->pixels);
	free(im);
}

/* An at_id no other virtual image in the server has. */
u_int
image_virtual_next_at_id(void)
{
	static u_int	last;

	return (++last);
}

/* The virtual image with an ID, if the screen has one. */
struct image *
image_virtual_find(struct screen *s, u_int id)
{
	struct image	*im;

	TAILQ_FOREACH(im, &s->virtual_images, entry) {
		if (im->id == id)
			return (im);
	}
	return (NULL);
}

/*
 * Keep an image as a virtual placement, replacing one with the same ID;
 * replaced says whether one went, as its placeholders must be drawn again.
 * The pixels (w by h, bpp bytes each, filling cols by rows cells) are kept
 * for a client that speaks at-protocol. Storing past the limit frees the
 * oldest.
 */
struct image *
image_virtual_place(struct screen *s, struct sixel_image *si, u_int id,
    const u_char *pixels, u_int w, u_int h, u_int bpp, u_int cols, u_int rows,
    int *replaced)
{
	struct image	*im;
	size_t		 n;

	*replaced = 0;
	if ((im = image_virtual_find(s, id)) != NULL) {
		image_virtual_free(im);
		*replaced = 1;
	}

	im = xcalloc(1, sizeof *im);
	im->s = s;
	im->data = si;
	im->id = id;
	im->at_id = image_virtual_next_at_id();
	sixel_size_in_cells(si, &im->sx, &im->sy);
	if (pixels != NULL) {
		n = (size_t)w * h * bpp;
		im->pixels = xmalloc(n);
		memcpy(im->pixels, pixels, n);
		im->pwidth = w;
		im->pheight = h;
		im->pbpp = bpp;
		im->pcols = cols;
		im->prows = rows;
	}
	log_debug("%s: id=%u (%ux%u cells)", __func__, id, im->sx, im->sy);

	TAILQ_INSERT_TAIL(&s->virtual_images, im, entry);
	if (++s->virtual_image_count > MAX_VIRTUAL_IMAGE_COUNT)
		image_virtual_free(TAILQ_FIRST(&s->virtual_images));
	return (im);
}

/* Delete the virtual image with an ID, or all of them; whether any went. */
int
image_virtual_delete(struct screen *s, int all, u_int id)
{
	struct image	*im, *im1;
	int		 redraw = 0;

	TAILQ_FOREACH_SAFE(im, &s->virtual_images, entry, im1) {
		if (all || im->id == id) {
			image_virtual_free(im);
			redraw = 1;
		}
	}
	return (redraw);
}

/* Free a screen's virtual images. */
void
image_virtual_free_all(struct screen *s)
{
	struct image	*im, *im1;

	TAILQ_FOREACH_SAFE(im, &s->virtual_images, entry, im1)
		image_virtual_free(im);
}

/*
 * Draw the image cells the placeholders on part of a line show: px,py the
 * first cell and nx the width in the screen, atx,aty where that part is on
 * the terminal. Neighbouring placeholders of one image row go as one image.
 */
void
tty_draw_placeholders(struct tty *tty, struct screen *s, u_int px, u_int py,
    u_int nx, u_int atx, u_int aty)
{
	struct grid		*gd = s->grid;
	struct grid_cell	 gc;
	struct image		*im;
	u_int			 i, id, row, col, start, run, nid, nrow, ncol;
	int			 complete;

	if (TAILQ_EMPTY(&s->virtual_images))
		return;
	if (tty->xpixel == 0 || tty->ypixel == 0)
		return;
	if (!tty->at_speaks && (~tty->term->flags & TERM_SIXEL) &&
	    !tty_term_has(tty->term, TTYC_SXL))
		return;

	for (i = 0; i < nx; ) {
		grid_view_get_cell(gd, px + i, py, &gc);
		if ((gc.flags & GRID_FLAG_PADDING) ||
		    !image_placeholder_cell(&gc, &id, &row, &col, &complete) ||
		    !complete) {
			i++;
			continue;
		}
		start = i;
		run = 1;
		for (i++; i < nx; i++, run++) {
			grid_view_get_cell(gd, px + i, py, &gc);
			if ((gc.flags & GRID_FLAG_PADDING) ||
			    !image_placeholder_cell(&gc, &nid, &nrow, &ncol,
			    &complete) || !complete ||
			    nid != id || nrow != row || ncol != col + run)
				break;
		}
		if ((im = image_virtual_find(s, id)) == NULL)
			continue;
		log_debug("%s: id=%u row=%u cols %u-%u at %u,%u", __func__,
		    id, row, col, col + run, atx + start, aty);
#ifdef HAVE_AT_PROTOCOL
		if (tty->at_speaks && im->pixels != NULL) {
			tty_at_place(tty, im, atx + start, aty, col, row, run, 1);
			continue;
		}
#endif
		if ((~tty->term->flags & TERM_SIXEL) &&
		    !tty_term_has(tty->term, TTYC_SXL))
			continue;
		tty_draw_sixel_part(tty, im->data, col, row, run, 1,
		    atx + start, aty);
	}
}

/*
 * A virtual image's pixels go to the next build after the screen's other
 * state, where a build before them leaves nothing, and are matched to the
 * image by ID when they come back.
 */
void
image_upgrade_save_pixels(struct evbuffer *evb, struct screen *s)
{
	struct evbuffer	*o = evbuffer_new();
	struct image	*im;

	TAILQ_FOREACH(im, &s->virtual_images, entry) {
		if (im->pixels == NULL)
			continue;
		upw_u32(o, im->id);
		upw_u32(o, im->pwidth);
		upw_u32(o, im->pheight);
		upw_u32(o, im->pbpp);
		upw_u32(o, im->pcols);
		upw_u32(o, im->prows);
		upw_data(o, im->pixels, (size_t)im->pwidth * im->pheight *
		    im->pbpp);
	}
	upw_obj(evb, o);
	evbuffer_free(o);
}

void
image_upgrade_restore_pixels(struct upgrade_reader *r, struct screen *s)
{
	struct upgrade_reader	 o;
	struct image		*im;
	const char		*data;
	size_t			 size;
	u_int			 id, w, h, bpp, cols, rows;

	upr_obj(r, &o);
	while (o.left > 0 && !o.error) {
		id = upr_u32(&o);
		w = upr_u32(&o);
		h = upr_u32(&o);
		bpp = upr_u32(&o);
		cols = upr_u32(&o);
		rows = upr_u32(&o);
		data = upr_data(&o, &size);
		if (o.error || data == NULL)
			break;
		if ((im = image_virtual_find(s, id)) == NULL ||
		    size != (size_t)w * h * bpp || w == 0 || h == 0 ||
		    (bpp != 3 && bpp != 4) || cols == 0 || rows == 0)
			continue;
		free(im->pixels);
		im->pixels = xmalloc(size);
		memcpy(im->pixels, data, size);
		im->pwidth = w;
		im->pheight = h;
		im->pbpp = bpp;
		im->pcols = cols;
		im->prows = rows;
	}
	if (o.error)
		r->error = 1;
}
