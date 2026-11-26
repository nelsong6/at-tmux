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

#include "logline.h"
#include "tmux.h"

static FILE	*log_file;
static int	 log_level;

/* Flight reports (flight.c) are kept this long. */
#define MESSAGE_LOG_DAYS 30

void
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

/* The most fields a line takes, the socket included. */
#define LOG_FIELDS 16
/* The longest value a line keeps whole. */
#define LOG_VALUE_BYTES 65536

/*
 * Write one line of tmux's log (AHT-204, at-home-tools docs/app-logs.md):
 * %LOCALAPPDATA%\tmux\tmux.log, or the file TMUX_LOG names, which tests and
 * throwaway servers set to keep their lines out of the NAS's pile. Every
 * process of every server writes the same file; each line carries its pid and
 * socket, and logline opens and closes the file for each line, so lines never
 * interleave. After the message come key, value string pairs, ended by a NULL
 * key; a NULL value leaves its field out. A value can hold text from outside
 * tmux (a command's error, a program's name, a path), so each is masked with
 * logline_redact.
 */
static void
log_record(logline_level level, const char *message, va_list ap)
{
	static logline_logger	*logger;
	logline_field		 fields[LOG_FIELDS];
	char			*owned[LOG_FIELDS];
	const char		*key, *value;
	size_t			 n = 0, i;

	if (logger == NULL && (logger = logline_open("tmux", "TMUX_LOG")) == NULL)
		return;
	while (n < LOG_FIELDS - 1 && (key = va_arg(ap, const char *)) != NULL) {
		if ((value = va_arg(ap, const char *)) == NULL)
			continue;
		if ((owned[n] = logline_redact(value)) != NULL &&
		    strlen(owned[n]) > LOG_VALUE_BYTES)
			strlcpy(owned[n] + LOG_VALUE_BYTES - 12, " [truncated]", 13);
		fields[n].key = key;
		fields[n].value = owned[n];
		n++;
	}
	fields[n].key = "socket";
	fields[n].value = socket_path;
	logline_log(logger, level, message, fields, n + 1);
	for (i = 0; i < n; i++)
		free(owned[i]);
}

/*
 * Something failed: a command's error, a program's failed exit. at-home-tools'
 * activity shows each error line of the at server as a terminal failure.
 */
void
log_message(const char *message, ...)
{
	va_list	 ap;

	va_start(ap, message);
	log_record(LOGLINE_ERROR, message, ap);
	va_end(ap);
}

/* Things the server did that are worth checking later but are not failures. */
void
log_event(const char *message, ...)
{
	va_list	 ap;

	va_start(ap, message);
	log_record(LOGLINE_INFO, message, ap);
	va_end(ap);
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

static void
log_flight_fatal(const char *msg, va_list ap)
{
	char	 why[256];

	vsnprintf(why, sizeof why, msg, ap);
	flight_crashed(why);
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

	va_start(ap, msg);
	log_flight_fatal(msg, ap);
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

	va_start(ap, msg);
	log_flight_fatal(msg, ap);
	va_end(ap);

	exit(1);
}
