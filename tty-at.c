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
#include <sys/stat.h>

#ifdef __APPLE__
#include <libproc.h>
#endif
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <unistd.h>
#endif

#include <at_protocol.h>

#include "tmux.h"

/*
 * at-protocol (ATT-7): the language the server speaks to an at-terminal
 * client, one package both compile (romaine-life/at-protocol). The server
 * says hello with its opening requests; a terminal that speaks it answers
 * with its own hello, and when the versions are the same the server sends
 * it each virtual image once, by ID, and draws a placeholder run as a
 * placement of the picture's cells instead of sixel (image-placeholder.c).
 * Any other client, and one whose version differs, keeps getting sixel.
 *
 * The versions are the commits each side's build pinned, so neither can
 * tell which is newer; on a mismatch the server says so to that client and,
 * if its own file on disk is newer than the running process (home-sync
 * switched the installed build under it), hands itself to it.
 */

/* The version this build speaks. */
const char *
tty_at_version(void)
{
	return (at_proto_version());
}

/*
 * Send a message whole or not at all (TMUX-240). While the client can't keep
 * up, tmux discards what it would write (TTY_BLOCK) and later redraws, which
 * places every image again; a message discarded then is not sent, so a picture
 * is never thought delivered when it didn't go. Once a message is in the
 * output, nothing is discarded until the output has all gone (TTY_NOBLOCK, as
 * for passthrough and sixel), so it can't be cut off part-way.
 */
static int
tty_at_send(struct tty *tty, const at_proto_msg *msg)
{
	char	*out;
	size_t	 len;

	if (tty->flags & TTY_BLOCK) {
		log_debug("%s: not sending %s while blocked", tty->client->name,
		    at_proto_kind_name(msg->kind));
		return (-1);
	}
	if (at_proto_encode(msg, &out, &len) != 0) {
		log_debug("%s: can't encode %s", tty->client->name,
		    at_proto_kind_name(msg->kind));
		return (-1);
	}
	tty_puts(tty, out);
	tty->flags |= TTY_NOBLOCK;
	free(out);
	return (0);
}

/* Say hello to the terminal. */
void
tty_at_hello(struct tty *tty)
{
	at_proto_msg	msg;

	memset(&msg, 0, sizeof msg);
	msg.kind = AT_PROTO_HELLO;
	strlcpy(msg.u.hello.version, at_proto_version(),
	    sizeof msg.u.hello.version);
	tty_at_send(tty, &msg);
}

/*
 * The running server's file on disk is newer than the process: home-sync
 * installed a release and switched the current junction under it, or on a
 * Mac or Linux machine a new build was installed over it.
 */
static int
tty_at_installed_is_newer(char *path, size_t pathlen)
{
	struct stat	sb;
#if defined(__linux__)
	ssize_t		n;
	char		*deleted;
#endif

#if defined(_WIN32)
	if (GetModuleFileNameA(NULL, path, pathlen) == 0)
		return (0);
#elif defined(__APPLE__)
	if (proc_pidpath(getpid(), path, pathlen) <= 0)
		return (0);
#elif defined(__linux__)
	/* Installed over, the file the process runs is "<path> (deleted)". */
	n = readlink("/proc/self/exe", path, pathlen - 1);
	if (n <= 0)
		return (0);
	path[n] = '\0';
	deleted = strstr(path, " (deleted)");
	if (deleted != NULL && deleted[10] == '\0')
		*deleted = '\0';
#else
	path[0] = '\0';
	(void)pathlen;
	return (0);
#endif
	if (stat(path, &sb) != 0)
		return (0);
	return (sb.st_mtime > start_time.tv_sec);
}

/* The terminal answered hello with its version. */
void
tty_at_answered(struct tty *tty, const char *version)
{
	struct client	*c = tty->client;
	static int	 upgrading;
	char		 path[4096], *cause;

	strlcpy(tty->at_version, version, sizeof tty->at_version);
	tty->at_spare_sent = 0;
	free(tty->at_images);
	tty->at_images = NULL;
	tty->at_nimages = 0;
	if (strcmp(version, at_proto_version()) == 0) {
		log_debug("%s: at-protocol %s, the same as this build", c->name,
		    version);
		tty->at_speaks = 1;
		server_redraw_client(c);
		return;
	}
	tty->at_speaks = 0;
	log_debug("%s: at-protocol %s, this build %s", c->name, version,
	    at_proto_version());
	if (!upgrading && tty_at_installed_is_newer(path, sizeof path)) {
		upgrading = 1;
		if (server_upgrade_request(path, &cause) != 0) {
			status_message_set(c, 0, 1, 0, 0, "The terminal speaks "
			    "at-protocol %.12s and this server %.12s; handing the "
			    "server to the installed tmux failed: %s", version,
			    at_proto_version(), cause);
			free(cause);
			return;
		}
		status_message_set(c, 0, 1, 0, 0, "The terminal speaks "
		    "at-protocol %.12s and this server %.12s: handing the "
		    "server to the installed tmux", version,
		    at_proto_version());
		return;
	}
	status_message_set(c, 0, 1, 0, 1, "The terminal speaks at-protocol "
	    "%.12s and this server %.12s: avatars go as sixel until both are "
	    "built from the same at-protocol", version, at_proto_version());
}

