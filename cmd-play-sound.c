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

#include "tmux.h"

#ifdef _WIN32
#include <windows.h>
#include <mmsystem.h>
#else
#include <paths.h>
#include <string.h>
#include <unistd.h>
#endif

/*
 * Play a sound file from the server, without waiting for it.
 */

static enum cmd_retval	cmd_play_sound_exec(struct cmd *, struct cmdq_item *);

const struct cmd_entry cmd_play_sound_entry = {
	.name = "play-sound",
	.alias = NULL,

	.args = { "t:", 1, 1, NULL },
	.usage = CMD_TARGET_PANE_USAGE " path",

	.target = { 't', CMD_FIND_PANE, CMD_FIND_CANFAIL },

	.flags = CMD_AFTERHOOK,
	.exec = cmd_play_sound_exec
};

#ifndef _WIN32
#ifdef __APPLE__
static const char	*cmd_play_sound_players[] = { "afplay", NULL };
#else
static const char	*cmd_play_sound_players[] = { "pw-play", "paplay", "aplay", NULL };
#endif

static struct job	*cmd_play_sound_job;

static void
cmd_play_sound_complete(struct job *job)
{
	if (job == cmd_play_sound_job)
		cmd_play_sound_job = NULL;
}

/* The first player found on the global PATH, the one the job will run with. */
static const char *
cmd_play_sound_find_player(void)
{
	struct environ_entry	 *envent;
	const char		**player, *value = _PATH_DEFPATH;
	char			 *copy, *next, *dir, *path;
	int			  found;

	envent = environ_find(global_environ, "PATH");
	if (envent != NULL && envent->value != NULL)
		value = envent->value;
	for (player = cmd_play_sound_players; *player != NULL; player++) {
		next = copy = xstrdup(value);
		found = 0;
		while (!found && (dir = strsep(&next, ":")) != NULL) {
			if (*dir == '\0')
				continue;
			xasprintf(&path, "%s/%s", dir, *player);
			found = (access(path, X_OK) == 0);
			free(path);
		}
		free(copy);
		if (found)
			return (*player);
	}
	return (NULL);
}
#endif

static enum cmd_retval
cmd_play_sound_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args	*args = cmd_get_args(self);
	const char	*path = args_string(args, 0);
#ifdef _WIN32
	wchar_t		*wpath;
	int		 n, ok;
#else
	const char	*player;
	char		*argv[3];
#endif

	/* A sound for a window being looked at has nothing to tell. */
	if (args_has(args, 't') && cmdq_get_target(item)->wl != NULL &&
	    window_seen(cmdq_get_target(item)->wl->window))
		return (CMD_RETURN_NORMAL);

	if (access(path, R_OK) != 0) {
		cmdq_error(item, "can't read %s", path);
		return (CMD_RETURN_ERROR);
	}
#ifdef _WIN32
	n = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
	if (n <= 0) {
		cmdq_error(item, "bad path: %s", path);
		return (CMD_RETURN_ERROR);
	}
	wpath = xcalloc(n, sizeof *wpath);
	MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, n);
	ok = PlaySoundW(wpath, NULL, SND_FILENAME|SND_ASYNC|SND_NODEFAULT);
	free(wpath);
	if (!ok) {
		cmdq_error(item, "can't play %s", path);
		return (CMD_RETURN_ERROR);
	}
	return (CMD_RETURN_NORMAL);
#else
	if ((player = cmd_play_sound_find_player()) == NULL) {
		cmdq_error(item, "no sound player found to play %s", path);
		return (CMD_RETURN_ERROR);
	}
	if (cmd_play_sound_job != NULL) {
		job_free(cmd_play_sound_job);
		cmd_play_sound_job = NULL;
	}
	argv[0] = (char *)player;
	argv[1] = (char *)path;
	argv[2] = NULL;
	cmd_play_sound_job = job_run(NULL, 2, argv, NULL, NULL, NULL, NULL,
	    cmd_play_sound_complete, NULL, NULL, JOB_NOWAIT, -1, -1, -1, -1);
	if (cmd_play_sound_job == NULL) {
		cmdq_error(item, "can't start %s", player);
		return (CMD_RETURN_ERROR);
	}
	return (CMD_RETURN_NORMAL);
#endif
}
