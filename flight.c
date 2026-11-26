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

#include "logline.h"
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

/*
 * A report is standard log lines (AHT-204, at-home-tools docs/app-logs.md): the
 * dead server's recent events, then a line with this message saying how it
 * ended, its how= one of flight_how_word, which flight_ended reads.
 */
#define FLIGHT_ENDED "server ended"
#ifdef _WIN32
#define FLIGHT_NO_WORD "no word from Windows: a power cut, Windows failing, or a kill"
#else
#define FLIGHT_NO_WORD "a reboot, a sign-out, a power cut, or a kill"
#endif

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

/* Each way of ending as a report's how= field says it. */
static const char *flight_how_word[] = {
	[FLIGHT_HOW_UNKNOWN] = "unknown",
	[FLIGHT_HOW_KILLED] = "killed",
	[FLIGHT_HOW_CRASHED] = "crashed",
	[FLIGHT_HOW_WINDOWS] = "windows",
	[FLIGHT_HOW_SIGNED_IN] = "signed-in",
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

/* A moment in seconds as logline writes it: local time and the zone's offset. */
static logline_time
flight_time(int64_t at)
{
	logline_time	 lt;
	time_t		 t = (time_t)at, local;
	struct tm	 tm, *p;

	memset(&lt, 0, sizeof lt);
	if ((p = localtime(&t)) == NULL)
		return (logline_now());
	tm = *p;
#ifdef _WIN32
	local = _mkgmtime(&tm);
#else
	local = timegm(&tm);
#endif
	lt.year = tm.tm_year + 1900;
	lt.month = tm.tm_mon + 1;
	lt.day = tm.tm_mday;
	lt.hour = tm.tm_hour;
	lt.minute = tm.tm_min;
	lt.second = tm.tm_sec;
	lt.offset_minutes = (int)((local - t) / 60);
	return (lt);
}

/* A moment for a report's field: RFC 3339 with the zone, as its lines' times. */
static void
flight_stamp(char *buf, size_t size, int64_t at)
{
	logline_time	 lt;
	int		 offset;

	if (at == 0) {
		snprintf(buf, size, "not recorded");
		return;
	}
	lt = flight_time(at);
	offset = lt.offset_minutes < 0 ? -lt.offset_minutes : lt.offset_minutes;
	if (lt.offset_minutes == 0)
		snprintf(buf, size, "%04d-%02d-%02dT%02d:%02d:%02dZ", lt.year,
		    lt.month, lt.day, lt.hour, lt.minute, lt.second);
	else
		snprintf(buf, size, "%04d-%02d-%02dT%02d:%02d:%02d%c%02d:%02d",
		    lt.year, lt.month, lt.day, lt.hour, lt.minute, lt.second,
		    lt.offset_minutes < 0 ? '-' : '+', offset / 60, offset % 60);
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

/*
 * When this sign-in began, or 0 if that can't be told: Windows' logon time, or
 * elsewhere the systemd-logind session's start, else the boot.
 */
int64_t
flight_signed_in(void)
{
	const char	*signin;
#ifdef _WIN32
	LPWSTR		 buffer;
	DWORD		 size;
	long long	 ticks;
#else
	FILE		*f;
	char		 line[128], *path;
	unsigned int	 id;
	long long	 at = 0;
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
#else
	if ((f = fopen("/proc/self/sessionid", "r")) != NULL) {
		if (fscanf(f, "%u", &id) != 1)
			id = UINT_MAX;
		fclose(f);
		if (id != UINT_MAX) {
			xasprintf(&path, "/run/systemd/sessions/%u", id);
			if ((f = fopen(path, "r")) != NULL) {
				while (fgets(line, sizeof line, f) != NULL) {
					if (sscanf(line, "REALTIME=%lld",
					    &at) == 1)
						break;
				}
				fclose(f);
			}
			free(path);
			if (at > 0)
				return (at / 1000000);
		}
	}
	if ((f = fopen("/proc/stat", "r")) != NULL) {
		while (fgets(line, sizeof line, f) != NULL) {
			if (sscanf(line, "btime %lld", &at) == 1)
				break;
		}
		fclose(f);
		if (at > 0)
			return (at);
	}
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
	logline_field		 fields[12];
	logline_level		 level;
	char			*ended, *report, *line, *text, *expanding = NULL;
	char			 pid[32], found[32], started[40], worked[40];
	char			 at[40], windows[40];
	const char		*reason;
	int64_t			 lost_at;
	uint32_t		 i, n, first;
	size_t			 got, nfields = 0;
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

	/*
	 * The recent events, oldest first, each a line at its own time with the
	 * dead server's pid (logline_format writes a line for an event that
	 * happened earlier). Their text names commands and what they ran on.
	 */
	n = r->next < FLIGHT_EVENTS ? r->next : FLIGHT_EVENTS;
	first = r->next - n;
	for (i = 0; i < n; i++) {
		e = &r->events[(first + i) % FLIGHT_EVENTS];
		e->text[sizeof e->text - 1] = '\0';
		text = logline_redact(e->text);
		fields[0].key = "event";
		fields[0].value = text;
		line = logline_format(flight_time(e->at), (long)r->pid,
		    LOGLINE_INFO, "flight event", fields, 1);
		if (line != NULL)
			fprintf(f, "%s\n", line);
		free(line);
		free(text);
	}

	/* Then how it ended, from the server that found it, now. */
	lost_at = flight_lost_at(lost, r->started);
	if (*r->crash != '\0') {
		how = FLIGHT_HOW_CRASHED;
		reason = r->crash;
	} else if (r->windows != 0) {
		how = FLIGHT_HOW_WINDOWS;
		reason = "Windows ended the session";
	} else if (r->worked < flight_signed_in()) {
		how = FLIGHT_HOW_SIGNED_IN;
		reason = FLIGHT_NO_WORD;
	} else {
		how = FLIGHT_HOW_KILLED;
		reason = "killed from outside, or a failure nothing in it "
		    "could catch";
	}
	level = how == FLIGHT_HOW_WINDOWS ? LOGLINE_INFO :
	    how == FLIGHT_HOW_SIGNED_IN ? LOGLINE_WARN : LOGLINE_ERROR;
	snprintf(pid, sizeof pid, "%lld", (long long)r->pid);
	snprintf(found, sizeof found, "%ld", (long)getpid());
	flight_stamp(started, sizeof started, r->started);
	flight_stamp(worked, sizeof worked, r->worked);
	flight_stamp(at, sizeof at, lost_at);
	flight_stamp(windows, sizeof windows, r->windows);
#define FLIGHT_FIELD(k, v) do {						\
	fields[nfields].key = (k);					\
	fields[nfields].value = (v);					\
	nfields++;							\
} while (0)
	FLIGHT_FIELD("server", pid);
	FLIGHT_FIELD("how", flight_how_word[how]);
	FLIGHT_FIELD("reason", reason);
	if (how == FLIGHT_HOW_WINDOWS)
		FLIGHT_FIELD("windows_ended", windows);
	FLIGHT_FIELD("socket", r->socket);
	FLIGHT_FIELD("build", r->build);
	FLIGHT_FIELD("started", started);
	FLIGHT_FIELD("ran_as", r->origin);
	FLIGHT_FIELD("last_worked", worked);
	FLIGHT_FIELD("client_lost", at);
	FLIGHT_FIELD("found_by", found);
	if (*r->expanding != '\0') {
		expanding = logline_redact(r->expanding);
		FLIGHT_FIELD("expanding", expanding);
	}
#undef FLIGHT_FIELD
	line = logline_format(logline_now(), (long)getpid(), level,
	    FLIGHT_ENDED, fields, nfields);
	if (line != NULL)
		fprintf(f, "%s\n", line);
	free(line);
	free(expanding);
	fclose(f);

	remove(path);

	xasprintf(&line, "The last tmux server %s. Report: %s",
	    flight_how_text[how], report);
	log_message("last server ended", "how", flight_how_word[how],
	    "server", pid, "report", report, (char *)NULL);
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
	char	*why;

	if (flight == NULL)
		return;
	va_start(ap, fmt);
	xvasprintf(&why, fmt, ap);
	va_end(ap);
	log_event("server stopped", "why", why, (char *)NULL);
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

/* A parsed line's field, NULL if it has none of that name. */
static const char *
flight_field(const logline_entry *entry, const char *key)
{
	size_t	i;

	for (i = 0; i < entry->nfields; i++) {
		if (strcmp(entry->fields[i].key, key) == 0)
			return (entry->fields[i].value);
	}
	return (NULL);
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
	logline_entry	 entry;
	char		*dir, *path, *line = NULL;
	const char	*word, *reason;
	size_t		 size = 0;
	enum flight_how	 how = FLIGHT_HOW_UNKNOWN, i;

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
	while (getline(&line, &size, f) != -1) {
		line[strcspn(line, "\r\n")] = '\0';
		if (logline_parse(line, &entry, NULL, 0) != 0)
			continue;
		if (strcmp(entry.message, FLIGHT_ENDED) == 0 &&
		    (word = flight_field(&entry, "how")) != NULL) {
			free(*crash);
			*crash = NULL;
			how = FLIGHT_HOW_KILLED;
			for (i = FLIGHT_HOW_KILLED; i <= FLIGHT_HOW_SIGNED_IN; i++) {
				if (strcmp(word, flight_how_word[i]) == 0)
					how = i;
			}
			reason = flight_field(&entry, "reason");
			if (how == FLIGHT_HOW_CRASHED)
				*crash = xstrdup(reason != NULL ? reason : "");
		}
		logline_entry_free(&entry);
	}
	free(line);
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
