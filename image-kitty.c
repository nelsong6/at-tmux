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

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include "tmux.h"

/*
 * A subset of the kitty graphics protocol (APC G ... ST): a program places an
 * image by ID and deletes it by ID, and tmux keeps it, drawing it again over
 * whatever is written under it (image.c). Supported:
 *
 *	a=T	transmit and place at the cursor: f=24 (RGB) or f=32 (RGBA), s and
 *		v its size in pixels, sent directly (t=d) and uncompressed, in
 *		chunks with m=1 on all but the last; c and r the cells it fills;
 *		i the image ID, p a placement ID; C=1 leaves the cursor
 *	a=d	delete: d=i or d=I those with ID i, d=a or d=A (or none) all
 *	a=q	ask whether a=T would take these keys, without placing
 *
 * q=1 answers only failures and q=2 nothing; nothing is answered without i.
 * The images reach the client's terminal as sixel.
 */

/* Most a transmission may be once decoded: a 4096-pixel square of RGBA. */
#define KITTY_DATA_LIMIT (4096 * 4096 * 4)

struct kitty_keys {
	char	a;
	char	d;
	char	t;
	char	o;
	u_int	f;
	u_int	i;
	u_int	p;
	u_int	s;
	u_int	v;
	u_int	c;
	u_int	r;
	u_int	C;
	u_int	q;
	u_int	m;
};

/* Read "k=v,k=v": a key is one letter, a value a number or one letter. */
static int
kitty_parse_keys(const char *s, size_t len, struct kitty_keys *k)
{
	const char	*end = s + len, *cp;
	char		 key, *ep;
	unsigned long	 n;

	memset(k, 0, sizeof *k);
	k->a = 't';
	k->t = 'd';
	k->f = 32;

	cp = s;
	while (cp < end) {
		if (end - cp < 3 || cp[1] != '=')
			return (-1);
		key = cp[0];
		cp += 2;
		if (*cp >= '0' && *cp <= '9') {
			n = strtoul(cp, &ep, 10);
			if (ep == cp || ep > end || n > UINT_MAX)
				return (-1);
			cp = ep;
		} else {
			n = (u_char)*cp++;
		}
		switch (key) {
		case 'a': k->a = (char)n; break;
		case 'd': k->d = (char)n; break;
		case 't': k->t = (char)n; break;
		case 'o': k->o = (char)n; break;
		case 'f': k->f = n; break;
		case 'i': k->i = n; break;
		case 'p': k->p = n; break;
		case 's': k->s = n; break;
		case 'v': k->v = n; break;
		case 'c': k->c = n; break;
		case 'r': k->r = n; break;
		case 'C': k->C = n; break;
		case 'q': k->q = n; break;
		case 'm': k->m = n; break;
		default: break; /* X, Y, z and the rest change nothing here */
		}
		if (cp < end) {
			if (*cp != ',')
				return (-1);
			cp++;
		}
	}
	return (0);
}

/* An answer, if the program asked for one: none without an ID. */
static char *
kitty_reply(const struct kitty_keys *k, const char *error)
{
	char	*reply, ids[64];

	if (k->i == 0 || k->q >= 2 || (error == NULL && k->q == 1))
		return (NULL);
	if (k->p != 0)
		xsnprintf(ids, sizeof ids, "i=%u,p=%u", k->i, k->p);
	else
		xsnprintf(ids, sizeof ids, "i=%u", k->i);
	xasprintf(&reply, "\033_G%s;%s\033\\", ids, error != NULL ? error :
	    "OK");
	return (reply);
}

/* Whether keys describe an image tmux can take; why not if not. */
static const char *
kitty_check(const struct kitty_keys *k)
{
	if (k->t != 'd')
		return ("ENOTSUP:only direct transmission (t=d)");
	if (k->o != 0)
		return ("ENOTSUP:no compression");
	if (k->f != 24 && k->f != 32)
		return ("ENOTSUP:only f=24 and f=32");
	if (k->s == 0 || k->v == 0)
		return ("EINVAL:s and v are needed");
	if ((uint64_t)k->s * k->v * (k->f / 8) > KITTY_DATA_LIMIT)
		return ("EFBIG:image too large");
	return (NULL);
}

/* The pixels a cell is for this image: what makes it fill c by r cells. */
static void
kitty_cell_size(struct window_pane *wp, const struct kitty_keys *k,
    u_int *xpixel, u_int *ypixel)
{
	struct window	*w = wp->window;

	*xpixel = (w->xpixel != 0) ? w->xpixel : DEFAULT_XPIXEL;
	*ypixel = (w->ypixel != 0) ? w->ypixel : DEFAULT_YPIXEL;
	if (k->c != 0)
		*xpixel = (k->s + k->c - 1) / k->c;
	if (k->r != 0)
		*ypixel = (k->v + k->r - 1) / k->r;
}

