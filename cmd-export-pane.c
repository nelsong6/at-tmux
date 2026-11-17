/* $OpenBSD$ */

#include <sys/types.h>

#include <stdlib.h>

#include "tmux.h"

/*
 * Hand a pane's program, console and screen to another server, which takes
 * them with split-window -M.
 */

static enum cmd_retval	cmd_export_pane_exec(struct cmd *, struct cmdq_item *);

const struct cmd_entry cmd_export_pane_entry = {
	.name = "export-pane",
	.alias = NULL,

	.args = { "p:t:", 1, 1, NULL },
	.usage = "-p server-pid " CMD_TARGET_PANE_USAGE " pane-file",

	.target = { 't', CMD_FIND_PANE, 0 },

	.flags = 0,
	.exec = cmd_export_pane_exec
};

static enum cmd_retval
cmd_export_pane_exec(struct cmd *self, struct cmdq_item *item)
{
#ifdef HAVE_SERVER_UPGRADE
	struct args		*args = cmd_get_args(self);
	struct cmd_find_state	*target = cmdq_get_target(item);
	char			*cause = NULL;
	long long		 pid;

	if (!args_has(args, 'p')) {
		cmdq_error(item, "-p names the server to hand the pane to");
		return (CMD_RETURN_ERROR);
	}
	pid = args_strtonum(args, 'p', 1, INT_MAX, &cause);
	if (cause != NULL) {
		cmdq_error(item, "server pid %s", cause);
		free(cause);
		return (CMD_RETURN_ERROR);
	}
	if (server_upgrade_export_pane(target->wp, (pid_t)pid,
	    args_string(args, 0), &cause) != 0) {
		cmdq_error(item, "%s", cause);
		free(cause);
		return (CMD_RETURN_ERROR);
	}
	return (CMD_RETURN_NORMAL);
#else
	(void)self;
	cmdq_error(item, "export-pane is only on Windows");
	return (CMD_RETURN_ERROR);
#endif
}
