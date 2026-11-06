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

static void
wer_line(const char *line, void *arg)
{
	fprintf(arg, "%s\n", line);
}

__declspec(dllexport) HRESULT WINAPI
OutOfProcessExceptionEventCallback(void *context,
    const PWER_RUNTIME_EXCEPTION_INFORMATION info, BOOL *claimed, PWSTR event,
    PDWORD size, PDWORD signatures)
{
	struct win32_crash_context	 c;
	const EXCEPTION_RECORD		*r = &info->exceptionRecord;
	FILE				*f;
	SIZE_T				 got;

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
	if (c.log[0] == '\0' || (f = fopen(c.log, "w")) == NULL)
		return (S_OK);

	fprintf(f, "tmux crashed: exception 0x%08lx", r->ExceptionCode);
	if (r->ExceptionCode == STATUS_FAIL_FAST && r->NumberParameters > 0)
		fprintf(f, " (fail-fast code %llu)",
		    (unsigned long long)r->ExceptionInformation[0]);
	fprintf(f, " at %p\n", r->ExceptionAddress);
	fflush(f);

	win32_crash_stack(info->hProcess, info->hThread, &info->context,
	    c.symbols, wer_line, f);
	fclose(f);
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
