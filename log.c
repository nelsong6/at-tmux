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
#include <sys/stat.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#else
#include <dirent.h>
#include <unistd.h>
#endif

#include "tmux.h"

static FILE	*log_file;
static int	 log_level;

/* Each process owns its files, including during upgrade-server handover. */
#define MESSAGE_LOG_BYTES (1024 * 1024)
#define MESSAGE_LOG_DAYS 30

static void
log_prune_messages(const char *dir)
{
	struct stat	 sb;
	char		*path;
	const char	*name, *suffix;
	time_t		 cutoff = time(NULL) - MESSAGE_LOG_DAYS * 86400;
#ifdef _WIN32
	WIN32_FIND_DATAA data;
	HANDLE		 search;

	xasprintf(&path, "%s/tmux-*.log*", dir);
	search = FindFirstFileA(path, &data);
	free(path);
	if (search == INVALID_HANDLE_VALUE)
		return;
	do {
		name = data.cFileName;
#else
	DIR		*d;
	struct dirent	*entry;

	if ((d = opendir(dir)) == NULL)
		return;
	while ((entry = readdir(d)) != NULL) {
		name = entry->d_name;
#endif
		if (strncmp(name, "tmux-", 5) != 0)
			continue;
		suffix = name + 5 + strspn(name + 5, "0123456789");
		if (suffix == name + 5 ||
		    (strcmp(suffix, ".log") != 0 && strcmp(suffix, ".log.1") != 0))
			continue;
		xasprintf(&path, "%s/%s", dir, name);
		if (stat(path, &sb) == 0 && S_ISREG(sb.st_mode) &&
		    sb.st_mtime < cutoff)
			remove(path);
		free(path);
#ifdef _WIN32
	} while (FindNextFileA(search, &data));
	FindClose(search);
#else
	}
	closedir(d);
#endif
}

/* Command errors and failed exits, independent of the verbose debug log. */
int
log_message(const char *message)
{
	static int	 pruned;
	const char	*dir, *home;
	char		*owned = NULL, *path, *previous;
	char		*escaped = NULL, *socket = NULL, *record = NULL;
	char		 stamp[32];
	struct stat	 sb;
	time_t		 now = time(NULL);
	struct tm	*utc = gmtime(&now);
	FILE		*f = NULL;
	int		 error = 0;
	size_t		 length;

	if (utc == NULL) {
		errno = EINVAL;
		return (-1);
	}
	strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%SZ", utc);

	dir = getenv("TMUX_ERROR_LOG_DIR");
	if (dir == NULL || *dir == '\0') {
		if ((home = find_home()) == NULL) {
			errno = ENOENT;
			return (-1);
		}
		xasprintf(&owned, "%s/.tmux", home);
#ifdef _WIN32
		_mkdir(owned);
#else
		mkdir(owned, S_IRWXU);
#endif
		free(owned);
		xasprintf(&owned, "%s/.tmux/errors", home);
		dir = owned;
	}
#ifdef _WIN32
	if (_mkdir(dir) != 0 && errno != EEXIST)
#else
	if (mkdir(dir, S_IRWXU) != 0 && errno != EEXIST)
#endif
	{
		error = errno;
		free(owned);
		errno = error;
		return (-1);
	}
	if (!pruned) {
		log_prune_messages(dir);
		pruned = 1;
	}
	xasprintf(&path, "%s/tmux-%ld.log", dir, (long)getpid());
	xasprintf(&previous, "%s.1", path);
	free(owned);
	if (stravis(&escaped, message,
	    VIS_OCTAL|VIS_CSTYLE|VIS_TAB|VIS_NL) < 0 ||
	    stravis(&socket, socket_path,
	    VIS_OCTAL|VIS_CSTYLE|VIS_TAB|VIS_NL) < 0) {
		error = ENOMEM;
		goto done;
	}
	xasprintf(&record, "%s\t%s\t%.65536s%s\n", stamp, socket,
	    escaped, strlen(escaped) > 65536 ? " [truncated]" : "");
	length = strlen(record);
	if (stat(path, &sb) == 0 && sb.st_size + length > MESSAGE_LOG_BYTES) {
		remove(previous);
		if (rename(path, previous) != 0)
			error = errno;
	}
	if (error == 0 && (f = fopen(path, "ab")) == NULL)
		error = errno;
	if (f != NULL) {
		if (fwrite(record, 1, length, f) != length)
			error = errno != 0 ? errno : EIO;
		if (fclose(f) != 0 && error == 0)
			error = errno;
	}
done:
	free(escaped);
	free(socket);
	free(record);
	free(previous);
	free(path);
	errno = error;
	return (error == 0 ? 0 : -1);
}

/* Log callback for libevent. */
static void
log_event_cb(__unused int severity, const char *msg)
{
	log_debug("%s", msg);
}

/* Increment log level. */
void
log_add_level(void)
{
	log_level++;
}

/* Get log level. */
int
log_get_level(void)
{
	return (log_level);
}

/* Open logging to file. */
void
log_open(const char *name)
{
	char	*path;

	if (log_level == 0)
		return;
	log_close();

	xasprintf(&path, "tmux-%s-%ld.log", name, (long)getpid());
	log_file = fopen(path, "a");
	free(path);
	if (log_file == NULL)
		return;

#ifdef _WIN32
	setvbuf(log_file, NULL, _IOLBF, BUFSIZ);
#else
	setvbuf(log_file, NULL, _IOLBF, 0);
#endif
	event_set_log_callback(log_event_cb);
}

/* Toggle logging. */
void
log_toggle(const char *name)
{
	if (log_level == 0) {
		log_level = 1;
		log_open(name);
		log_debug("log opened");
	} else {
		log_debug("log closed");
		log_level = 0;
		log_close();
	}
}

/* Close logging. */
void
log_close(void)
{
	if (log_file != NULL)
		fclose(log_file);
	log_file = NULL;

	event_set_log_callback(NULL);
}

/* Write a log message. */
static void printflike(1, 0)
log_vwrite(const char *msg, va_list ap, const char *prefix)
{
	char		*s, *out;
	struct timeval	 tv;

	if (log_file == NULL)
		return;

	if (vasprintf(&s, msg, ap) == -1)
		return;
	if (stravis(&out, s, VIS_OCTAL|VIS_CSTYLE|VIS_TAB|VIS_NL) == -1) {
		free(s);
		return;
	}
	free(s);

	gettimeofday(&tv, NULL);
	if (fprintf(log_file, "%lld.%06d %s%s\n", (long long)tv.tv_sec,
	    (int)tv.tv_usec, prefix, out) != -1)
		fflush(log_file);
	free(out);
}

/* Log a debug message. */
void
log_debug(const char *msg, ...)
{
	va_list	ap;

	if (log_file == NULL)
		return;

	va_start(ap, msg);
	log_vwrite(msg, ap, "");
	va_end(ap);
}

/* Log a critical error with error string and die. */
__dead void
fatal(const char *msg, ...)
{
	char	 tmp[256];
	va_list	 ap;

	if (snprintf(tmp, sizeof tmp, "fatal: %s: ", strerror(errno)) < 0)
		exit(1);

	va_start(ap, msg);
	log_vwrite(msg, ap, tmp);
	va_end(ap);

	exit(1);
}

/* Log a critical error and die. */
__dead void
fatalx(const char *msg, ...)
{
	va_list	 ap;

	va_start(ap, msg);
	log_vwrite(msg, ap, "fatal: ");
	va_end(ap);

	exit(1);
}
