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

	.args = { "K:", 1, -1, NULL },
	.usage = "[-K key] program [argument ...]",

	.flags = CMD_AFTERHOOK,
	.exec = cmd_start_program_exec
};

#ifdef _WIN32
/*
 * The program outlives the server, so it has no console or inherited handles.
 * Its environment is the one job_run gives a program with no session, as on
 * other platforms: the global environment, so its PATH, not the server
 * process's (fixed when the server started and carried over by upgrade-server),
 * finds an unqualified program, and a folder home-sync puts on PATH later is
 * seen without a new server.
 */
static int
cmd_start_program_spawn(int argc, char **argv)
{
	STARTUPINFOW		 si;
	PROCESS_INFORMATION	 pi;
	struct environ		*env;
	wchar_t			*application, *wcmd;
	char			*cmdline, *envblock;
	int			 n, ok = 0;

	cmdline = win32_argv_to_cmdline(argc, argv);
	n = MultiByteToWideChar(CP_UTF8, 0, cmdline, -1, NULL, 0);
	wcmd = xcalloc(n, sizeof *wcmd);
	MultiByteToWideChar(CP_UTF8, 0, cmdline, -1, wcmd, n);
	free(cmdline);

	env = environ_for_session(NULL, !cfg_finished);
	envblock = environ_to_win32_block(env);
	environ_free(env);

	if (win32_child_application(wcmd, envblock, &application)) {
		memset(&si, 0, sizeof si);
		si.cb = sizeof si;
		AllowSetForegroundWindow(ASFW_ANY);
		ok = CreateProcessW(application, wcmd, NULL, NULL, FALSE,
		    DETACHED_PROCESS|CREATE_UNICODE_ENVIRONMENT, envblock, NULL,
		    &si, &pi);
		if (ok) {
			CloseHandle(pi.hThread);
			CloseHandle(pi.hProcess);
		}
		free(application);
	}
	free(envblock);
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
	key_code	  key = KEYC_NONE;
	const char	 *keyname = args_get(args, 'K');

	if (keyname != NULL) {
		key = key_string_lookup_string(keyname);
		if (key == KEYC_NONE || key == KEYC_UNKNOWN) {
			cmdq_error(item, "unknown key: %s", keyname);
			return (CMD_RETURN_ERROR);
		}
	}

	args_to_vector(args, &argc, &argv);
	ok = cmd_start_program_spawn(argc, argv);
	cmd_free_argv(argc, argv);
	if (!ok) {
		cmdq_error(item, "can't start %s", args_string(args, 0));
		return (CMD_RETURN_ERROR);
	}
	if (key != KEYC_NONE)
		options_set_string(global_s_options, "@start-program-key", 0,
		    "%s", keyname);
	return (CMD_RETURN_NORMAL);
}
