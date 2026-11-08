/* $OpenBSD$ */

/*
 * Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
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

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <unistd.h>
#endif

#include "tmux.h"

/*
 * Create a new window.
 */

#define NEW_WINDOW_TEMPLATE "#{session_name}:#{window_index}.#{pane_index}"

static enum cmd_retval	cmd_new_window_exec(struct cmd *, struct cmdq_item *);

const struct cmd_entry cmd_new_window_entry = {
	.name = "new-window",
	.alias = "neww",

	.args = { "abc:de:F:kM:n:o:PRSt:W:", 0, -1, NULL },
	.usage = "[-abdkPRS] [-c start-directory] [-e environment] [-F format] "
		 "[-M app-name] [-n window-name] [-o option=value] "
		 CMD_TARGET_WINDOW_USAGE
		 " [-W target-client] [shell-command [argument ...]]",

	.target = { 't', CMD_FIND_WINDOW, CMD_FIND_WINDOW_INDEX },

	.flags = CMD_WAITS_RESTORE,
	.exec = cmd_new_window_exec
};

/*
 * new-window -W: the window opens in the background and a client is switched
 * to it once its pane has drawn something, so the client never shows a blank
 * pane while the program starts. The command waits until then. A pane that
 * exits or is closed first fails the command and switches nothing; the
 * waiting command's client going away drops the wait. Nothing is kept once it
 * ends, and upgrade-server waits while one is pending.
 */
struct new_window_draw {
	struct cmdq_item		*item;
	struct window_pane		*wp;
	struct client			*tc;	/* referenced */
	u_int				 session;

	TAILQ_ENTRY(new_window_draw)	 entry;
};
static TAILQ_HEAD(, new_window_draw) new_window_draws =
    TAILQ_HEAD_INITIALIZER(new_window_draws);

/*
 * Has the pane drawn anything? Its visible screen has a cell that isn't a
 * space. A new console's own setup (clearing the screen, a title, moving the
 * cursor) leaves it blank.
 */
static int
new_window_drawn(struct window_pane *wp)
{
	struct grid		*gd = wp->base.grid;
	const struct grid_line	*gl;
	struct grid_cell	 gc;
	u_int			 x, y;

	for (y = gd->hsize; y < gd->hsize + gd->sy; y++) {
		gl = grid_peek_line(gd, y);
		for (x = 0; x < gl->cellused; x++) {
			grid_get_cell(gd, x, y, &gc);
			if (gc.flags & GRID_FLAG_PADDING)
				continue;
			if (gc.data.size != 1 || *gc.data.data != ' ')
				return (1);
		}
	}
	return (0);
}

static void
new_window_switch(struct client *tc, struct session *s, struct winlink *wl)
{
	session_set_current(s, wl);
	environ_update(s->options, tc->environ, s->environ);
	server_client_set_session(tc, s);
}

static void
new_window_draw_free(struct new_window_draw *nwd)
{
	nwd->wp->draw_wait = NULL;
	TAILQ_REMOVE(&new_window_draws, nwd, entry);
	server_client_unref(nwd->tc);
	free(nwd);
}

/* After a pane's output is parsed: switch the client if it has drawn. */
void
new_window_draw_check(struct window_pane *wp)
{
	struct new_window_draw	*nwd = wp->draw_wait;
	struct cmdq_item	*item;
	struct session		*s;
	struct winlink		*wl = NULL;

	if (nwd == NULL || !new_window_drawn(wp))
		return;
	item = nwd->item;

	if ((s = session_find_by_id(nwd->session)) != NULL)
		wl = winlink_find_by_window(&s->windows, wp->window);
	if (wl == NULL)
		cmdq_error(item, "window @%u left its session", wp->window->id);
	else if (nwd->tc->flags & CLIENT_DEAD)
		cmdq_error(item, "client %s has gone", nwd->tc->name);
	else
		new_window_switch(nwd->tc, s, wl);
	log_debug("%s: %%%u drew", __func__, wp->id);

	new_window_draw_free(nwd);
	cmdq_continue(item);
}

