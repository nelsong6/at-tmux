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
#include <sys/stat.h>

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#include <wtsapi32.h>
#include <direct.h>
#else
#include <sys/file.h>
#include <sys/mman.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#endif

#include "tmux.h"

/*
 * The flight record: what the server was doing, in a file mapped into memory.
 * A write is a plain memory write, and the system keeps the pages when the
 * process dies, so a kill with no chance to clean up still leaves it.
 *
 * Each server owns its own file for as long as it runs: open exclusively on
 * Windows, under flock elsewhere. The system drops that when the process goes
 * however it goes, so the next server tells a dead server's record from a live
 * one's without any timer, and a server handing over leaves its successor
 * nothing to clear. A clean end removes the file, so one left behind by a dead
 * server is a server that ended without saying so, or one Windows took with it
 * (flight_window).
 */

#define FLIGHT_MAGIC "tmuxfl2"
#define FLIGHT_EVENTS 256
#define FLIGHT_TEXT 120

/* A report's line saying how its server ended; flight_ended reads it. */
#define FLIGHT_ENDED "ended:        "
#define FLIGHT_CRASHED "crashed: "
#define FLIGHT_WINDOWS "with Windows: "
#define FLIGHT_SIGNED_IN "before this Windows sign-in: "

struct flight_event {
	int64_t	 at;
	char	 text[FLIGHT_TEXT];
};

struct flight_record {
	char			magic[8];
	int64_t			pid;
	int64_t			started;
	int64_t			worked;
	int64_t			windows;
	char			build[64];
	char			socket[256];
	char			origin[256];
	char			crash[256];
	char			expanding[FLIGHT_TEXT];
	uint32_t		next;
	struct flight_event	events[FLIGHT_EVENTS];
};

static struct flight_record	*flight;
static char			*flight_path;
static char			*flight_pending;
#ifdef _WIN32
static HANDLE			 flight_file = INVALID_HANDLE_VALUE;
static HANDLE			 flight_map;
static SRWLOCK			 flight_lock = SRWLOCK_INIT;
#else
static int			 flight_fd = -1;
#endif

/* What the status message and show-messages say of each way of ending. */
static const char *flight_how_text[] = {
	[FLIGHT_HOW_KILLED] = "was killed from outside",
	[FLIGHT_HOW_CRASHED] = "crashed",
	[FLIGHT_HOW_WINDOWS] = "ended with Windows",
	[FLIGHT_HOW_SIGNED_IN] = "ended before this Windows sign-in, with no "
	    "word from Windows",
};

static void
flight_mkdir(const char *path)
{
#ifdef _WIN32
	_mkdir(path);
#else
	mkdir(path, S_IRWXU);
#endif
}

/* The folder holding every server's record. */
static char *
flight_dir(void)
{
	const char	*dir, *home;
	char		*path;

	dir = getenv("TMUX_FLIGHT_DIR");
	if (dir != NULL && *dir != '\0') {
		flight_mkdir(dir);
		return (xstrdup(dir));
	}
	if ((home = find_home()) == NULL)
		return (NULL);
	xasprintf(&path, "%s/.tmux", home);
	flight_mkdir(path);
	free(path);
	xasprintf(&path, "%s/.tmux/flight", home);
	flight_mkdir(path);
	return (path);
}

/* This socket's name, safe in a file name. */
static char *
flight_label(void)
{
	const char	*name;
	char		*label, *cp;

	if ((name = strrchr(socket_path, '/')) != NULL)
		name++;
	else
		name = socket_path;
	label = xstrdup(name);
	for (cp = label; *cp != '\0'; cp++) {
		if (strchr("/\\:*?\"<>|", *cp) != NULL)
			*cp = '_';
	}
	return (label);
}

static void
flight_stamp(char *buf, size_t size, int64_t at)
{
	time_t		 t = (time_t)at;
	struct tm	*tm = localtime(&t);

	if (at == 0 || tm == NULL ||
	    strftime(buf, size, "%Y-%m-%d %H:%M:%S", tm) == 0)
		snprintf(buf, size, "not recorded");
}

