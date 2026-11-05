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

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "tmux.h"

/*
 * Follow each key from the keyboard to the pane, by time only: which key it
 * was is never kept. A press comes from the desktop keyboard hook, so a key the
 * terminal never handed over is seen as well as one tmux lost.
 *
 * The timer runs only while a key is unaccounted for, and is one second from
 * the news that started it.
 */

#define KEY_TRACE_ENTRIES 128
#define KEY_TRACE_WAIT 1000
#define KEY_TRACE_TOLD 2

struct key_trace_entry {
	uint64_t	 pressed;
	uint64_t	 arrived;
	uint64_t	 read;
	const char	*where;
	int		 pane;
};

static struct key_trace_entry	 key_trace_entries[KEY_TRACE_ENTRIES];
static u_int			 key_trace_next;
static u_int			 key_trace_unread;
static struct key_trace_entry	*key_trace_current;
static struct event		 key_trace_timer;

static u_int			 key_trace_missed;
static uint64_t			 key_trace_missed_since;
static int			 key_trace_late;

static int			 key_trace_watching;
static u_int			 key_trace_watch;
static size_t			 key_trace_queued;
static uint64_t			 key_trace_stuck;

static struct key_trace_entry *
key_trace_entry(u_int n)
{
	return (&key_trace_entries[n % KEY_TRACE_ENTRIES]);
}

static void printflike(1, 2)
key_trace_report(const char *fmt, ...)
{
	va_list	 ap;
	char	*s;

	va_start(ap, fmt);
	xvasprintf(&s, fmt, ap);
	va_end(ap);

	server_add_message("key trace: %s", s);
	flight_note("key trace: %s", s);
	log_message(s);
	free(s);
}

static void	key_trace_callback(int, short, void *);

static void
key_trace_arm(void)
{
	struct timeval	tv = { .tv_sec = KEY_TRACE_WAIT / 1000 };

	if (!evtimer_initialized(&key_trace_timer))
		evtimer_set(&key_trace_timer, key_trace_callback, NULL);
	if (!evtimer_pending(&key_trace_timer, NULL))
		evtimer_add(&key_trace_timer, &tv);
}

/* Was the terminal of the client keys go to in front when the key went down? */
static int
key_trace_for_client(pid_t foreground)
{
#ifdef _WIN32
	static pid_t	 last_foreground, last_client;
	static int	 last;
	struct client	*c;

	if (foreground == -1)
		return (1);
	if ((c = cmd_find_best_client(NULL)) == NULL)
		return (0);
	if (foreground != last_foreground || c->pid != last_client) {
		last_foreground = foreground;
		last_client = c->pid;
		last = win32_pid_descends(c->pid, foreground);
	}
	return (last);
#else
	return (foreground == -1);
#endif
}

/* A key went down at a time from get_timer. A foreground of -1 is always ours. */
void
key_trace_pressed(uint64_t at, pid_t foreground)
{
	struct key_trace_entry	*e;
	uint64_t		 now = get_timer();

	if (!key_trace_for_client(foreground))
		return;

	if (now - at < KEY_TRACE_WAIT)
		key_trace_late = 0;
	else if (!key_trace_late) {
		key_trace_late = 1;
		key_trace_report("the server took %llu ms to see a key",
		    (unsigned long long)(now - at));
	}

	e = key_trace_entry(key_trace_next++);
	memset(e, 0, sizeof *e);
	e->pressed = at;
	e->arrived = now;
	e->pane = -1;
	if (key_trace_next - key_trace_unread > KEY_TRACE_ENTRIES)
		key_trace_unread = key_trace_next - KEY_TRACE_ENTRIES;
	key_trace_arm();
}

/* A key arrived from a client. The oldest press still waiting is this one. */
void
key_trace_read(key_code key)
{
	struct key_trace_entry	*e;
	uint64_t		 now = get_timer();
	key_code		 base = key & KEYC_MASK_KEY;

	key_trace_current = NULL;
	if (KEYC_IS_MOUSE(key) || base == KEYC_FOCUS_IN ||
	    base == KEYC_FOCUS_OUT || base == KEYC_PASTE_START ||
	    base == KEYC_PASTE_END || base == KEYC_REPORT_LIGHT_THEME ||
	    base == KEYC_REPORT_DARK_THEME)
		return;

	if (key_trace_missed >= KEY_TRACE_TOLD) {
		key_trace_report("keys reach tmux again after %llu ms, "
		    "%u unanswered",
		    (unsigned long long)(now - key_trace_missed_since),
		    key_trace_missed);
	}
	key_trace_missed = 0;

	if (key_trace_unread != key_trace_next) {
		e = key_trace_entry(key_trace_unread++);
		e->read = now;
		key_trace_current = e;
	}
}

