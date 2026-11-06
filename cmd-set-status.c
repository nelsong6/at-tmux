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

#include <string.h>

#include "tmux.h"

/*
 * Set the Claude state of a window, or of every window in a session, by hand:
 * the window option @claude that Claude Code's hooks set, which the default
 * window-status formats colour through @claude-style. done removes it.
 *
 * attention is the user's move: a finished turn or an open question. It lasts
 * until the window is seen, the current window of a focused client, where
 * waiting (a permission prompt) lasts until it is answered.
 */

#define SET_STATUS_OPTION "@claude"

static enum cmd_retval	cmd_set_status_exec(struct cmd *, struct cmdq_item *);

const struct cmd_entry cmd_set_window_status_entry = {
	.name = "set-window-status",
	.alias = NULL,

	.args = { "t:", 1, 1, NULL },
	.usage = CMD_TARGET_WINDOW_USAGE " working|waiting|attention|done",

	.target = { 't', CMD_FIND_WINDOW, 0 },

	.flags = CMD_AFTERHOOK,
	.exec = cmd_set_status_exec
};

const struct cmd_entry cmd_set_session_status_entry = {
	.name = "set-session-status",
	.alias = NULL,

	.args = { "t:", 1, 1, NULL },
	.usage = CMD_TARGET_SESSION_USAGE " working|waiting|attention|done",

	.target = { 't', CMD_FIND_SESSION, 0 },

	.flags = CMD_AFTERHOOK,
	.exec = cmd_set_status_exec
};

static void
cmd_set_status_window(struct window *w, const char *state)
{
	struct options_entry	*o;

	if (state == NULL) {
		o = options_get_only(w->options, SET_STATUS_OPTION);
		if (o != NULL)
			options_remove_or_default(o, -1, NULL);
	} else
		options_set_string(w->options, SET_STATUS_OPTION, 0, "%s",
		    state);
}

static enum cmd_retval
cmd_set_status_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args		*args = cmd_get_args(self);
	struct cmd_find_state	*target = cmdq_get_target(item);
	const char		*state = args_string(args, 0);
	struct winlink		*wl;

	if (strcmp(state, "done") == 0)
		state = NULL;
	else if (strcmp(state, "working") != 0 &&
	    strcmp(state, "waiting") != 0 &&
	    strcmp(state, "attention") != 0) {
		cmdq_error(item,
		    "unknown status %s: working, waiting, attention or done",
		    state);
		return (CMD_RETURN_ERROR);
	}

	if (cmd_get_entry(self) == &cmd_set_window_status_entry)
		cmd_set_status_window(target->wl->window, state);
	else {
		RB_FOREACH(wl, winlinks, &target->s->windows)
			cmd_set_status_window(wl->window, state);
	}
	options_push_changes(SET_STATUS_OPTION);

	return (CMD_RETURN_NORMAL);
}

/* Clear attention from every window a focused client is looking at. */
void
window_status_seen(void)
{
	struct client		*c;
	struct window		*w;
	struct options_entry	*o;
	const char		*state;

	TAILQ_FOREACH(c, &clients, entry) {
		if (c->session == NULL || c->session->curw == NULL)
			continue;
		if (c->flags & (CLIENT_SUSPENDED|CLIENT_EXIT|CLIENT_CONTROL))
			continue;
		if (~c->flags & CLIENT_FOCUSED)
			continue;
		w = c->session->curw->window;
		o = options_get_only(w->options, SET_STATUS_OPTION);
		if (o == NULL)
			continue;
		state = options_get_string(w->options, SET_STATUS_OPTION);
		if (strcmp(state, "attention") != 0)
			continue;
		options_remove_or_default(o, -1, NULL);
		server_status_window(w);
	}
}
