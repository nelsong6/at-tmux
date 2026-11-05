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
 * Rebuild saved servers (session-set snapshots) in this server, beside its own
 * sessions, and show them. The server stays free while it does: the client that
 * asked waits for the end. With no files, say how a restore is going.
 */

static enum cmd_retval	cmd_restore_set_exec(struct cmd *,
			    struct cmdq_item *);

const struct cmd_entry cmd_restore_set_entry = {
	.name = "restore-set",
	.alias = NULL,

	.args = { "d", 0, -1, NULL },
	.usage = "[-d] [file ...]",

	.flags = 0,
	.exec = cmd_restore_set_exec
};

static enum cmd_retval
cmd_restore_set_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args	*args = cmd_get_args(self);
	struct client	*tc = cmdq_get_target_client(item);
	const char	**files, *last;
	char		*status, *cause = NULL;
	u_int		 i, n = args_count(args);
	int		 failed;

	if (n == 0) {
		status = session_set_restore_status();
		last = session_set_restore_last();
		if (*status != '\0')
			cmdq_print(item, "%s", status);
		else if (last != NULL)
			cmdq_print(item, "no restore running; last %s", last);
		else
			cmdq_print(item, "no restore running");
		free(status);
		return (CMD_RETURN_NORMAL);
	}

	if (args_has(args, 'd') || tc == NULL || tc->session == NULL)
		tc = NULL;
	files = xcalloc(n, sizeof *files);
	for (i = 0; i < n; i++)
		files[i] = args_string(args, i);
	failed = session_set_restore(files, n, tc, item, &cause);
	free(files);
	if (failed != 0) {
		cmdq_error(item, "%s", cause);
		free(cause);
		return (CMD_RETURN_ERROR);
	}
	return (CMD_RETURN_WAIT);
}