/* Is the server that owns this record gone? */
static int
flight_owner_gone(const char *path)
{
#ifdef _WIN32
	HANDLE	h;

	h = CreateFileA(path, GENERIC_READ|GENERIC_WRITE,
	    FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE, NULL,
	    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
	if (h == INVALID_HANDLE_VALUE)
		return (0);
	CloseHandle(h);
	return (1);
#else
	int	fd, gone;

	if ((fd = open(path, O_RDWR|O_CLOEXEC)) == -1)
		return (0);
	gone = flock(fd, LOCK_EX|LOCK_NB) == 0;
	close(fd);
	return (gone);
#endif
}

/* The first time any client lost this server, 0 if none did. */
static int64_t
flight_lost_at(const char *path, int64_t started)
{
	FILE		*f;
	long long	 at;
	int64_t		 first = 0;

	if ((f = fopen(path, "r")) == NULL)
		return (0);
	while (fscanf(f, "%lld%*[^\n]", &at) == 1) {
		if (at >= started && (first == 0 || at < first))
			first = at;
	}
	fclose(f);
	return (first);
}

/* When this Windows sign-in began, or 0 if that can't be told. */
int64_t
flight_signed_in(void)
{
	const char	*signin;
#ifdef _WIN32
	LPWSTR		 buffer;
	DWORD		 size;
	long long	 ticks;
#endif

	if ((signin = getenv("TMUX_FLIGHT_SIGNIN")) != NULL && *signin != '\0')
		return (strtoll(signin, NULL, 10));
#ifdef _WIN32
	if (!WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE,
	    WTS_CURRENT_SESSION, WTSSessionInfo, &buffer, &size))
		return (0);
	ticks = ((WTSINFOW *)buffer)->LogonTime.QuadPart;
	WTSFreeMemory(buffer);
	if (ticks > 0)
		return (ticks / 10000000 - 11644473600LL);
#endif
	return (0);
}

/* Turn a dead server's record into a report anyone can read. */
static void
flight_report_one(const char *dir, const char *path, const char *lost)
{
	struct flight_record	*r;
	struct flight_event	*e;
	FILE			*f;
	char			*ended, *report, *line;
	char			 started[32], worked[32], at[32], now[32];
	int64_t			 lost_at;
	uint32_t		 i, n, first;
	size_t			 got;
	enum flight_how		 how;

	r = xcalloc(1, sizeof *r);
	if ((f = fopen(path, "rb")) == NULL) {
		free(r);
		return;
	}
	got = fread(r, 1, sizeof *r, f);
	fclose(f);
	if (got != sizeof *r || strcmp(r->magic, FLIGHT_MAGIC) != 0) {
		remove(path);
		free(r);
		return;
	}
	r->socket[sizeof r->socket - 1] = '\0';
	r->build[sizeof r->build - 1] = '\0';
	r->origin[sizeof r->origin - 1] = '\0';
	r->crash[sizeof r->crash - 1] = '\0';
	r->expanding[sizeof r->expanding - 1] = '\0';
#ifdef _WIN32
	if (*r->crash == '\0')
		win32_crash_reason((long)r->pid, r->started, r->crash,
		    sizeof r->crash);
#endif

	xasprintf(&ended, "%s/ended", dir);
	flight_mkdir(ended);
	log_prune_messages(ended);
	xasprintf(&report, "%s/tmux-%lld.log", ended, (long long)r->pid);
	free(ended);
	if ((f = fopen(report, "ab")) == NULL) {
		free(report);
		free(r);
		return;
	}

	lost_at = flight_lost_at(lost, r->started);
	flight_stamp(started, sizeof started, r->started);
	flight_stamp(worked, sizeof worked, r->worked);
	flight_stamp(at, sizeof at, lost_at);
	flight_stamp(now, sizeof now, time(NULL));

	fprintf(f, "tmux server %lld on %s\n", (long long)r->pid, r->socket);
	if (*r->crash != '\0') {
		how = FLIGHT_HOW_CRASHED;
		fprintf(f, FLIGHT_ENDED FLIGHT_CRASHED "%s\n", r->crash);
	} else if (r->windows != 0) {
		how = FLIGHT_HOW_WINDOWS;
		flight_stamp(at, sizeof at, r->windows);
		fprintf(f, FLIGHT_ENDED FLIGHT_WINDOWS "Windows ended the "
		    "session at %s\n", at);
	} else if (r->worked < flight_signed_in()) {
		how = FLIGHT_HOW_SIGNED_IN;
		fprintf(f, FLIGHT_ENDED FLIGHT_SIGNED_IN "no word from "
		    "Windows: a power cut, Windows failing, or a kill\n");
	} else {
		how = FLIGHT_HOW_KILLED;
		fprintf(f, FLIGHT_ENDED "with no record of why: killed from "
		    "outside, or a failure nothing in it could catch\n");
	}
	fprintf(f, "build:        %s\n", r->build);
	fprintf(f, "started:      %s\n", started);
	fprintf(f, "ran as:       %s\n", r->origin);
	fprintf(f, "last worked:  %s\n", worked);
	fprintf(f, "client lost:  %s\n", at);
	fprintf(f, "found by:     server %ld at %s\n", (long)getpid(), now);
	if (*r->expanding != '\0')
		fprintf(f, "expanding:    %s\n", r->expanding);
	fprintf(f, "recent events, oldest first:\n");
	n = r->next < FLIGHT_EVENTS ? r->next : FLIGHT_EVENTS;
	first = r->next - n;
	for (i = 0; i < n; i++) {
		e = &r->events[(first + i) % FLIGHT_EVENTS];
		e->text[sizeof e->text - 1] = '\0';
		flight_stamp(at, sizeof at, e->at);
		fprintf(f, "  %s  %s\n", at, e->text);
	}
	fprintf(f, "\n");
	fclose(f);

	remove(path);

	xasprintf(&line, "The last tmux server %s. Report: %s",
	    flight_how_text[how], report);
	log_message(line);
	server_add_message("%s", line);
	if (how == FLIGHT_HOW_WINDOWS)
		free(line);
	else {
		free(flight_pending);
		flight_pending = line;
	}
	free(report);
	free(r);
}

