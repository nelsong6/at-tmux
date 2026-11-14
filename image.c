/* $OpenBSD$ */

/*
 * Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
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

/* The images one screen keeps: storing another frees that screen's oldest. */
#define MAX_IMAGE_COUNT 20

static void printflike(3, 4)
image_log(struct image *im, const char* from, const char* fmt, ...)
{
	va_list	ap;
	char	s[128];

	if (log_get_level() == 0)
		return;

	if (fmt == NULL) {
		log_debug("%s: %p (%ux%u %u,%u)", from, im, im->sx, im->sy,
		    im->px, im->py);
		return;
	}

	va_start(ap, fmt);
	vsnprintf(s, sizeof s, fmt, ap);
	va_end(ap);

	log_debug("%s: %p (%ux%u %u,%u): %s", from, im, im->sx, im->sy,
	    im->px, im->py, s);
}

static void
image_free(struct image *im)
{
	struct screen	*s = im->s;

	image_log(im, __func__, NULL);

	TAILQ_REMOVE(&s->images, im, entry);
	s->image_count--;
	sixel_free(im->data);
	free(im->fallback);
	free(im);
}

/* Make room for another image: the oldest sixel image goes, else the oldest. */
static void
image_evict(struct screen *s)
{
	struct image	*im;

	TAILQ_FOREACH(im, &s->images, entry) {
		if (!im->placed) {
			image_free(im);
			return;
		}
	}
	image_free(TAILQ_FIRST(&s->images));
}

int
image_free_all(struct screen *s)
{
	struct image	*im, *im1;
	int		 redraw = !TAILQ_EMPTY(&s->images);

	if (redraw)
		log_debug ("%s", __func__);
	TAILQ_FOREACH_SAFE(im, &s->images, entry, im1)
		image_free(im);
	return (redraw);
}

/* Put a screen's images aside while the alternate screen is on. */
void
image_save(struct screen *s)
{
	TAILQ_CONCAT(&s->saved_images, &s->images, entry);
	s->saved_image_count = s->image_count;
	s->image_count = 0;
}

/* Free the alternate screen's images and bring back those put aside. */
void
image_restore(struct screen *s)
{
	image_free_all(s);
	TAILQ_CONCAT(&s->images, &s->saved_images, entry);
	s->image_count = s->saved_image_count;
	s->saved_image_count = 0;
}

/* Free every image of a screen, those put aside too. */
void
image_free_screen(struct screen *s)
{
	image_restore(s);
	image_free_all(s);
}

/* Create text placeholder for an image. */
static void
image_fallback(char **ret, u_int sx, u_int sy)
{
	char	*buf, *label;
	u_int	 py, size, lsize;

	/* Allocate first line. */
	lsize = xasprintf(&label, "SIXEL IMAGE (%ux%u)\r\n", sx, sy) + 1;
	if (sx < lsize - 3)
		size = lsize - 1;
	else
		size = sx + 2;

	/* Remaining lines. Every placeholder line has \r\n at the end. */
	size += (sx + 2) * (sy - 1) + 1;
	*ret = buf = xmalloc(size);

	/* Render first line. */
	if (sx < lsize - 3) {
		memcpy(buf, label, lsize);
		buf += lsize - 1;
	} else {
		memcpy(buf, label, lsize - 3);
		buf += lsize - 3;
		memset(buf, '+', sx - lsize + 3);
		buf += sx - lsize + 3;
		snprintf(buf, 3, "\r\n");
		buf += 2;
	}

	/* Remaining lines. */
	for (py = 1; py < sy; py++) {
		memset(buf, '+', sx);
		buf += sx;
		snprintf(buf, 3, "\r\n");
		buf += 2;
	}

	free(label);
}

struct image*
image_store(struct screen *s, struct sixel_image *si)
{
	struct image	*im;

	im = xcalloc(1, sizeof *im);
	im->s = s;
	im->data = si;

	im->px = s->cx;
	im->py = s->cy;
	sixel_size_in_cells(si, &im->sx, &im->sy);

	image_fallback(&im->fallback, im->sx, im->sy);

	image_log(im, __func__, NULL);
	TAILQ_INSERT_TAIL(&s->images, im, entry);
	if (++s->image_count > MAX_IMAGE_COUNT)
		image_evict(s);

	return (im);
}

/*
 * Place an image at the cursor for the program to keep (kitty graphics). One
 * with the same ID goes first: all of its placements, or only the one with
 * the same placement ID if there is one. replaced says whether one went.
 */
