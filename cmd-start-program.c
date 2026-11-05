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

#ifdef _WIN32
#include <windows.h>
#endif

/*
 * Start a program from the server with no shell and no pane, without waiting
 * for it.
 */

static enum cmd_retval	cmd_start_program_exec(struct cmd *, struct cmdq_item *);

const struct cmd_entry cmd_start_program_entry = {
	.name = "start-program",
	.alias = NULL,

	.args = { "", 1, -1, NULL },
	.usage = "program [argument ...]",

	.flags = CMD_AFTERHOOK,
	.exec = cmd_start_program_exec
};

#ifdef _WIN32
/* The program outlives the server, so it has no console or inherited handles. */
static int
cmd_start_program_spawn(int argc, char **argv)
{
	STARTUPINFOW		 si;
	PROCESS_INFORMATION	 pi;
	wchar_t			*application, *wcmd;
	char			*cmdline;
	int			 n, ok = 0;

	cmdline = win32_argv_to_cmdline(argc, argv);
	n = MultiByteToWideChar(CP_UTF8, 0, cmdline, -1, NULL, 0);
	wcmd = xcalloc(n, sizeof *wcmd);
	MultiByteToWideChar(CP_UTF8, 0, cmdline, -1, wcmd, n);
	free(cmdline);

	if (win32_child_application(wcmd, NULL, &application)) {
		memset(&si, 0, sizeof si);
		si.cb = sizeof si;
		AllowSetForegroundWindow(ASFW_ANY);
		ok = CreateProcessW(application, wcmd, NULL, NULL, FALSE,
		    DETACHED_PROCESS, NULL, NULL, &si, &pi);
		if (ok) {
			CloseHandle(pi.hThread);
			CloseHandle(pi.hProcess);
		}
		free(application);
	}
	free(wcmd);
	return (ok);
}
#else
static int
cmd_start_program_spawn(int argc, char **argv)
{
	return (job_run(NULL, argc, argv, NULL, NULL, NULL, NULL, NULL, NULL,
	    NULL, JOB_NOWAIT, -1, -1, -1, -1) != NULL);
}
#endif

static enum cmd_retval
cmd_start_program_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args	*args = cmd_get_args(self);
	char		**argv;
	int		  argc, ok;

	args_to_vector(args, &argc, &argv);
	ok = cmd_start_program_spawn(argc, argv);
	cmd_free_argv(argc, argv);
	if (!ok) {
		cmdq_error(item, "can't start %s", args_string(args, 0));
		return (CMD_RETURN_ERROR);
	}
	return (CMD_RETURN_NORMAL);
}