/* Decode a transmission and place it. */
static const char *
kitty_place(struct window_pane *wp, struct screen_write_ctx *ctx,
    const struct kitty_keys *k, const char *payload, size_t len)
{
	struct sixel_image	*si;
	const char		*error;
	char			*copy;
	u_char			*pixels;
	size_t			 want;
	int			 got;
	u_int			 bpp = k->f / 8, xpixel, ypixel;

	if ((error = kitty_check(k)) != NULL)
		return (error);
	want = (size_t)k->s * k->v * bpp;

	copy = xmalloc(len + 1);
	memcpy(copy, payload, len);
	copy[len] = '\0';
	pixels = xmalloc(len / 4 * 3 + 3);
	got = b64_pton(copy, pixels, len / 4 * 3 + 3);
	free(copy);
	if (got < 0 || (size_t)got != want) {
		free(pixels);
		return ("EINVAL:the data is not s*v pixels");
	}

	kitty_cell_size(wp, k, &xpixel, &ypixel);
	si = sixel_from_pixels(pixels, k->s, k->v, bpp, xpixel, ypixel);
	free(pixels);
	if (si == NULL)
		return ("EINVAL:bad image");
	screen_write_placeimage(ctx, si, k->i, k->p, k->C == 1);
	return (NULL);
}

/* Run one complete command. */
static char *
kitty_run(struct window_pane *wp, struct screen_write_ctx *ctx,
    const struct kitty_keys *k, const char *payload, size_t len)
{
	const char	*error = NULL;

	switch (k->a) {
	case 'T':
		error = kitty_place(wp, ctx, k, payload, len);
		break;
	case 'q':
		error = kitty_check(k);
		break;
	case 'd':
		switch (k->d) {
		case 0:
		case 'a':
		case 'A':
			screen_write_deleteimages(ctx, 1, 0);
			break;
		case 'i':
		case 'I':
			screen_write_deleteimages(ctx, 0, k->i);
			break;
		default:
			error = "ENOTSUP:only d=a and d=i";
			break;
		}
		/* Deleting answers nothing, as in kitty. */
		return (NULL);
	default:
		error = "ENOTSUP:only a=T, a=d and a=q";
		break;
	}
	return (kitty_reply(k, error));
}

/* Drop a transmission still arriving. */
void
image_kitty_free(struct window_pane *wp)
{
	if (wp->kitty_data != NULL)
		evbuffer_free(wp->kitty_data);
	wp->kitty_data = NULL;
	free(wp->kitty_keys);
	wp->kitty_keys = NULL;
}

/*
 * A kitty graphics command, the APC string after its G. Returns the answer to
 * send the program, if any.
 */
char *
image_kitty(struct window_pane *wp, struct screen_write_ctx *ctx,
    const char *buf, size_t len)
{
	struct kitty_keys	 k, first;
	const char		*semi, *payload = "";
	size_t			 klen, plen = 0;
	char			*reply;

	semi = memchr(buf, ';', len);
	klen = (semi != NULL) ? (size_t)(semi - buf) : len;
	if (semi != NULL) {
		payload = semi + 1;
		plen = len - klen - 1;
	}
	if (kitty_parse_keys(buf, klen, &k) != 0) {
		log_debug("%s: bad keys: %.*s", __func__, (int)klen, buf);
		image_kitty_free(wp);
		return (NULL);
	}

	/* A later chunk carries only m (and q); the first one's keys stand. */
	if (wp->kitty_data == NULL && k.m == 1) {
		wp->kitty_data = evbuffer_new();
		wp->kitty_keys = xstrndup(buf, klen);
	}
	if (wp->kitty_data != NULL) {
		if (EVBUFFER_LENGTH(wp->kitty_data) + plen >
		    KITTY_DATA_LIMIT / 3 * 4 + 4) {
			if (kitty_parse_keys(wp->kitty_keys,
			    strlen(wp->kitty_keys), &first) != 0)
				memset(&first, 0, sizeof first);
			image_kitty_free(wp);
			return (kitty_reply(&first, "EFBIG:image too large"));
		}
		evbuffer_add(wp->kitty_data, payload, plen);
		if (k.m == 1)
			return (NULL);
		if (kitty_parse_keys(wp->kitty_keys, strlen(wp->kitty_keys),
		    &first) != 0) {
			image_kitty_free(wp);
			return (NULL);
		}
		reply = kitty_run(wp, ctx, &first,
		    (const char *)EVBUFFER_DATA(wp->kitty_data),
		    EVBUFFER_LENGTH(wp->kitty_data));
		image_kitty_free(wp);
		return (reply);
	}
	return (kitty_run(wp, ctx, &k, payload, plen));
}