/* The pane is going before it drew: fail the command. */
void
new_window_draw_end(struct window_pane *wp, const char *why)
{
	struct new_window_draw	*nwd = wp->draw_wait;
	struct cmdq_item	*item;

	if (nwd == NULL)
		return;
	item = nwd->item;
	log_debug("%s: %%%u %s", __func__, wp->id, why);
	cmdq_error(item, "pane %%%u %s", wp->id, why);
	new_window_draw_free(nwd);
	cmdq_continue(item);
}

/*
 * A client has gone: a wait it was running is given up, and one that would
 * switch it fails.
 */
void
new_window_draw_client_lost(struct client *c)
{
	struct new_window_draw	*nwd, *nwd1;
	struct cmdq_item	*item;

	TAILQ_FOREACH_SAFE(nwd, &new_window_draws, entry, nwd1) {
		item = nwd->item;
		if (cmdq_get_client(item) == c) {
			log_debug("%s: %%%u given up", __func__, nwd->wp->id);
			new_window_draw_free(nwd);
			cmdq_continue(item);
		} else if (nwd->tc == c) {
			cmdq_error(item, "client %s has gone", c->name);
			new_window_draw_free(nwd);
			cmdq_continue(item);
		}
	}
}

/*
 * new-window -o name=value: a window option set on the new window as it is
 * made, before the event loop can see its program end, so remain-on-exit
 * holds even for a program that fails at once (FZT-71, TMUX-52). Every -o is
 * checked before the window is made, on options that are thrown away.
 */
static int
cmd_new_window_options(struct args *args, struct options *oo, char **cause)
{
	struct args_value			*av;
	struct options_entry			*o;
	const struct options_table_entry	*oe;
	char					*name, *value;
	int					 error = 0;

	for (av = args_first_value(args, 'o'); av != NULL;
	    av = args_next_value(av)) {
		name = xstrdup(av->string);
		if ((value = strchr(name, '=')) == NULL) {
			xasprintf(cause, "-o needs name=value: %s", av->string);
			error = -1;
		} else {
			*value++ = '\0';
			if (*name == '@')
				options_set_string(oo, name, 0, "%s", value);
			else if ((o = options_get(global_w_options, name)) == NULL ||
			    (oe = options_table_entry(o)) == NULL ||
			    (~oe->scope & OPTIONS_TABLE_WINDOW)) {
				xasprintf(cause, "not a window option: %s", name);
				error = -1;
			} else
				error = options_from_string(oo, oe, oe->name,
				    value, 0, cause);
		}
		free(name);
		if (error != 0)
			return (-1);
	}
	return (0);
}

/*
 * An -o option given to a window -M found reaches its panes: a pane's own
 * value would win over it (a restore leaves a program's first pane its own
 * remain-on-exit failed), so it goes.
 */
static void
cmd_new_window_clear_panes(struct args *args, struct window *w)
{
	struct args_value	*av;
	struct window_pane	*wp;
	struct options_entry	*o;
	char			*name;

	for (av = args_first_value(args, 'o'); av != NULL;
	    av = args_next_value(av)) {
		name = xstrndup(av->string, strcspn(av->string, "="));
		TAILQ_FOREACH(wp, &w->panes, entry) {
			if ((o = options_get_only(wp->options, name)) != NULL)
				options_remove_or_default(o, -1, NULL);
		}
		free(name);
	}
}

/* The client waits for wp to draw, then switches to it (-W). */
static void
cmd_new_window_wait(struct cmdq_item *item, struct window_pane *wp,
    struct client *wc, struct session *s)
{
	struct new_window_draw	*nwd;

	nwd = xcalloc(1, sizeof *nwd);
	nwd->item = item;
	nwd->wp = wp;
	nwd->tc = wc;
	wc->references++;
	nwd->session = s->id;
	TAILQ_INSERT_TAIL(&new_window_draws, nwd, entry);
	wp->draw_wait = nwd;
}

