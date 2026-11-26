/*
 * A fail-fast (heap corruption, a stack cookie) ends a process without running
 * anything in it, so no handler of ours can write the crash log. Windows' error
 * reporting still sees it, and loads this DLL into its own process while the
 * failed one waits, because win32_crash_init registered it. The log it writes
 * is the one the process would have.
 */

#include <stdio.h>

#include "win32-crash.h"
#include <werapi.h>

#define STATUS_FAIL_FAST 0xc0000409

struct wer_log {
	FILE	*f;
	long	 pid;
};

static void
wer_line(int frame, const char *function, const char *at, void *arg)
{
	struct wer_log	*log = arg;
	char		 n[16];

	snprintf(n, sizeof n, "%d", frame);
	win32_crash_record(log->f, log->pid, "stack frame", "frame", n,
	    "function", function, at != NULL ? "at" : NULL, at, (char *)NULL);
}

__declspec(dllexport) HRESULT WINAPI
OutOfProcessExceptionEventCallback(void *context,
    const PWER_RUNTIME_EXCEPTION_INFORMATION info, BOOL *claimed, PWSTR event,
    PDWORD size, PDWORD signatures)
{
	struct win32_crash_context	 c;
	const EXCEPTION_RECORD		*r = &info->exceptionRecord;
	struct wer_log			 log;
	char				 what[128];
	SIZE_T				 got;
	int				 n;

	(void)event;
	(void)size;
	(void)signatures;

	/* Not claiming it leaves Windows' own report and dump as they were. */
	*claimed = FALSE;

	if (!ReadProcessMemory(info->hProcess, context, &c, sizeof c, &got) ||
	    got != sizeof c || c.magic != WIN32_CRASH_MAGIC || c.reported)
		return (S_OK);
	c.log[sizeof c.log - 1] = '\0';
	c.symbols[sizeof c.symbols - 1] = '\0';
	if (c.log[0] == '\0' || (log.f = fopen(c.log, "w")) == NULL)
		return (S_OK);
	/* The lines are the failed process's, not this one's. */
	log.pid = (long)GetProcessId(info->hProcess);

	n = snprintf(what, sizeof what, "exception 0x%08lx", r->ExceptionCode);
	if (r->ExceptionCode == STATUS_FAIL_FAST && r->NumberParameters > 0)
		n += snprintf(what + n, sizeof what - n, " (fail-fast code %llu)",
		    (unsigned long long)r->ExceptionInformation[0]);
	snprintf(what + n, sizeof what - n, " at %p", r->ExceptionAddress);
	win32_crash_record(log.f, log.pid, "tmux crashed", "what", what,
	    (char *)NULL);

	win32_crash_stack(info->hProcess, info->hThread, &info->context,
	    c.symbols, wer_line, &log);
	fclose(log.f);
	return (S_OK);
}

/* Windows asks for these only of a module that claims the crash. */
__declspec(dllexport) HRESULT WINAPI
OutOfProcessExceptionEventSignatureCallback(void *context,
    const PWER_RUNTIME_EXCEPTION_INFORMATION info, DWORD index, PWSTR name,
    PDWORD name_size, PWSTR value, PDWORD value_size)
{
	return (E_NOTIMPL);
}

__declspec(dllexport) HRESULT WINAPI
OutOfProcessExceptionEventDebuggerLaunchCallback(void *context,
    const PWER_RUNTIME_EXCEPTION_INFORMATION info, BOOL *custom,
    PWSTR command, PDWORD size, BOOL *wait)
{
	return (E_NOTIMPL);
}
