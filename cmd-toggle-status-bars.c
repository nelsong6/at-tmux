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

#include "tmux.h"

static enum cmd_retval	cmd_toggle_status_bars_exec(struct cmd *,
			    struct cmdq_item *);
static enum cmd_retval	cmd_toggle_single_window_exec(struct cmd *,
			    struct cmdq_item *);

const struct cmd_entry cmd_toggle_status_bars_entry = {
	.name = "toggle-status-bars",
	.alias = NULL,

	.args = { "t:", 0, 0, NULL },
	.usage = CMD_TARGET_SESSION_USAGE,

	.target = { 't', CMD_FIND_SESSION, 0 },

	.flags = CMD_AFTERHOOK,
	.exec = cmd_toggle_status_bars_exec
};

const struct cmd_entry cmd_toggle_window_bar_entry = {
	.name = "toggle-window-bar",
	.alias = NULL,

	.args = { "t:", 0, 0, NULL },
	.usage = CMD_TARGET_SESSION_USAGE,

	.target = { 't', CMD_FIND_SESSION, 0 },

	.flags = CMD_AFTERHOOK,
	.exec = cmd_toggle_status_bars_exec
};

const struct cmd_entry cmd_toggle_session_bar_entry = {
	.name = "toggle-session-bar",
	.alias = NULL,

	.args = { "t:", 0, 0, NULL },
	.usage = CMD_TARGET_SESSION_USAGE,

	.target = { 't', CMD_FIND_SESSION, 0 },

	.flags = CMD_AFTERHOOK,
	.exec = cmd_toggle_status_bars_exec
};

const struct cmd_entry cmd_toggle_single_window_entry = {
	.name = "toggle-single-window",
	.alias = NULL,

	.args = { "", 0, 0, NULL },
	.usage = "",

	.flags = CMD_AFTERHOOK,
	.exec = cmd_toggle_single_window_exec
};

static enum cmd_retval
cmd_toggle_status_bars_exec(struct cmd *self, struct cmdq_item *item)
{
	struct session	*s = cmdq_get_target(item)->s;
	struct options	*oo = s->options;
	const char	*name, *other;
	int		 enabled;

	if (cmd_get_entry(self) == &cmd_toggle_status_bars_entry) {
		enabled = (s->statuslines == 0);
		options_set_number(oo, "status", enabled);
		if (enabled) {
			options_set_number(oo, "status-window-bar", 1);
			options_set_number(oo, "status-session-bar", 1);
		}
	} else {
		if (cmd_get_entry(self) == &cmd_toggle_window_bar_entry) {
			name = "status-window-bar";
			other = "status-session-bar";
		} else {
			name = "status-session-bar";
			other = "status-window-bar";
		}
		enabled = options_get_number(oo, "status") != 0;
		if (!enabled)
			options_set_number(oo, other, 0);
		enabled = enabled && options_get_number(oo, name);
		options_set_number(oo, name, !enabled);
		options_set_number(oo, "status", 1);
	}
	options_push_changes("status");
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_toggle_single_window_exec(__unused struct cmd *self,
    __unused struct cmdq_item *item)
{
	const char	*name = "status-single-window";

	options_set_number(global_s_options, name,
	    !options_get_number(global_s_options, name));
	options_push_changes(name);
	return (CMD_RETURN_NORMAL);
}
