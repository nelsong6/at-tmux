/*
 * What a tmux process and tmux-wer.dll share about a crash. The DLL runs in
 * Windows' error reporting process and reads this from the failed process, and
 * after an update it may be a newer build than the server, so the layout only
 * changes along with the magic.
 */

#ifndef WIN32_CRASH_H
#define WIN32_CRASH_H

#include <windows.h>

#define WIN32_CRASH_MAGIC 0x31726577

struct win32_crash_context {
	DWORD		magic;
	volatile LONG	reported;
	char		log[MAX_PATH];
	char		symbols[MAX_PATH];
};

typedef void (*win32_crash_line)(const char *, void *);

void	win32_crash_stack(HANDLE, HANDLE, const CONTEXT *, const char *,
	    win32_crash_line, void *);

#endif
