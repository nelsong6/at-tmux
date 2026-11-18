/*
 * The PowerShell a test's panes run under CTest (win32-test.sh's POWERSHELL_EXE,
 * from TEST_POWERSHELL): Windows PowerShell with -NoProfile and the rest of this
 * program's command line, so no account's profile prints into a pane a test
 * reads. A pane started with Windows PowerShell loads the profile of the account
 * running the test, and on upstairspc's runner that profile prints errors into
 * the pane. It is named powershell.exe, so tmux starts it as it starts Windows
 * PowerShell (-NoLogo for a shell, -c before a command).
 *
 * PowerShell runs in a job that ends with this program, so ending the pane's
 * process ends both, as ending PowerShell would. On a console close this waits
 * for PowerShell to finish its own handling, as PowerShell itself would keep
 * the pane until then; Ctrl+C is PowerShell's to handle.
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static HANDLE	child;

static BOOL WINAPI
control(DWORD type)
{
	if (type == CTRL_CLOSE_EVENT || type == CTRL_LOGOFF_EVENT ||
	    type == CTRL_SHUTDOWN_EVENT)
		WaitForSingleObject(child, INFINITE);
	return (TRUE);
}

int
wmain(void)
{
	JOBOBJECT_EXTENDED_LIMIT_INFORMATION	 limit = { 0 };
	STARTUPINFOW				 si = { sizeof si };
	PROCESS_INFORMATION			 pi;
	wchar_t					*rest, system[MAX_PATH], *line;
	size_t					 size;
	HANDLE					 job;
	DWORD					 code;

	/* What follows this program's own name, quoted or not, passes on as written. */
	rest = GetCommandLineW();
	if (*rest == L'"') {
		rest = wcschr(rest + 1, L'"');
		rest = rest != NULL ? rest + 1 : L"";
	} else {
		while (*rest != L'\0' && *rest != L' ' && *rest != L'\t')
			rest++;
	}

	if (GetSystemDirectoryW(system, MAX_PATH) == 0)
		return (1);
	size = wcslen(system) + wcslen(rest) + 64;
	line = malloc(size * sizeof *line);
	if (line == NULL)
		return (1);
	swprintf(line, size,
	    L"\"%ls\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile%ls",
	    system, rest);

	job = CreateJobObjectW(NULL, NULL);
	limit.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
	if (job == NULL || !SetInformationJobObject(job,
	    JobObjectExtendedLimitInformation, &limit, sizeof limit))
		return (1);
	if (!CreateProcessW(NULL, line, NULL, NULL, TRUE, CREATE_SUSPENDED,
	    NULL, NULL, &si, &pi)) {
		fwprintf(stderr, L"starting %ls: error %lu\n", line,
		    GetLastError());
		return (1);
	}
	if (!AssignProcessToJobObject(job, pi.hProcess)) {
		TerminateProcess(pi.hProcess, 1);
		return (1);
	}
	child = pi.hProcess;
	SetConsoleCtrlHandler(control, TRUE);
	ResumeThread(pi.hThread);
	CloseHandle(pi.hThread);

	WaitForSingleObject(pi.hProcess, INFINITE);
	if (!GetExitCodeProcess(pi.hProcess, &code))
		code = 1;
	return ((int)code);
}