/* Report every server of this socket that died since the last one started. */
static void
flight_report(const char *dir, const char *label)
{
	char		*pattern, *path, *lost;
	const char	*name;
	size_t		 size = strlen(label);
#ifdef _WIN32
	WIN32_FIND_DATAA data;
	HANDLE		 search;

	xasprintf(&lost, "%s/%s.lost", dir, label);
	xasprintf(&pattern, "%s/%s-*.rec", dir, label);
	search = FindFirstFileA(pattern, &data);
	free(pattern);
	if (search != INVALID_HANDLE_VALUE) {
		do {
			name = data.cFileName;
#else
	DIR		*d;
	struct dirent	*entry;

	pattern = NULL;
	xasprintf(&lost, "%s/%s.lost", dir, label);
	if ((d = opendir(dir)) != NULL) {
		while ((entry = readdir(d)) != NULL) {
			name = entry->d_name;
#endif
			if (strncmp(name, label, size) != 0 ||
			    name[size] != '-' ||
			    name[size + 1 + strspn(name + size + 1,
			    "0123456789")] != '.')
				continue;
			xasprintf(&path, "%s/%s", dir, name);
			if (flight_owner_gone(path))
				flight_report_one(dir, path, lost);
			free(path);
#ifdef _WIN32
		} while (FindNextFileA(search, &data));
		FindClose(search);
#else
		}
		closedir(d);
#endif
	}
	remove(lost);
	free(lost);
}

#ifdef _WIN32
/*
 * Windows ending the session says so to every top-level window, hidden ones
 * too, and to nothing else in a process with user32 loaded: the console control
 * events for sign-out and shutdown are not sent to it. The answer to the first
 * message can still be overruled, so only the second, which also says whether
 * the end went ahead, is believed. Windows may end the process as soon as it
 * returns, and this isn't the server's thread, so the mark goes straight to
 * disk. An installer closing the server is not the session ending.
 */
static LRESULT CALLBACK
flight_window(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
	if (message != WM_ENDSESSION)
		return (DefWindowProcW(window, message, wparam, lparam));
	if (wparam && (lparam & ENDSESSION_CLOSEAPP) == 0) {
		AcquireSRWLockExclusive(&flight_lock);
		if (flight != NULL) {
			flight->windows = (int64_t)time(NULL);
			FlushViewOfFile(flight, sizeof *flight);
			FlushFileBuffers(flight_file);
		}
		ReleaseSRWLockExclusive(&flight_lock);
	}
	return (0);
}

static DWORD WINAPI
flight_window_thread(__unused LPVOID arg)
{
	WNDCLASSW	window = { 0 };
	MSG		message;

	window.lpfnWndProc = flight_window;
	window.hInstance = GetModuleHandleW(NULL);
	window.lpszClassName = L"tmux-flight";
	if (RegisterClassW(&window) == 0 ||
	    CreateWindowExW(0, window.lpszClassName, NULL, WS_POPUP, 0, 0, 0, 0,
	    NULL, NULL, window.hInstance, NULL) == NULL)
		return (0);
	while (GetMessageW(&message, NULL, 0, 0) > 0)
		DispatchMessageW(&message);
	return (0);
}
#endif

/* Map this server's record. */
static int
flight_open(const char *dir, const char *label)
{
	xasprintf(&flight_path, "%s/%s-%ld.rec", dir, label, (long)getpid());
#ifdef _WIN32
	flight_file = CreateFileA(flight_path, GENERIC_READ|GENERIC_WRITE,
	    FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
	if (flight_file == INVALID_HANDLE_VALUE)
		goto fail;
	flight_map = CreateFileMappingA(flight_file, NULL, PAGE_READWRITE, 0,
	    sizeof *flight, NULL);
	if (flight_map == NULL)
		goto fail;
	flight = MapViewOfFile(flight_map, FILE_MAP_WRITE, 0, 0, 0);
	if (flight == NULL)
		goto fail;
#else
	void	*view;

	flight_fd = open(flight_path, O_RDWR|O_CREAT|O_TRUNC|O_CLOEXEC, 0600);
	if (flight_fd == -1 || flock(flight_fd, LOCK_EX|LOCK_NB) != 0 ||
	    ftruncate(flight_fd, sizeof *flight) != 0)
		goto fail;
	view = mmap(NULL, sizeof *flight, PROT_READ|PROT_WRITE, MAP_SHARED,
	    flight_fd, 0);
	if (view == MAP_FAILED)
		goto fail;
	flight = view;
#endif
	return (0);

fail:
	log_debug("%s: can't map %s", __func__, flight_path);
	free(flight_path);
	flight_path = NULL;
	return (-1);
}

/* Start this server's record, after reporting any dead server's. */
void
flight_start(void)
{
	char	*dir, *label;
#ifdef _WIN32
	HANDLE	 thread;
#endif

	if ((dir = flight_dir()) == NULL)
		return;
	label = flight_label();
	flight_report(dir, label);
	if (flight_open(dir, label) == 0) {
		memcpy(flight->magic, FLIGHT_MAGIC, sizeof FLIGHT_MAGIC);
		flight->pid = (int64_t)getpid();
		flight->started = flight->worked = (int64_t)time(NULL);
		strlcpy(flight->build, getversion(), sizeof flight->build);
		strlcpy(flight->socket, socket_path, sizeof flight->socket);
#ifdef _WIN32
		win32_origin(flight->origin, sizeof flight->origin);
#else
		snprintf(flight->origin, sizeof flight->origin, "parent %ld",
		    (long)getppid());
#endif
		flight_note("server started");
#ifdef _WIN32
		thread = CreateThread(NULL, 0, flight_window_thread, NULL, 0,
		    NULL);
		if (thread != NULL)
			CloseHandle(thread);
#endif
	}
	free(label);
	free(dir);
}

/* Add a line to the recent events. */
void
flight_note(const char *fmt, ...)
{
	struct flight_event	*e;
	va_list			 ap;

	if (flight == NULL)
		return;
	e = &flight->events[flight->next % FLIGHT_EVENTS];
	e->at = (int64_t)time(NULL);
	va_start(ap, fmt);
	vsnprintf(e->text, sizeof e->text, fmt, ap);
	va_end(ap);
	flight->next++;
}

/* The server is at work now. */
void
flight_worked(time_t now)
{
	if (flight != NULL)
		flight->worked = (int64_t)now;
}

/* Keep the format being expanded, whose text can be what brings a server down. */
void
flight_expanding(const char *fmt)
{
	if (flight != NULL)
		strlcpy(flight->expanding, fmt, sizeof flight->expanding);
}

/* The server is going down and knows why: this can run from a crash handler. */
void
flight_crashed(const char *why)
{
	if (flight != NULL)
		snprintf(flight->crash, sizeof flight->crash, "%s", why);
}

/* A clean end: leave a line saying how, and no record to report. */
void
flight_end(const char *fmt, ...)
{
	va_list	 ap;
	char	*why, *line;

	if (flight == NULL)
		return;
	va_start(ap, fmt);
	xvasprintf(&why, fmt, ap);
	va_end(ap);
	xasprintf(&line, "server %ld ended: %s", (long)getpid(), why);
	log_message(line);
	free(line);
	free(why);

#ifdef _WIN32
	AcquireSRWLockExclusive(&flight_lock);
	UnmapViewOfFile(flight);
	CloseHandle(flight_map);
	CloseHandle(flight_file);
	flight = NULL;
	ReleaseSRWLockExclusive(&flight_lock);
#else
	munmap(flight, sizeof *flight);
	close(flight_fd);
	flight = NULL;
#endif
	remove(flight_path);
	free(flight_path);
	flight_path = NULL;
}

/*
 * Read how server pid ended from its report, if one was written at or after
 * since, setting its path and, if the server crashed, the reason (NULL if not),
 * for the caller to free. Reports go by pid and pids come round again, so an
 * older one is another server's, and in a file of several the last counts.
 */
enum flight_how
flight_ended(long long pid, time_t since, char **report, char **crash)
{
	struct stat	 sb;
	FILE		*f;
	char		*dir, *path, line[512], *ended;
	enum flight_how	 how = FLIGHT_HOW_UNKNOWN;

	*report = *crash = NULL;
	if ((dir = flight_dir()) == NULL)
		return (FLIGHT_HOW_UNKNOWN);
	xasprintf(&path, "%s/ended/tmux-%lld.log", dir, pid);
	free(dir);
	if (stat(path, &sb) != 0 || sb.st_mtime < since ||
	    (f = fopen(path, "r")) == NULL) {
		free(path);
		return (FLIGHT_HOW_UNKNOWN);
	}
	while (fgets(line, sizeof line, f) != NULL) {
		if (strncmp(line, FLIGHT_ENDED, strlen(FLIGHT_ENDED)) != 0)
			continue;
		free(*crash);
		*crash = NULL;
		line[strcspn(line, "\r\n")] = '\0';
		ended = line + strlen(FLIGHT_ENDED);
		if (strncmp(ended, FLIGHT_CRASHED,
		    strlen(FLIGHT_CRASHED)) == 0) {
			how = FLIGHT_HOW_CRASHED;
			*crash = xstrdup(ended + strlen(FLIGHT_CRASHED));
		} else if (strncmp(ended, FLIGHT_WINDOWS,
		    strlen(FLIGHT_WINDOWS)) == 0)
			how = FLIGHT_HOW_WINDOWS;
		else if (strncmp(ended, FLIGHT_SIGNED_IN,
		    strlen(FLIGHT_SIGNED_IN)) == 0)
			how = FLIGHT_HOW_SIGNED_IN;
		else
			how = FLIGHT_HOW_KILLED;
	}
	fclose(f);
	if (how != FLIGHT_HOW_UNKNOWN)
		*report = path;
	else
		free(path);
	return (how);
}

/* Tell the first client to attach how the last server went. */
void
flight_tell(struct client *c)
{
	if (flight_pending == NULL)
		return;
	status_message_set(c, -1, 1, 0, 0, "%s", flight_pending);
	free(flight_pending);
	flight_pending = NULL;
}

/* A client saw the connection drop, the exact moment the server went. */
void
flight_lost_server(void)
{
	char	*dir, *label, *path;
	FILE	*f;

	if ((dir = flight_dir()) == NULL)
		return;
	label = flight_label();
	xasprintf(&path, "%s/%s.lost", dir, label);
	if ((f = fopen(path, "a")) != NULL) {
		fprintf(f, "%lld %ld\n", (long long)time(NULL), (long)getpid());
		fclose(f);
	}
	free(path);
	free(label);
	free(dir);
}