static int
tty_at_has(struct tty *tty, u_int id)
{
	u_int	i;

	for (i = 0; i < tty->at_nimages; i++) {
		if (tty->at_images[i] == id)
			return (1);
	}
	return (0);
}

/* Send a virtual image to the terminal, once; 0 once it has gone. */
static int
tty_at_store(struct tty *tty, struct image *im)
{
	at_proto_msg	msg;

	if (tty_at_has(tty, im->at_id))
		return (0);
	memset(&msg, 0, sizeof msg);
	msg.kind = AT_PROTO_IMAGE_STORE;
	msg.u.image_store.id = im->at_id;
	msg.u.image_store.width = im->pwidth;
	msg.u.image_store.height = im->pheight;
	msg.u.image_store.cols = im->pcols;
	msg.u.image_store.rows = im->prows;
	msg.u.image_store.format = im->pbpp == 4 ? AT_PROTO_RGBA : AT_PROTO_RGB;
	msg.u.image_store.pixels = im->pixels;
	msg.u.image_store.len = (size_t)im->pwidth * im->pheight * im->pbpp;
	if (tty_at_send(tty, &msg) != 0)
		return (-1);
	tty->at_images = xreallocarray(tty->at_images, tty->at_nimages + 1,
	    sizeof *tty->at_images);
	tty->at_images[tty->at_nimages++] = im->at_id;
	log_debug("%s: sent image %u as %u (%ux%u, %ux%u cells)",
	    tty->client->name, im->id, im->at_id, im->pwidth, im->pheight,
	    im->pcols, im->prows);
	return (0);
}

/*
 * Show cells sc,sr of a virtual image's grid, nx by ny, at x,y on the
 * terminal.
 */
void
tty_at_place(struct tty *tty, struct image *im, u_int x, u_int y, u_int sc,
    u_int sr, u_int nx, u_int ny)
{
	at_proto_msg	msg;

	if (tty_at_store(tty, im) != 0)
		return;
	memset(&msg, 0, sizeof msg);
	msg.kind = AT_PROTO_IMAGE_PLACE;
	msg.u.image_place.id = im->at_id;
	msg.u.image_place.col = x;
	msg.u.image_place.row = y;
	msg.u.image_place.src_col = sc;
	msg.u.image_place.src_row = sr;
	msg.u.image_place.cols = nx;
	msg.u.image_place.rows = ny;
	tty_at_send(tty, &msg);
}

/* A virtual image is going: every terminal that has it forgets it. */
void
tty_at_drop(struct image *im)
{
	struct client	*c;
	struct tty	*tty;
	at_proto_msg	 msg;
	u_int		 i;

	TAILQ_FOREACH(c, &clients, entry) {
		tty = &c->tty;
		if (~tty->flags & TTY_OPENED || !tty->at_speaks)
			continue;
		for (i = 0; i < tty->at_nimages; i++) {
			if (tty->at_images[i] == im->at_id)
				break;
		}
		if (i == tty->at_nimages)
			continue;
		memmove(tty->at_images + i, tty->at_images + i + 1,
		    (tty->at_nimages - i - 1) * sizeof *tty->at_images);
		tty->at_nimages--;
		memset(&msg, 0, sizeof msg);
		msg.kind = AT_PROTO_IMAGE_DROP;
		msg.u.image_drop.id = im->at_id;
		tty_at_send(tty, &msg);
	}
}

/* The terminal is gone: nothing it was sent is known any more. */
void
tty_at_reset(struct tty *tty)
{
	free(tty->at_images);
	tty->at_images = NULL;
	tty->at_nimages = 0;
	tty->at_speaks = 0;
	tty->at_version[0] = '\0';
	tty->at_spare_sent = 0;
}

/*
 * Spare space (ATT-37): a fullscreen at-terminal's rows are whole pixels, so
 * less than a row is left over, which it draws under the last row unless told
 * to put it above a screen row. A program in a pane asks for it above a row
 * of its pane; the server keeps that per pane and tells each client that
 * speaks at-protocol the screen row it comes to, or none, whenever that
 * changes: after the client is drawn (a window or pane change, a resize, the
 * status line moving all redraw it) and when a pane's request changes.
 */

/* Send the terminal a spare-space row, if it isn't the one it has. */
void
tty_at_spare_space(struct tty *tty, u_int row)
{
	at_proto_msg	msg;

	if (~tty->flags & TTY_OPENED || !tty->at_speaks)
		return;
	if (tty->at_spare_sent && tty->at_spare == row)
		return;
	memset(&msg, 0, sizeof msg);
	msg.kind = AT_PROTO_SPARE_SPACE;
	msg.u.spare_space.row = (row == UINT_MAX) ? AT_PROTO_SPARE_NONE : row;
	if (tty_at_send(tty, &msg) != 0)
		return;
	tty->at_spare = row;
	tty->at_spare_sent = 1;
	if (row == UINT_MAX)
		log_debug("%s: spare space none", tty->client->name);
	else
		log_debug("%s: spare space above row %u", tty->client->name, row);
}

