/* $OpenBSD$ */

/*
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

#include "tmux.h"

/*
 * Ask a pane, window or session to close: its programs are told to close and
 * it goes once they have exited (server_close_pane).
 */

static enum cmd_retval	cmd_close_exec(struct cmd *, struct cmdq_item *);

const struct cmd_entry cmd_close_pane_entry = {
	.name = "close-pane",
	.alias = "closep",

	.args = { "at:", 0, 0, NULL },
	.usage = "[-a] " CMD_TARGET_PANE_USAGE,

	.target = { 't', CMD_FIND_PANE, 0 },

	.flags = CMD_AFTERHOOK,
	.exec = cmd_close_exec
};

const struct cmd_entry cmd_close_window_entry = {
	.name = "close-window",
	.alias = "closew",

	.args = { "at:", 0, 0, NULL },
	.usage = "[-a] " CMD_TARGET_WINDOW_USAGE,

	.target = { 't', CMD_FIND_WINDOW, 0 },

	.flags = 0,
	.exec = cmd_close_exec
};

/* No alias, like kill-session. */
const struct cmd_entry cmd_close_session_entry = {
	.name = "close-session",
	.alias = NULL,

	.args = { "at:", 0, 0, NULL },
	.usage = "[-a] " CMD_TARGET_SESSION_USAGE,

	.target = { 't', CMD_FIND_SESSION, 0 },

	.flags = 0,
	.exec = cmd_close_exec
};

/* Close every window in a session but one. */
static void
cmd_close_other_windows(struct session *s, struct window *keep)
{
	struct winlink	 *wl;
	struct window	**list = NULL;
	u_int		  n = 0, i;

	/* Closing one may remove it at once, so list them first. */
	RB_FOREACH(wl, winlinks, &s->windows) {
		if (wl->window == keep)
			continue;
		for (i = 0; i < n; i++) {
			if (list[i] == wl->window)
				break;
		}
		if (i != n)
			continue;
		list = xreallocarray(list, n + 1, sizeof *list);
		list[n++] = wl->window;
		window_add_ref(wl->window, __func__);
	}
	for (i = 0; i < n; i++) {
		server_close_window(list[i]);
		window_remove_ref(list[i], __func__);
	}
	free(list);
}

static enum cmd_retval
cmd_close_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args		*args = cmd_get_args(self);
	const struct cmd_entry	*entry = cmd_get_entry(self);
	struct cmd_find_state	*target = cmdq_get_target(item);
	struct session		*s = target->s, *sloop, *stmp;
	struct window_pane	*wp, *wp1;

	if (entry == &cmd_close_pane_entry) {
		if (!args_has(args, 'a')) {
			server_close_pane(target->wp);
			return (CMD_RETURN_NORMAL);
		}
		TAILQ_FOREACH_SAFE(wp, &target->w->panes, entry, wp1) {
			if (wp != target->wp)
				server_close_pane(wp);
		}
		return (CMD_RETURN_NORMAL);
	}

	if (entry == &cmd_close_window_entry) {
		if (args_has(args, 'a'))
			cmd_close_other_windows(s, target->w);
		else
			server_close_window(target->w);
		return (CMD_RETURN_NORMAL);
	}

	if (!args_has(args, 'a')) {
		server_close_session(s);
		return (CMD_RETURN_NORMAL);
	}
	RB_FOREACH_SAFE(sloop, sessions, &sessions, stmp) {
		if (sloop != s)
			server_close_session(sloop);
	}
	return (CMD_RETURN_NORMAL);
}
