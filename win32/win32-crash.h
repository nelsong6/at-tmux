/*
 * What a tmux process and tmux-wer.dll share about a crash. The DLL runs in
 * Windows' error reporting process and reads this from the failed process, and
 * after an update it may be a newer build than the server, so the layout only
 * changes along with the magic.
 */

#ifndef WIN32_CRASH_H
#define WIN32_CRASH_H

#include <stdio.h>
#include <windows.h>

#define WIN32_CRASH_MAGIC 0x31726577

struct win32_crash_context {
	DWORD		magic;
	volatile LONG	reported;
	char		log[MAX_PATH];
	char		symbols[MAX_PATH];
};

/* A frame of a crash's stack: its number, function and file:line (or NULL). */
typedef void (*win32_crash_line)(int, const char *, const char *, void *);

void	win32_crash_stack(HANDLE, HANDLE, const CONTEXT *, const char *,
	    win32_crash_line, void *);

/*
 * One line of the crash log (AHT-204): a standard log line for process pid at
 * error level, then key, value string pairs ended by a NULL key, appended to f
 * and flushed, so a handler that dies part way leaves what it wrote.
 */
void	win32_crash_record(FILE *, long, const char *, ...);

#endif