/* A pane with a request whose rows are the whole width of its window. */
static int
tty_at_spare_pane(struct window *w, struct window_pane *wp)
{
	return (wp != NULL &&
	    wp->at_spare_row != UINT_MAX &&
	    wp->at_spare_row < wp->sy &&
	    wp->xoff == 0 &&
	    wp->sx == w->sx &&
	    window_pane_visible(wp));
}

/*
 * The screen row a client's spare space goes above: the row a full-width
 * pane of its window asked for (the active pane's first), below the status
 * lines drawn above the window, as screen_redraw_set_context places it.
 */
static u_int
tty_at_spare_row(struct client *c)
{
	struct window		*w = c->session->curw->window;
	struct window_pane	*wp = w->active, *loop;
	u_int			 lines, ox, oy, sx, sy, y;

	if (!tty_at_spare_pane(w, wp)) {
		wp = NULL;
		TAILQ_FOREACH(loop, &w->panes, entry) {
			if (tty_at_spare_pane(w, loop)) {
				wp = loop;
				break;
			}
		}
		if (wp == NULL)
			return (UINT_MAX);
	}
	y = wp->yoff + wp->at_spare_row;

	tty_window_offset(&c->tty, &ox, &oy, &sx, &sy);
	if (y < oy || y - oy >= sy)
		return (UINT_MAX);
	y -= oy;

	lines = status_line_size(c);
	if (c->message_string != NULL || c->prompt_string != NULL)
		lines = (lines == 0) ? 1 : lines;
	if (lines != 0 &&
	    options_get_number(c->session->options, "status-position") == 0)
		y += lines;
	return (y);
}

/* Tell a client where its spare space goes now. */
void
tty_at_spare_update(struct client *c)
{
	if (c->session == NULL || (c->flags & CLIENT_CONTROL))
		return;
	if (~c->tty.flags & TTY_OPENED || !c->tty.at_speaks)
		return;
	tty_at_spare_space(&c->tty, tty_at_spare_row(c));
}

/* A pane's request changed: tell every client showing its window. */
void
tty_at_spare_window(struct window *w)
{
	struct client	*c;

	TAILQ_FOREACH(c, &clients, entry) {
		if (c->session != NULL && c->session->curw != NULL &&
		    c->session->curw->window == w)
			tty_at_spare_update(c);
	}
}

/* A pane's program has gone: its request goes with it. */
void
tty_at_pane_reset(struct window_pane *wp)
{
	if (wp->at_spare_row == UINT_MAX)
		return;
	wp->at_spare_row = UINT_MAX;
	tty_at_spare_window(wp->window);
}

/*
 * An APC string from a program in a pane (input_exit_apc). A spare-space
 * request is kept for the pane; returns 1 for that, 0 for anything else,
 * which goes on as any APC string does.
 */
int
tty_at_from_pane(struct window_pane *wp, const char *buf, size_t len)
{
	at_proto_msg	msg;
	u_int		row;

	if (len < 3 || memcmp(buf, "at;", 3) != 0)
		return (0);
	if (at_proto_decode(buf, len, &msg) != 1)
		return (0);
	if (msg.kind != AT_PROTO_SPARE_SPACE) {
		at_proto_msg_free(&msg);
		return (0);
	}
	row = msg.u.spare_space.row;
	at_proto_msg_free(&msg);
	if (row == AT_PROTO_SPARE_NONE)
		row = UINT_MAX;
	if (row == UINT_MAX)
		log_debug("%%%u: spare space none", wp->id);
	else
		log_debug("%%%u: spare space above pane row %u", wp->id, row);
	if (wp->at_spare_row != row) {
		wp->at_spare_row = row;
		tty_at_spare_window(wp->window);
	}
	return (1);
}

/*
 * An at-protocol message from the terminal, in its input: ESC _ at; ... ESC
 * \. Returns 0 for one read, -1 for input that isn't one, 1 for part of one.
 */
int
tty_keys_at(struct tty *tty, const char *buf, size_t len, size_t *size)
{
	const char	prefix[] = "\033_at;";
	size_t		plen = sizeof prefix - 1, end;
	at_proto_msg	msg;

	*size = 0;
	if (len < plen) {
		if (memcmp(buf, prefix, len) != 0)
			return (-1);
		return (1);
	}
	if (memcmp(buf, prefix, plen) != 0)
		return (-1);
	for (end = plen; end < len; end++) {
		if (buf[end] == '\033')
			break;
	}
	if (end == len || end + 1 == len)
		return (1);
	if (buf[end + 1] != '\\')
		return (-1);
	*size = end + 2;

	switch (at_proto_decode(buf + 2, end - 2, &msg)) {
	case 1:
		if (msg.kind == AT_PROTO_HELLO)
			tty_at_answered(tty, msg.u.hello.version);
		else {
			log_debug("%s: the terminal sent %s", tty->client->name,
			    at_proto_kind_name(msg.kind));
		}
		at_proto_msg_free(&msg);
		break;
	default:
		log_debug("%s: malformed at-protocol message from the terminal",
		    tty->client->name);
		break;
	}
	return (0);
}