struct image *
image_place(struct screen *s, struct sixel_image *si, u_int id,
    u_int placement, int *replaced)
{
	struct image	*im, *im1;

	*replaced = 0;
	if (id != 0) {
		TAILQ_FOREACH_SAFE(im, &s->images, entry, im1) {
			if (!im->placed || im->id != id)
				continue;
			if (placement != 0 && im->placement != placement)
				continue;
			image_free(im);
			*replaced = 1;
		}
	}

	im = image_store(s, si);
	im->placed = 1;
	im->id = id;
	im->placement = placement;
	image_log(im, __func__, "id=%u, placement=%u", id, placement);
	return (im);
}

/* Delete the placed images with an ID, or all of them. */
int
image_delete(struct screen *s, int all, u_int id)
{
	struct image	*im, *im1;
	int		 redraw = 0;

	TAILQ_FOREACH_SAFE(im, &s->images, entry, im1) {
		if (im->placed && (all || im->id == id)) {
			image_free(im);
			redraw = 1;
		}
	}
	return (redraw);
}

/* Whether an image covers any of an area's cells. */
static int
image_covers(struct image *im, u_int px, u_int py, u_int nx, u_int ny)
{
	return (py < im->py + im->sy && py + ny > im->py &&
	    px < im->px + im->sx && px + nx > im->px);
}

/*
 * Rows have been written over or cleared: a sixel image on them goes, and a
 * placed one stays, to be drawn again over them.
 */
int
image_check_line(struct screen *s, u_int py, u_int ny)
{
	struct image	*im, *im1;
	int		 redraw = 0, in;

	TAILQ_FOREACH_SAFE(im, &s->images, entry, im1) {
		in = (py + ny > im->py && py < im->py + im->sy);
		image_log(im, __func__, "py=%u, ny=%u, in=%d", py, ny, in);
		if (in) {
			if (!im->placed)
				image_free(im);
			redraw = 1;
		}
	}
	return (redraw);
}

/* Cells have been written over: as image_check_line, for those cells. */
int
image_check_area(struct screen *s, u_int px, u_int py, u_int nx, u_int ny)
{
	struct image	*im, *im1;
	int		 redraw = 0, in;

	TAILQ_FOREACH_SAFE(im, &s->images, entry, im1) {
		in = image_covers(im, px, py, nx, ny);
		image_log(im, __func__, "py=%u, ny=%u, in=%d", py, ny, in);
		if (in) {
			if (!im->placed)
				image_free(im);
			redraw = 1;
		}
	}
	return (redraw);
}

/*
 * Part of rows has been cleared, inserted into or deleted from: a sixel image
 * on those rows goes, as it always has; a placed image is drawn again only if
 * the cells were its own, so text changing beside it leaves it alone.
 */
int
image_check_cells(struct screen *s, u_int px, u_int py, u_int nx, u_int ny)
{
	struct image	*im, *im1;
	int		 redraw = 0;

	TAILQ_FOREACH_SAFE(im, &s->images, entry, im1) {
		if (im->placed) {
			if (image_covers(im, px, py, nx, ny))
				redraw = 1;
		} else if (py + ny > im->py && py < im->py + im->sy) {
			image_free(im);
			redraw = 1;
		}
	}
	return (redraw);
}

/* The screen has been cleared: sixel images go, placed images stay. */
int
image_clear(struct screen *s)
{
	struct image	*im, *im1;
	int		 redraw = !TAILQ_EMPTY(&s->images);

	TAILQ_FOREACH_SAFE(im, &s->images, entry, im1) {
		if (!im->placed)
			image_free(im);
	}
	return (redraw);
}

/*
 * Rows upper to lower have moved by delta (up if negative), as a scroll
 * region scrolling, or lines inserted or deleted, moves them. A placed image
 * inside them moves with its rows and goes if they take it out; one only
 * partly inside goes, as does a sixel image on any of them.
 */
int
image_move_rows(struct screen *s, u_int upper, u_int lower, int delta)
{
	struct image	*im, *im1;
	int		 redraw = 0, py;

	TAILQ_FOREACH_SAFE(im, &s->images, entry, im1) {
		if (im->py > lower || im->py + im->sy <= upper)
			continue;
		redraw = 1;
		py = (int)im->py + delta;
		if (!im->placed || im->py < upper ||
		    im->py + im->sy - 1 > lower || py < (int)upper ||
		    py + (int)im->sy - 1 > (int)lower) {
			image_free(im);
			continue;
		}
		im->py = py;
	}
	return (redraw);
}

