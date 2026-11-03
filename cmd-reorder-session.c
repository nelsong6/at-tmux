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
#include <string.h>

#include "tmux.h"

/*
 * Move a session to another place in the sessions row.
 */

static enum cmd_retval	cmd_reorder_session_exec(struct cmd *,
			    struct cmdq_item *);

const struct cmd_entry cmd_reorder_session_entry = {
	.name = "reorder-session",
	.alias = "reorders",

	.args = { "abs:t:", 0, 1, NULL },
	.usage = "[-ab] [-s src-session] [-t dst-session] "
		 "[front|back|forward|backward]",

	.source = { 's', CMD_FIND_SESSION, 0 },
	/* -t is optional, so it is found in exec. */

	.flags = 0,
	.exec = cmd_reorder_session_exec
};

static enum cmd_retval
cmd_reorder_session_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args		*args = cmd_get_args(self);
	struct cmd_find_state	*source = cmdq_get_source(item);
	struct cmd_find_state	 target;
	struct sort_criteria	 sc = { .order = SORT_INDEX };
	struct session		*s = source->s, **sorted, **l;
	struct client		*c;
	const char		*where = args_string(args, 0);
	u_int			 n, i, from, to;

	if (args_has(args, 'a') && args_has(args, 'b')) {
		cmdq_error(item, "-a and -b cannot be used together");
		return (CMD_RETURN_ERROR);
	}
	if (where != NULL && (args_has(args, 't') || args_has(args, 'a') ||
	    args_has(args, 'b'))) {
		cmdq_error(item, "%s cannot be used with -t, -a or -b", where);
		return (CMD_RETURN_ERROR);
	}
	if (where == NULL && !args_has(args, 't')) {
		cmdq_error(item, "no place given: front, back, forward, "
		    "backward or -t");
		return (CMD_RETURN_ERROR);
	}

	/* The row without the session being moved. */
	sorted = sort_get_sessions(&n, &sc);
	l = xreallocarray(NULL, n, sizeof *l);
	from = n;
	for (i = 0; i < n; i++) {
		if (sorted[i] == s)
			from = i;
		else
			l[i - (from < i)] = sorted[i];
	}
	if (from == n)
		fatalx("session %s not in the sessions row", s->name);

	if (where != NULL) {
		if (strcmp(where, "front") == 0)
			to = 0;
		else if (strcmp(where, "back") == 0)
			to = n - 1;
		else if (strcmp(where, "forward") == 0)
			to = (from == 0) ? 0 : from - 1;
		else if (strcmp(where, "backward") == 0)
			to = (from == n - 1) ? from : from + 1;
		else {
			cmdq_error(item, "unknown place: %s", where);
			free(l);
			return (CMD_RETURN_ERROR);
		}
	} else {
		if (cmd_find_target(&target, item, args_get(args, 't'),
		    CMD_FIND_SESSION, 0) != 0) {
			free(l);
			return (CMD_RETURN_ERROR);
		}
		if (target.s == s) {
			free(l);
			return (CMD_RETURN_NORMAL);
		}
		for (to = 0; to < n - 1; to++) {
			if (l[to] == target.s)
				break;
		}
		if (args_has(args, 'a'))
			to++;
	}

	memmove(l + to + 1, l + to, (n - 1 - to) * sizeof *l);
	l[to] = s;
	for (i = 0; i < n; i++)
		l[i]->order = i;
	next_session_order = n;
	free(l);

	TAILQ_FOREACH(c, &clients, entry) {
		if (c->session != NULL)
			server_status_client(c);
	}
	return (CMD_RETURN_NORMAL);
}