/* A program's name: the last part of its path, less .exe on Windows. */
static char *
cmd_new_window_program_name(const char *path)
{
	const char	*cp;
	char		*name;
#ifdef _WIN32
	size_t		 len;
#endif

	if ((cp = strrchr(path, '/')) != NULL)
		path = cp + 1;
#ifdef _WIN32
	if ((cp = strrchr(path, '\\')) != NULL)
		path = cp + 1;
#endif
	name = xstrdup(path);
#ifdef _WIN32
	len = strlen(name);
	if (len > 4 && strcasecmp(name + len - 4, ".exe") == 0)
		name[len - 4] = '\0';
#endif
	return (name);
}

/* Does w carry any app's mark, an @<name>-window option? */
static int
cmd_new_window_marked(struct window *w)
{
	struct options_entry	*o;
	const char		*name;
	size_t			 len;

	for (o = options_first(w->options); o != NULL; o = options_next(o)) {
		name = options_name(o);
		len = strlen(name);
		if (*name == '@' && len > 7 &&
		    strcmp(name + len - 7, "-window") == 0)
			return (1);
	}
	return (0);
}

/*
 * Is w an app's window with no mark: one pane, started as this same command
 * (the program by its name wherever it was found, then the same arguments)?
 */
static int
cmd_new_window_runs(struct window *w, int argc, char **argv)
{
	struct window_pane	*wp = TAILQ_FIRST(&w->panes);
	char			*a, *b;
	int			 i, same;

	if (wp == NULL || window_count_panes(w) != 1 || wp->argc != argc ||
	    argc == 0 || cmd_new_window_marked(w))
		return (0);
	for (i = 1; i < argc; i++) {
		if (strcmp(wp->argv[i], argv[i]) != 0)
			return (0);
	}
	a = cmd_new_window_program_name(wp->argv[0]);
	b = cmd_new_window_program_name(argv[0]);
#ifdef _WIN32
	same = (strcasecmp(a, b) == 0);
#else
	same = (strcmp(a, b) == 0);
#endif
	free(a);
	free(b);
	return (same);
}

/*
 * new-window -M: the app's window, in any session. The one marked
 * @<name>-window first, else an unmarked window of one pane started as its
 * command.
 */
static struct winlink *
cmd_new_window_find_app(const char *mark, int argc, char **argv,
    struct session **sp)
{
	struct session	*s, *by_s = NULL;
	struct winlink	*wl, *by_program = NULL;

	RB_FOREACH(s, sessions, &sessions) {
		RB_FOREACH(wl, winlinks, &s->windows) {
			if (options_get_only(wl->window->options, mark) != NULL &&
			    format_true(options_get_string(wl->window->options,
			    mark))) {
				*sp = s;
				return (wl);
			}
			if (by_program == NULL &&
			    cmd_new_window_runs(wl->window, argc, argv)) {
				by_program = wl;
				by_s = s;
			}
		}
	}
	*sp = by_s;
	return (by_program);
}

/*
 * new-window -M found the app's window wl in app_s: bring it into s, give it
 * its mark and the -o options, start its dead panes' programs again, and show
 * it as a new window would be shown.
 */