int
image_scroll_up(struct screen *s, u_int lines)
{
	struct image		*im, *im1;
	int			 redraw = 0;
	u_int			 sx, sy;
	struct sixel_image	*new;

	TAILQ_FOREACH_SAFE(im, &s->images, entry, im1) {
		if (im->py >= lines) {
			image_log(im, __func__, "1, lines=%u", lines);
			im->py -= lines;
			redraw = 1;
			continue;
		}
		if (im->py + im->sy <= lines) {
			image_log(im, __func__, "2, lines=%u", lines);
			image_free(im);
			redraw = 1;
			continue;
		}
		sx = im->sx;
		sy = (im->py + im->sy) - lines;
		image_log(im, __func__, "3, lines=%u, sy=%u", lines, sy);

		new = sixel_scale(im->data, 0, 0, 0, im->sy - sy, sx, sy, 1);
		sixel_free(im->data);
		im->data = new;

		im->py = 0;
		sixel_size_in_cells(im->data, &im->sx, &im->sy);

		free(im->fallback);
		image_fallback(&im->fallback, im->sx, im->sy);
		redraw = 1;
	}
	return (redraw);
}

static void
image_upgrade_save_list(struct evbuffer *o, struct images *images)
{
	struct image	*im;
	char		*data;
	size_t		 size;
	u_int		 xpixel, ypixel;

	TAILQ_FOREACH(im, images, entry) {
		data = sixel_print(im->data, NULL, &size);
		if (data == NULL)
			continue;
		sixel_cell_size(im->data, &xpixel, &ypixel);
		upw_u32(o, images == &im->s->saved_images);
		upw_u32(o, im->px);
		upw_u32(o, im->py);
		upw_u32(o, im->placed);
		upw_u32(o, im->id);
		upw_u32(o, im->placement);
		upw_u32(o, xpixel);
		upw_u32(o, ypixel);
		upw_data(o, data, size);
		free(data);
	}
}

/*
 * A screen's images, for upgrade-server: each as the sixel it is drawn with,
 * after the screen's other state, where a build that doesn't read them
 * leaves them.
 */
void
image_upgrade_save(struct evbuffer *evb, struct screen *s)
{
	struct evbuffer	*o = evbuffer_new();

	image_upgrade_save_list(o, &s->images);
	image_upgrade_save_list(o, &s->saved_images);
	upw_obj(evb, o);
	evbuffer_free(o);
}

void
image_upgrade_restore(struct upgrade_reader *r, struct screen *s)
{
	struct upgrade_reader	 o;
	struct image		*im;
	struct sixel_image	*si;
	const char		*data, *q, *p;
	size_t			 size;
	u_int			 saved, px, py, placed, id, placement;
	u_int			 xpixel, ypixel, p2;

	upr_obj(r, &o);
	while (o.left > 0 && !o.error) {
		saved = upr_u32(&o);
		px = upr_u32(&o);
		py = upr_u32(&o);
		placed = upr_u32(&o);
		id = upr_u32(&o);
		placement = upr_u32(&o);
		xpixel = upr_u32(&o);
		ypixel = upr_u32(&o);
		data = upr_data(&o, &size);
		if (o.error || data == NULL)
			break;

		/* sixel_print writes "\033P0;<p2>q...\033\\". */
		q = memchr(data, 'q', size);
		p = memchr(data, ';', size);
		if (q == NULL || size < 2 || (size_t)(q - data) + 2 > size)
			continue;
		p2 = (p != NULL && p < q) ? (u_int)strtoul(p + 1, NULL, 10) : 0;
		si = sixel_parse(q, size - (q - data) - 2, p2, xpixel, ypixel);
		if (si == NULL)
			continue;

		im = xcalloc(1, sizeof *im);
		im->s = s;
		im->data = si;
		im->px = px;
		im->py = py;
		im->placed = placed;
		im->id = id;
		im->placement = placement;
		sixel_size_in_cells(si, &im->sx, &im->sy);
		image_fallback(&im->fallback, im->sx, im->sy);
		if (saved) {
			TAILQ_INSERT_TAIL(&s->saved_images, im, entry);
			s->saved_image_count++;
		} else {
			TAILQ_INSERT_TAIL(&s->images, im, entry);
			s->image_count++;
		}
		image_log(im, __func__, "placed=%u, id=%u", placed, id);
	}
	if (o.error)
		r->error = 1;
}
