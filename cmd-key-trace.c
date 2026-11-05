/*
 * Copyright (c) 2026 Nelson Romaine
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

/*
 * Show how recent keys travelled to their pane, or record a press as the
 * keyboard hook would, which is how a test or a person checks the path with
 * no key pressed.
 */

static enum cmd_retval	cmd_key_trace_exec(struct cmd *, struct cmdq_item *);

const struct cmd_entry cmd_key_trace_entry = {
	.name = "key-trace",
	.alias = NULL,

	.args = { "p", 0, 0, NULL },
	.usage = "[-p]",

	.flags = CMD_AFTERHOOK,
	.exec = cmd_key_trace_exec
};

static enum cmd_retval
cmd_key_trace_exec(struct cmd *self, struct cmdq_item *item)
{
	if (args_has(cmd_get_args(self), 'p'))
		key_trace_pressed(get_timer(), -1);
	else
		key_trace_print(item);
	return (CMD_RETURN_NORMAL);
}