/* The key just read stopped short of a pane, at where. */
void
key_trace_took(const char *where)
{
	if (key_trace_current != NULL) {
		key_trace_current->where = where;
		key_trace_current = NULL;
	}
}

/* The key just read was queued for a pane. */
void
key_trace_sent(struct window_pane *wp)
{
	if (key_trace_current != NULL) {
		key_trace_current->where = "pane";
		key_trace_current->pane = wp->id;
		key_trace_current = NULL;
	}
	if (key_trace_stuck == 0) {
		key_trace_watching = 1;
		key_trace_watch = wp->id;
		key_trace_queued = 0;
	}
	key_trace_arm();
}

static void
key_trace_check_pane(uint64_t now)
{
	struct window_pane	*wp;
	size_t			 queued = 0;
	uint64_t		 blocked = 0;

	wp = window_pane_find_by_id(key_trace_watch);
	if (wp == NULL || wp->event == NULL) {
		key_trace_watching = 0;
		key_trace_stuck = 0;
		return;
	}
	queued = EVBUFFER_LENGTH(wp->event->output);
#ifdef _WIN32
	blocked = win32_pty_input_blocked(wp->win32_pty);
#endif

	if (blocked >= KEY_TRACE_WAIT || (queued != 0 && key_trace_queued != 0)) {
		if (key_trace_stuck == 0) {
			key_trace_stuck = now - blocked;
			key_trace_report("keys are stuck going into pane %%%u "
			    "(%s): %zu bytes queued, console write blocked "
			    "%llu ms", wp->id, wp->window->name, queued,
			    (unsigned long long)blocked);
		}
	} else {
		if (key_trace_stuck != 0) {
			key_trace_report("keys reach pane %%%u again after "
			    "%llu ms", wp->id,
			    (unsigned long long)(now - key_trace_stuck));
			key_trace_stuck = 0;
		}
		if (queued == 0)
			key_trace_watching = 0;
	}
	key_trace_queued = queued;
}

static void
key_trace_callback(__unused int fd, __unused short events, __unused void *arg)
{
	struct key_trace_entry	*e;
	uint64_t		 now = get_timer();

	while (key_trace_unread != key_trace_next) {
		e = key_trace_entry(key_trace_unread);
		if (now - e->pressed < KEY_TRACE_WAIT)
			break;
		if (key_trace_missed++ == 0)
			key_trace_missed_since = e->pressed;
		key_trace_unread++;
		if (key_trace_missed == KEY_TRACE_TOLD) {
			key_trace_report("keys pressed in the terminal are not "
			    "reaching tmux: nothing for %llu ms",
			    (unsigned long long)(now - key_trace_missed_since));
		}
	}

	if (key_trace_watching)
		key_trace_check_pane(now);

	if (key_trace_watching || key_trace_unread != key_trace_next)
		key_trace_arm();
}

/* Print the keys kept, oldest first, and anything still unaccounted for. */
void
key_trace_print(struct cmdq_item *item)
{
	struct key_trace_entry	*e;
	uint64_t		 now = get_timer();
	u_int			 n, first = 0;
	char			 taken[32];

	if (key_trace_next > KEY_TRACE_ENTRIES)
		first = key_trace_next - KEY_TRACE_ENTRIES;
	for (n = first; n != key_trace_next; n++) {
		e = key_trace_entry(n);
		if (e->pane != -1)
			xsnprintf(taken, sizeof taken, "pane %%%d", e->pane);
		else if (e->where != NULL)
			xsnprintf(taken, sizeof taken, "%s", e->where);
		else
			xsnprintf(taken, sizeof taken, "-");
		if (e->read != 0) {
			cmdq_print(item, "%llu.%llus ago: seen +%llums, read "
			    "+%llums, went to %s",
			    (unsigned long long)((now - e->pressed) / 1000),
			    (unsigned long long)((now - e->pressed) % 1000 / 100),
			    (unsigned long long)(e->arrived - e->pressed),
			    (unsigned long long)(e->read - e->pressed), taken);
		} else {
			cmdq_print(item, "%llu.%llus ago: seen +%llums, never "
			    "read",
			    (unsigned long long)((now - e->pressed) / 1000),
			    (unsigned long long)((now - e->pressed) % 1000 / 100),
			    (unsigned long long)(e->arrived - e->pressed));
		}
	}
	if (key_trace_missed != 0)
		cmdq_print(item, "unanswered: %u", key_trace_missed);
	if (key_trace_stuck != 0)
		cmdq_print(item, "stuck: pane %%%u", key_trace_watch);
}
