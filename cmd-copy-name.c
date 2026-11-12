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
 * Copy a window's or a session's name to the client's clipboard, as copy mode
 * copies a selection: a new paste buffer and the terminal's clipboard.
 */

static enum cmd_retval	cmd_copy_name_exec(struct cmd *, struct cmdq_item *);

const struct cmd_entry cmd_copy_window_name_entry = {
	.name = "copy-window-name-to-clipboard",
	.alias = NULL,

	.args = { "c:t:", 0, 0, NULL },
	.usage = CMD_TARGET_CLIENT_USAGE " " CMD_TARGET_WINDOW_USAGE,

	.target = { 't', CMD_FIND_WINDOW, 0 },

	.flags = CMD_AFTERHOOK|CMD_CLIENT_CFLAG,
	.exec = cmd_copy_name_exec
};

const struct cmd_entry cmd_copy_session_name_entry = {
	.name = "copy-session-name-to-clipboard",
	.alias = NULL,

	.args = { "c:t:", 0, 0, NULL },
	.usage = CMD_TARGET_CLIENT_USAGE " " CMD_TARGET_SESSION_USAGE,

	.target = { 't', CMD_FIND_SESSION, 0 },

	.flags = CMD_AFTERHOOK|CMD_CLIENT_CFLAG,
	.exec = cmd_copy_name_exec
};

static enum cmd_retval
cmd_copy_name_exec(struct cmd *self, struct cmdq_item *item)
{
	struct cmd_find_state	*target = cmdq_get_target(item);
	struct client		*tc = cmdq_get_target_client(item);
	const char		*name;
	char			*data, *cause;
	size_t			 size;

	if (cmd_get_entry(self) == &cmd_copy_window_name_entry)
		name = target->wl->window->name;
	else
		name = target->s->name;
	if ((size = strlen(name)) == 0) {
		cmdq_error(item, "no name to copy");
		return (CMD_RETURN_ERROR);
	}

	if ((tc->flags & CLIENT_CONTROL) ||
	    (~tc->tty.flags & TTY_STARTED) ||
	    !tty_term_has(tc->tty.term, TTYC_MS)) {
		cmdq_error(item, "%s's terminal has no clipboard", tc->name);
		return (CMD_RETURN_ERROR);
	}

	data = xstrdup(name);
	if (paste_set(data, size, NULL, &cause) != 0) {
		cmdq_error(item, "%s", cause);
		free(cause);
		free(data);
		return (CMD_RETURN_ERROR);
	}
	tty_set_selection(&tc->tty, "", name, size);

	return (CMD_RETURN_NORMAL);
}