static enum cmd_retval
cmd_new_window_app(struct cmdq_item *item, struct args *args,
    struct winlink *wl, struct session *app_s, struct session *s, int idx,
    const char *mark, struct client *wc, struct client *c, struct client *tc)
{
	struct window		*w = wl->window;
	struct window_pane	*wp, *relaunched = NULL;
	char			*cause = NULL, *cp;
	const char		*template;
	int			 failed = 0;

	if (app_s != s) {
		w->references++;
		if (server_link_window(app_s, wl, s, idx, 0, 0, &cause) != 0) {
			window_remove_ref(w, __func__);
			cmdq_error(item, "%s", cause);
			free(cause);
			return (CMD_RETURN_ERROR);
		}
		server_unlink_window(app_s, wl);
		wl = winlink_find_by_window(&s->windows, w);
		window_remove_ref(w, __func__);
		if (session_alive(app_s) &&
		    options_get_number(app_s->options, "renumber-windows"))
			session_renumber_windows(app_s);
		recalculate_sizes();
	}
	/* Checked before the window was looked for, so this can't fail. */
	cmd_new_window_options(args, w->options, &cause);
	cmd_new_window_clear_panes(args, w);
	options_set_string(w->options, mark, 0, "1");

	TAILQ_FOREACH(wp, &w->panes, entry) {
		if (wp->fd != -1)
			continue;
		if (spawn_relaunch(item, s, wl, wp, &cause) != 0) {
			cmdq_error(item, "relaunch failed: %s", cause);
			free(cause);
			cause = NULL;
			failed = 1;
		} else if (wp == w->active)
			relaunched = wp;
	}

	if (args_has(args, 'P')) {
		if ((template = args_get(args, 'F')) == NULL)
			template = NEW_WINDOW_TEMPLATE;
		cp = format_single(item, template, tc, s, wl, w->active);
		cmdq_print(item, "%s", cp);
		free(cp);
	}

	if (wc != NULL) {
		if (relaunched != NULL && relaunched->draw_wait == NULL) {
			cmd_new_window_wait(item, relaunched, wc, s);
			return (CMD_RETURN_WAIT);
		}
		new_window_switch(wc, s, wl);
	} else if (!args_has(args, 'd')) {
		if (session_set_current(s, wl) == 0)
			server_redraw_session(s);
		if (c != NULL && c->session != NULL)
			w->latest = c;
		recalculate_sizes();
	} else
		server_status_session_group(s);
	return (failed ? CMD_RETURN_ERROR : CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_new_window_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args		*args = cmd_get_args(self);
	struct client		*c = cmdq_get_client(item);
	struct cmd_find_state	*current = cmdq_get_current(item);
	struct cmd_find_state	*target = cmdq_get_target(item);
	struct spawn_context	 sc = { 0 };
	struct client		*tc = cmdq_get_target_client(item);
	struct session		*s = target->s;
	struct winlink		*wl = target->wl, *new_wl = NULL;
	int			 idx = target->idx, before;
	char			*cause = NULL, *cp, *expanded;
	const char		*template, *name;
	struct cmd_find_state	 fs;
	struct args_value	*av;
	struct client		*wc = NULL;
	int			 detached, argc;
	const char		*app = NULL;
	char			*mark = NULL, **argv = NULL;
	struct session		*app_s;
	enum cmd_retval		 retval;

	if (args_has(args, 'W')) {
		wc = cmd_find_client(item, args_get(args, 'W'), 0);
		if (wc == NULL)
			return (CMD_RETURN_ERROR);
		if (wc->session == NULL) {
			cmdq_error(item, "client %s is not attached", wc->name);
			return (CMD_RETURN_ERROR);
		}
	}
	detached = args_has(args, 'd') || wc != NULL;

	if (args_has(args, 'o')) {
		struct options	*check = options_create(global_w_options);
		int		 bad = cmd_new_window_options(args, check, &cause);

		options_free(check);
		if (bad) {
			cmdq_error(item, "%s", cause);
			free(cause);
			return (CMD_RETURN_ERROR);
		}
	}

	/*
	 * -M name: an app with one place (TMUX-167). Its window, found in any
	 * session, moves into the target session, gets the -o options, has a
	 * dead pane's program started again and is selected; only with none is
	 * a window made, marked @<name>-window and named for the app.
	 */
	if ((app = args_get(args, 'M')) != NULL) {
		if (*app == '\0' || app[strcspn(app, "=:. \t")] != '\0') {
			cmdq_error(item, "bad app name: %s", app);
			return (CMD_RETURN_ERROR);
		}
		xasprintf(&mark, "@%s-window", app);
		args_to_vector(args, &argc, &argv);
		wl = cmd_new_window_find_app(mark, argc, argv, &app_s);
		if (argv != NULL)
			cmd_free_argv(argc, argv);
		if (wl != NULL) {
			/* Moved in, it takes its place as a new window would. */
			before = args_has(args, 'b');
			if (app_s != s && (args_has(args, 'a') || before)) {
				idx = winlink_shuffle_up(s, target->wl, before);
				if (idx == -1)
					idx = target->idx;
			}
			retval = cmd_new_window_app(item, args, wl, app_s, s,
			    idx, mark, wc, c, tc);
			free(mark);
			return (retval);
		}
		wl = target->wl;
	}

	/*
	 * If -S and -n are given and -t is not and a single window with this
	 * name already exists, select it.
	 */
	name = args_get(args, 'n');
	if (args_has(args, 'S') && name != NULL && target->idx == -1) {
		expanded = format_single(item, name, c, s, NULL, NULL);
		RB_FOREACH(wl, winlinks, &s->windows) {
			if (strcmp(wl->window->name, expanded) != 0)
				continue;
			if (new_wl == NULL) {
				new_wl = wl;
				continue;
			}
			cmdq_error(item, "multiple windows named %s", name);
			free(expanded);
			return (CMD_RETURN_ERROR);
		}
		free(expanded);
		if (new_wl != NULL) {
			if (wc != NULL) {
				new_window_switch(wc, s, new_wl);
				return (CMD_RETURN_NORMAL);
			}
			if (args_has(args, 'd'))
				return (CMD_RETURN_NORMAL);
			if (session_set_current(s, new_wl) == 0)
				server_redraw_session(s);
			if (c != NULL && c->session != NULL)
				s->curw->window->latest = c;
			recalculate_sizes();
			return (CMD_RETURN_NORMAL);
		}
	}

	before = args_has(args, 'b');
	if (args_has(args, 'a') || before) {
		idx = winlink_shuffle_up(s, wl, before);
		if (idx == -1)
			idx = target->idx;
	}

	sc.item = item;
	sc.s = s;
	sc.tc = tc;

	sc.name = args_get(args, 'n');
	if (sc.name == NULL)
		sc.name = app;
	args_to_vector(args, &sc.argc, &sc.argv);
	sc.environ = environ_create();

	av = args_first_value(args, 'e');
	while (av != NULL) {
		environ_put(sc.environ, av->string, 0);
		av = args_next_value(av);
	}

	sc.idx = idx;
	sc.cwd = args_get(args, 'c');

	sc.flags = 0;
	if (detached)
		sc.flags |= SPAWN_DETACHED;
	if (args_has(args, 'k'))
		sc.flags |= SPAWN_KILL;
	if (args_has(args, 'R'))
		sc.flags |= SPAWN_SHELLFALLBACK;

	if ((new_wl = spawn_window(&sc, &cause)) == NULL) {
		cmdq_error(item, "create window failed: %s", cause);
		free(cause);
		free(mark);
		if (sc.argv != NULL)
			cmd_free_argv(sc.argc, sc.argv);
		environ_free(sc.environ);
		return (CMD_RETURN_ERROR);
	}
	/* Checked above, so this can't fail. */
	cmd_new_window_options(args, new_wl->window->options, &cause);
	if (mark != NULL) {
		options_set_string(new_wl->window->options, mark, 0, "1");
		free(mark);
	}
	if (!detached || new_wl == s->curw) {
		cmd_find_from_winlink(current, new_wl, 0);
		server_redraw_session_group(s);
	} else
		server_status_session_group(s);

	if (args_has(args, 'P')) {
		if ((template = args_get(args, 'F')) == NULL)
			template = NEW_WINDOW_TEMPLATE;
		cp = format_single(item, template, tc, s, new_wl,
			new_wl->window->active);
		cmdq_print(item, "%s", cp);
		free(cp);
	}

	cmd_find_from_winlink(&fs, new_wl, 0);
	cmdq_insert_hook(s, item, &fs, "after-new-window");

	if (sc.argv != NULL)
		cmd_free_argv(sc.argc, sc.argv);
	environ_free(sc.environ);

	if (wc != NULL) {
		cmd_new_window_wait(item, new_wl->window->active, wc, s);
		return (CMD_RETURN_WAIT);
	}
	return (CMD_RETURN_NORMAL);
}
