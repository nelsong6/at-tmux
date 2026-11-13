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
#include <sys/stat.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <direct.h>
#endif

#include "tmux.h"

/*
 * record-output: every byte the server sends a client's terminal, written to
 * <socket name>.out in ~/.tmux/output (or TMUX_OUTPUT_DIR) as it leaves, so a
 * screen that went wrong can be replayed. Each frame is a header line, then
 * for a W frame its bytes and a newline:
 *
 *	W <unix ms> <client> <width>x<height> <length>	sent to the terminal
 *	D <unix ms> <client> <width>x<height> <length>	thrown away unsent
 *
 * A file that would pass record-output-limit becomes <name>.out.1, replacing
 * the one before, so at most two files exist. Turning the option off, or a
 * new server of the same name starting, deletes both; upgrade-server carries
 * the option, and the new process appends.
 */

static FILE	*tty_record_file;
static char	*tty_record_path;
static off_t	 tty_record_size;
static int	 tty_record_failed;

static char *
tty_record_previous(void)
{
	char	*previous;

	xasprintf(&previous, "%s.1", tty_record_path);
	return (previous);
}

/* Find the recording's path, making its directory. */
static int
tty_record_find_path(void)
{
	const char	*dir, *home, *name, *slash;
	char		*owned = NULL;

	if (tty_record_path != NULL)
		return (0);

	dir = getenv("TMUX_OUTPUT_DIR");
	if (dir == NULL || *dir == '\0') {
		if ((home = find_home()) == NULL)
			return (-1);
		xasprintf(&owned, "%s/.tmux", home);
#ifdef _WIN32
		_mkdir(owned);
#else
		mkdir(owned, S_IRWXU);
#endif
		free(owned);
		xasprintf(&owned, "%s/.tmux/output", home);
		dir = owned;
	}
#ifdef _WIN32
	_mkdir(dir);
#else
	mkdir(dir, S_IRWXU);
#endif

	name = socket_path;
	if ((slash = strrchr(name, '/')) != NULL)
		name = slash + 1;
	if ((slash = strrchr(name, '\\')) != NULL)
		name = slash + 1;
	xasprintf(&tty_record_path, "%s/%s.out", dir, name);
	free(owned);
	return (0);
}

static void
tty_record_close(void)
{
	if (tty_record_file != NULL)
		fclose(tty_record_file);
	tty_record_file = NULL;
}

/* Stop recording after a failure, saying why once. */
static void
tty_record_fail(const char *what)
{
	char	*msg;

	xasprintf(&msg, "record-output: can't %s %s: %s", what,
	    tty_record_path != NULL ? tty_record_path : "a recording",
	    strerror(errno));
	log_debug("%s", msg);
	log_message(msg);
	free(msg);
	tty_record_close();
	tty_record_failed = 1;
}

static int
tty_record_open(void)
{
	if (tty_record_file != NULL)
		return (0);
	if (tty_record_failed)
		return (-1);
	if (tty_record_find_path() != 0) {
		errno = ENOENT;
		tty_record_fail("find a folder for");
		return (-1);
	}
	if ((tty_record_file = fopen(tty_record_path, "ab")) == NULL) {
		tty_record_fail("open");
		return (-1);
	}
	fseeko(tty_record_file, 0, SEEK_END);
	tty_record_size = ftello(tty_record_file);
	if (tty_record_size < 0)
		tty_record_size = 0;
	return (0);
}

/* Start a new file when this frame would take the current one past the limit. */
static int
tty_record_roll(size_t length)
{
	off_t	 limit;
	char	*previous;
	int	 error = 0;

	limit = (off_t)options_get_number(global_options,
	    "record-output-limit") * 1024;
	if (tty_record_size == 0 || tty_record_size + (off_t)length <= limit)
		return (0);

	tty_record_close();
	previous = tty_record_previous();
	remove(previous);
	if (rename(tty_record_path, previous) != 0)
		error = 1;
	free(previous);
	if (error) {
		tty_record_fail("roll over");
		return (-1);
	}
	return (tty_record_open());
}

static void
tty_record(struct client *c, char kind, const char *data, size_t length)
{
	struct timeval	 tv;
	char		 header[256];
	int		 n;
	size_t		 total;

	if (!options_get_number(global_options, "record-output"))
		return;
	if (tty_record_open() != 0)
		return;

	gettimeofday(&tv, NULL);
	n = snprintf(header, sizeof header, "%c %lld %s %ux%u %zu\n", kind,
	    (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000, c->name,
	    c->tty.sx, c->tty.sy, length);
	if (n < 0 || (size_t)n >= sizeof header)
		return;
	total = n + (data != NULL ? length + 1 : 0);
	if (tty_record_roll(total) != 0)
		return;

	if (fwrite(header, 1, n, tty_record_file) != (size_t)n ||
	    (data != NULL &&
	    (fwrite(data, 1, length, tty_record_file) != length ||
	    fputc('\n', tty_record_file) == EOF)) ||
	    fflush(tty_record_file) != 0) {
		tty_record_fail("write");
		return;
	}
	tty_record_size += total;
}

/* Whether what is about to be sent should be copied first. */
int
tty_record_wanted(void)
{
	return (options_get_number(global_options, "record-output") &&
	    !tty_record_failed);
}

/* Record bytes sent to a client's terminal. */
void
tty_record_sent(struct client *c, const char *data, size_t length)
{
	if (length != 0)
		tty_record(c, 'W', data, length);
}

/* Record bytes thrown away because a client's terminal couldn't keep up. */
void
tty_record_discarded(struct client *c, size_t length)
{
	if (length != 0)
		tty_record(c, 'D', NULL, length);
}

/* Delete the recording: the option was turned off, or a new server starts. */
void
tty_record_remove(void)
{
	char	*previous;

	tty_record_close();
	tty_record_failed = 0;
	if (tty_record_find_path() != 0)
		return;
	previous = tty_record_previous();
	remove(tty_record_path);
	remove(previous);
	free(previous);
}

/* Apply a change to record-output. */
void
tty_record_changed(void)
{
	if (!options_get_number(global_options, "record-output"))
		tty_record_remove();
	else
		tty_record_failed = 0;
}
