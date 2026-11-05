/*
 * Process management for Windows.
 * Tracks child process handles and notifies the event loop when they exit.
 * Replaces SIGCHLD / waitpid() functionality.
 */

#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "win32-platform.h"
#include <shellapi.h>
#include <dbghelp.h>
#include <signal.h>

/* Defined in flight.c. */
void flight_crashed(const char *);

/* From appmodel.h, which needs more of windows.h than this platform header sets up. */
#define PACKAGE_FULL_NAME_MAX_LENGTH 127
LONG WINAPI GetCurrentPackageFullName(unsigned int *, wchar_t *);

#pragma comment(lib, "dbghelp.lib")

/* External: defined in win32-compat.c */
void win32_child_exited(pid_t pid, int status);

/* CreateProcess searches the parent's PATH even with a supplied environment.
 * Resolve an unqualified program against the child's PATH before starting it.
 * Explicit paths retain CreateProcess's existing command-line parsing. */
int
win32_child_application(const wchar_t *cmd, const char *env,
    wchar_t **application)
{
	wchar_t **argv, *path, *found, *inherited = NULL;
	const wchar_t *entry, *child_path = L"";
	wchar_t module[MAX_PATH], cwd[MAX_PATH], system[MAX_PATH], windows[MAX_PATH];
	size_t length;
	DWORD needed, error;
	int argc;

	*application = NULL;
	argv = CommandLineToArgvW(cmd, &argc);
	if (argv == NULL)
		return (0);
	if (argc == 0 || wcspbrk(argv[0], L"/\\:") != NULL) {
		LocalFree(argv);
		return (1);
	}
	if (env != NULL) {
		for (entry = (const wchar_t *)env; *entry != L'\0';
		    entry += wcslen(entry) + 1) {
			if (_wcsnicmp(entry, L"PATH=", 5) == 0) {
				child_path = entry + 5;
				break;
			}
		}
	} else {
		needed = GetEnvironmentVariableW(L"PATH", NULL, 0);
		if (needed != 0) {
			inherited = calloc(needed, sizeof *inherited);
			if (inherited == NULL)
				goto memory;
			GetEnvironmentVariableW(L"PATH", inherited, needed);
			child_path = inherited;
		}
	}
	module[0] = cwd[0] = system[0] = windows[0] = L'\0';
	needed = GetModuleFileNameW(NULL, module, MAX_PATH);
	if (needed != 0 && needed < MAX_PATH) {
		wchar_t *last = wcsrchr(module, L'\\');
		if (last != NULL)
			*last = L'\0';
	} else
		module[0] = L'\0';
	if (GetCurrentDirectoryW(MAX_PATH, cwd) >= MAX_PATH)
		cwd[0] = L'\0';
	if (GetSystemDirectoryW(system, MAX_PATH) >= MAX_PATH)
		system[0] = L'\0';
	if (GetWindowsDirectoryW(windows, MAX_PATH) >= MAX_PATH)
		windows[0] = L'\0';
	length = wcslen(child_path) + wcslen(module) + wcslen(cwd) +
	    wcslen(system) + wcslen(windows) + 5;
	path = calloc(length, sizeof *path);
	if (path == NULL)
		goto memory;
	swprintf_s(path, length, L"%ls;%ls;%ls;%ls;%ls", module, cwd, system,
	    windows, child_path);
	needed = SearchPathW(path, argv[0], L".exe", 0, NULL, NULL);
	if (needed == 0) {
		error = GetLastError();
		free(path);
		free(inherited);
		LocalFree(argv);
		SetLastError(error);
		return (0);
	}
	found = calloc(needed + 1, sizeof *found);
	if (found == NULL) {
		free(path);
		goto memory;
	}
	needed = SearchPathW(path, argv[0], L".exe", needed + 1, found, NULL);
	error = GetLastError();
	free(path);
	free(inherited);
	LocalFree(argv);
	if (needed == 0) {
		free(found);
		SetLastError(error);
		return (0);
	}
	*application = found;
	return (1);
memory:
	free(inherited);
	LocalFree(argv);
	SetLastError(ERROR_NOT_ENOUGH_MEMORY);
	return (0);
}

void fatalx(const char *, ...);

/*
 * Each child has a thread pool wait of its own, so any number can be watched and
 * one that has exited leaves nothing behind. The handle is the server's own copy.
 */
struct watched_process {
	HANDLE	 process;
	pid_t	 pid;
};

static VOID CALLBACK
process_exited(PTP_CALLBACK_INSTANCE instance, PVOID arg, PTP_WAIT wait,
    TP_WAIT_RESULT result)
{
	struct watched_process	*w = arg;
	DWORD			 code = 0;

	(void)instance;
	(void)result;

	GetExitCodeProcess(w->process, &code);
	CloseHandle(w->process);
	win32_child_exited(w->pid, (int)(code << 8));
	free(w);
	CloseThreadpoolWait(wait);

	win32_signal_notify(SIGCHLD);
}

void
win32_process_watch(HANDLE hProcess, pid_t pid)
{
	struct watched_process	*w;
	PTP_WAIT		 wait;

	if ((w = calloc(1, sizeof *w)) == NULL)
		fatalx("out of memory");
	w->pid = pid;
	if (!DuplicateHandle(GetCurrentProcess(), hProcess,
	    GetCurrentProcess(), &w->process, 0, FALSE, DUPLICATE_SAME_ACCESS))
		fatalx("can't watch process %ld: error %lu", (long)pid,
		    GetLastError());
	if ((wait = CreateThreadpoolWait(process_exited, w, NULL)) == NULL)
		fatalx("can't watch process %ld: error %lu", (long)pid,
		    GetLastError());
	SetThreadpoolWait(wait, w->process, NULL);
}

/*
 * A child's stdio is a pair of pipes, copied to and from the server's socket by
 * two threads. A program can't use a socket as its stdout (cmd.exe and pwsh
 * both exited 1 with no output), and the CRT can't take one either.
 */
struct spawn_bridge {
	HANDLE		 out;	/* read end of the child's stdout/stderr */
	HANDLE		 in;	/* write end of the child's stdin */
	SOCKET		 sock;
	volatile LONG	 refs;
};

static void
spawn_bridge_release(struct spawn_bridge *b)
{
	if (InterlockedDecrement(&b->refs) != 0)
		return;
	closesocket(b->sock);
	free(b);
}

/* Child output to the server; at EOF the socket closes and the job sees EOF. */
static DWORD WINAPI
spawn_bridge_out(LPVOID arg)
{
	struct spawn_bridge	*b = arg;
	char			 buf[4096];
	DWORD			 n;

	while (ReadFile(b->out, buf, sizeof buf, &n, NULL) && n != 0) {
		if (send(b->sock, buf, (int)n, 0) <= 0)
			break;
	}
	CloseHandle(b->out);
	shutdown(b->sock, SD_SEND);
	spawn_bridge_release(b);
	return (0);
}

/* Server input to the child (pipe-pane -O). */
static DWORD WINAPI
spawn_bridge_in(LPVOID arg)
{
	struct spawn_bridge	*b = arg;
	char			 buf[4096];
	DWORD			 written;
	int			 n;

	while ((n = recv(b->sock, buf, sizeof buf, 0)) > 0) {
		if (!WriteFile(b->in, buf, (DWORD)n, &written, NULL))
			break;
	}
	CloseHandle(b->in);
	spawn_bridge_release(b);
	return (0);
}

struct write_close {
	int	 fd;
	size_t	 len;
	char	 data[];
};

static DWORD WINAPI
write_close_thread(LPVOID arg)
{
	struct write_close	*wc = arg;
	size_t			 off = 0;
	int			 n;

	while (off < wc->len) {
		n = _write(wc->fd, wc->data + off, (unsigned int)(wc->len - off));
		if (n <= 0)
			break;
		off += n;
	}
	_close(wc->fd);
	free(wc);
	return (0);
}

/*
 * Write data to a pipe and close it, on a thread of its own: a write to a pipe
 * blocks once the pipe is full, until the reader catches up, and the reader is
 * a child the server must keep serving meanwhile. The fd belongs to the thread.
 */
void
win32_write_close(int fd, const void *data, size_t len)
{
	struct write_close	*wc;
	HANDLE			 thread;

	wc = malloc(sizeof *wc + len);
	if (wc == NULL) {
		_close(fd);
		return;
	}
	wc->fd = fd;
	wc->len = len;
	memcpy(wc->data, data, len);

	thread = CreateThread(NULL, 0, write_close_thread, wc, 0, NULL);
	if (thread == NULL) {
		_close(fd);
		free(wc);
		return;
	}
	CloseHandle(thread);
}

struct read_socket {
	int	 fd;
	SOCKET	 sock;
};

static DWORD WINAPI
read_socket_thread(LPVOID arg)
{
	struct read_socket	*rs = arg;
	HANDLE			 h = (HANDLE)_get_osfhandle(rs->fd);
	struct linger		 reset = { 1, 0 };
	char			 buf[8192];
	DWORD			 n, error = 0;

	for (;;) {
		if (!ReadFile(h, buf, sizeof buf, &n, NULL)) {
			error = GetLastError();
			break;
		}
		if (n == 0 || send(rs->sock, buf, (int)n, 0) != (int)n)
			break;
	}

	/* A broken pipe is its writer closing it; a reset tells a failure. */
	if (error != 0 && error != ERROR_BROKEN_PIPE) {
		setsockopt(rs->sock, SOL_SOCKET, SO_LINGER, (char *)&reset,
		    sizeof reset);
	}
	closesocket(rs->sock);
	_close(rs->fd);
	free(rs);
	return (0);
}

/*
 * Copy what an fd reads to a socket, on a thread of its own: a read can block
 * for as long as the writer likes, and libevent can only watch the socket.
 * Reading it gives the bytes as they arrive, end of file when the fd ends and
 * a connection reset when reading it fails. The fd belongs to the thread.
 * Returns the socket, nonblocking, or -1.
 */
int
win32_read_socket(int fd)
{
	struct read_socket	*rs;
	HANDLE			 thread;
	u_long			 nonblocking = 1;
	int			 sv[2];

	rs = malloc(sizeof *rs);
	if (rs == NULL || win32_socketpair(AF_INET, SOCK_STREAM, 0, sv) != 0) {
		free(rs);
		_close(fd);
		return (-1);
	}
	ioctlsocket((SOCKET)sv[0], FIONBIO, &nonblocking);
	rs->fd = fd;
	rs->sock = (SOCKET)sv[1];

	thread = CreateThread(NULL, 0, read_socket_thread, rs, 0, NULL);
	if (thread == NULL) {
		closesocket((SOCKET)sv[0]);
		closesocket((SOCKET)sv[1]);
		_close(fd);
		free(rs);
		return (-1);
	}
	CloseHandle(thread);
	return (sv[0]);
}

/*
 * Spawn a non-PTY process with its stdin, stdout and stderr connected to the
 * given socket. The socket then belongs to the bridge, which closes it when
 * the child is done; the caller must not close it. Returns the child PID on
 * success, -1 on failure (the caller still owns the socket). env is the child's
 * Unicode environment block, as used by the PTY launcher.
 */
pid_t
win32_process_spawn(const char *cmd, const char *cwd, char *env, int outfd)
{
	STARTUPINFOEXW si;
	PROCESS_INFORMATION pi;
	SECURITY_ATTRIBUTES sa;
	HANDLE outr = NULL, outw = NULL, inr = NULL, inw = NULL, threads[2];
	HANDLE inherit[2];
	struct spawn_bridge *b;
	SIZE_T attrsize = 0;
	wchar_t wcmd[32768], wcwd[MAX_PATH], *application = NULL;
	BOOL ok;

	memset(&sa, 0, sizeof sa);
	sa.nLength = sizeof sa;
	sa.bInheritHandle = TRUE;

	if (!CreatePipe(&outr, &outw, &sa, 0))
		return (-1);
	if (!CreatePipe(&inr, &inw, &sa, 0)) {
		CloseHandle(outr);
		CloseHandle(outw);
		return (-1);
	}
	SetHandleInformation(outr, HANDLE_FLAG_INHERIT, 0);
	SetHandleInformation(inw, HANDLE_FLAG_INHERIT, 0);

	/* The child inherits its two pipe ends and nothing else of the server's. */
	memset(&si, 0, sizeof si);
	si.StartupInfo.cb = sizeof si;
	si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
	si.StartupInfo.hStdInput = inr;
	si.StartupInfo.hStdOutput = outw;
	si.StartupInfo.hStdError = outw;
	inherit[0] = inr;
	inherit[1] = outw;
	InitializeProcThreadAttributeList(NULL, 1, 0, &attrsize);
	si.lpAttributeList = malloc(attrsize);
	ok = si.lpAttributeList != NULL &&
	    InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0,
	    &attrsize) &&
	    UpdateProcThreadAttribute(si.lpAttributeList, 0,
	    PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherit, sizeof inherit, NULL,
	    NULL);

	memset(&pi, 0, sizeof pi);
	if (!MultiByteToWideChar(CP_UTF8, 0, cmd, -1, wcmd, 32768))
		ok = FALSE;
	if (cwd != NULL && *cwd != '\0' &&
	    !MultiByteToWideChar(CP_UTF8, 0, cwd, -1, wcwd, MAX_PATH))
		ok = FALSE;
	if (ok && !win32_child_application(wcmd, env, &application))
		ok = FALSE;
	if (ok) {
		ok = CreateProcessW(application, wcmd, NULL, NULL, TRUE,
		    CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT |
		    CREATE_UNICODE_ENVIRONMENT, env,
		    (cwd != NULL && *cwd != '\0') ? wcwd : NULL,
		    &si.StartupInfo, &pi);
	}
	free(application);
	if (si.lpAttributeList != NULL) {
		DeleteProcThreadAttributeList(si.lpAttributeList);
		free(si.lpAttributeList);
	}
	CloseHandle(outw);
	CloseHandle(inr);
	if (!ok) {
		CloseHandle(outr);
		CloseHandle(inw);
		return (-1);
	}
	CloseHandle(pi.hThread);

	b = calloc(1, sizeof *b);
	b->out = outr;
	b->in = inw;
	b->sock = (SOCKET)outfd;
	b->refs = 2;
	threads[0] = CreateThread(NULL, 0, spawn_bridge_out, b, 0, NULL);
	threads[1] = CreateThread(NULL, 0, spawn_bridge_in, b, 0, NULL);
	CloseHandle(threads[0]);
	CloseHandle(threads[1]);

	/* Watch the process for exit. */
	win32_process_watch(pi.hProcess, (pid_t)pi.dwProcessId);
	CloseHandle(pi.hProcess);

	return ((pid_t)pi.dwProcessId);
}

/*
 * On a crash, write the faulting call stack to stderr, the log and
 * %TEMP%\tmux-crash-<pid>.log, with function names and lines from the PDB
 * beside the exe. Without it the server died silently, with no debugger
 * installed to say where; a server started detached, or by upgrade-server, has
 * no stderr and usually no log.
 */
void log_debug(const char *, ...);

/*
 * dbghelp's default search leaves out the exe's folder, and the path stored in
 * the exe is the build machine's. The folder is resolved at startup because a
 * release runs through a junction home-sync moves to the next release while
 * this server keeps running, and that release's PDB doesn't match.
 */
static char win32_crash_symbols[MAX_PATH];

static void
win32_crash_report(const char *what, const CONTEXT *context)
{
	HANDLE			 proc = GetCurrentProcess(), thread = GetCurrentThread();
	CONTEXT			 ctx = *context;
	STACKFRAME64		 frame;
	char			 symbuf[sizeof(SYMBOL_INFO) + 256];
	SYMBOL_INFO		*sym = (SYMBOL_INFO *)symbuf;
	IMAGEHLP_LINE64		 line;
	DWORD64			 disp64;
	DWORD			 disp;
	char			 out[1024], path[MAX_PATH];
	size_t			 len;
	int			 i;
	FILE			*f = NULL;
	DWORD			 n;

	n = GetTempPathA(sizeof path, path);
	if (n != 0 && n < sizeof path - 32) {
		snprintf(path + n, sizeof path - n, "tmux-crash-%lu.log",
		    GetCurrentProcessId());
		f = fopen(path, "w");
	}

	flight_crashed(what);
	snprintf(out, sizeof out, "tmux crashed: %s", what);
	fprintf(stderr, "%s\n", out);
	if (f != NULL)
		fprintf(f, "%s\n", out);
	log_debug("%s", out);
	SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_UNDNAME);
	SymInitialize(proc, win32_crash_symbols[0] != '\0' ?
	    win32_crash_symbols : NULL, TRUE);

	memset(&frame, 0, sizeof frame);
	frame.AddrPC.Offset = ctx.Rip;
	frame.AddrPC.Mode = AddrModeFlat;
	frame.AddrFrame.Offset = ctx.Rbp;
	frame.AddrFrame.Mode = AddrModeFlat;
	frame.AddrStack.Offset = ctx.Rsp;
	frame.AddrStack.Mode = AddrModeFlat;
	for (i = 0; i < 32; i++) {
		if (!StackWalk64(IMAGE_FILE_MACHINE_AMD64, proc, thread, &frame,
		    &ctx, NULL, SymFunctionTableAccess64, SymGetModuleBase64, NULL))
			break;
		memset(symbuf, 0, sizeof symbuf);
		sym->SizeOfStruct = sizeof(SYMBOL_INFO);
		sym->MaxNameLen = 255;
		memset(&line, 0, sizeof line);
		line.SizeOfStruct = sizeof line;
		len = snprintf(out, sizeof out, "  #%d %s", i,
		    SymFromAddr(proc, frame.AddrPC.Offset, &disp64, sym) ?
		    sym->Name : "?");
		if (len < sizeof out &&
		    SymGetLineFromAddr64(proc, frame.AddrPC.Offset, &disp, &line))
			snprintf(out + len, sizeof out - len, " %s:%lu",
			    line.FileName, line.LineNumber);
		fprintf(stderr, "%s\n", out);
		if (f != NULL)
			fprintf(f, "%s\n", out);
		log_debug("%s", out);
	}
	if (f != NULL)
		fclose(f);
	fflush(NULL);
}

static LONG WINAPI
win32_crash_handler(EXCEPTION_POINTERS *ep)
{
	char	 what[64];

	snprintf(what, sizeof what, "exception 0x%08lx at %p",
	    ep->ExceptionRecord->ExceptionCode,
	    ep->ExceptionRecord->ExceptionAddress);
	win32_crash_report(what, ep->ContextRecord);
	return (EXCEPTION_CONTINUE_SEARCH);
}

/*
 * The C runtime reports a bad argument, and abort(), without raising an
 * exception, so the handler above never sees them. Ending in a fail-fast keeps
 * the crash dump Windows writes for one.
 */
static void
win32_invalid_parameter(const wchar_t *expression, const wchar_t *function,
    const wchar_t *file, unsigned int line, uintptr_t reserved)
{
	CONTEXT	 ctx;

	(void)expression;
	(void)function;
	(void)file;
	(void)line;
	(void)reserved;
	RtlCaptureContext(&ctx);
	win32_crash_report("invalid argument to a C runtime function", &ctx);
	__fastfail(FAST_FAIL_INVALID_ARG);
}

static void
win32_abort(int sig)
{
	CONTEXT	 ctx;

	(void)sig;
	RtlCaptureContext(&ctx);
	signal(SIGABRT, SIG_DFL);
	win32_crash_report("abort", &ctx);
}

void
win32_crash_init(void)
{
	char	 path[MAX_PATH], *slash;
	HANDLE	 h;
	DWORD	 n;

	SetUnhandledExceptionFilter(win32_crash_handler);
	_set_invalid_parameter_handler(win32_invalid_parameter);
	signal(SIGABRT, win32_abort);

	n = GetModuleFileNameA(NULL, path, sizeof path);
	if (n == 0 || n >= sizeof path)
		return;
	h = CreateFileA(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE |
	    FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
	if (h == INVALID_HANDLE_VALUE)
		return;
	n = GetFinalPathNameByHandleA(h, path, sizeof path, VOLUME_NAME_DOS);
	CloseHandle(h);
	if (n == 0 || n >= sizeof path ||
	    (slash = strrchr(path, '\\')) == NULL)
		return;
	*slash = '\0';
	snprintf(win32_crash_symbols, sizeof win32_crash_symbols, "%s",
	    strncmp(path, "\\\\?\\", 4) == 0 ? path + 4 : path);
}

#ifndef PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY
#define PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY ProcThreadAttributeValue(18, FALSE, TRUE, FALSE)
#endif
#ifndef PROCESS_CREATION_DESKTOP_APP_BREAKAWAY_ENABLE_PROCESS_TREE
#define PROCESS_CREATION_DESKTOP_APP_BREAKAWAY_ENABLE_PROCESS_TREE 0x1
#endif

/*
 * A child of a packaged desktop app stays in the app's container, even though
 * CREATE_BREAKAWAY_FROM_JOB reports success, and the app's next update ends it
 * with the app. This policy is what takes a child out.
 */
void
win32_leave_package(LPPROC_THREAD_ATTRIBUTE_LIST list)
{
	static DWORD	 policy =
	    PROCESS_CREATION_DESKTOP_APP_BREAKAWAY_ENABLE_PROCESS_TREE;

	UpdateProcThreadAttribute(list, 0,
	    PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY, &policy, sizeof policy,
	    NULL, NULL);
}

/* What this process runs inside: a package or job can end it with no warning. */
void
win32_origin(char *buf, size_t size)
{
	wchar_t	 package[PACKAGE_FULL_NAME_MAX_LENGTH + 1];
	unsigned int	 length = PACKAGE_FULL_NAME_MAX_LENGTH + 1;
	BOOL	 job = FALSE;

	IsProcessInJob(GetCurrentProcess(), NULL, &job);
	if (GetCurrentPackageFullName(&length, package) == ERROR_SUCCESS) {
		snprintf(buf, size, "package %ls, %s", package,
		    job ? "in a job" : "no job");
	} else
		snprintf(buf, size, "no package, %s", job ? "in a job" : "no job");
}

/* Defined in cfg.c. */
extern char **cfg_files;
extern unsigned int cfg_nfiles;
extern int cfg_quiet;
int log_get_level(void);

/*
 * Launch a detached tmux server process.
 * Runs: tmux.exe [-v...] -D -S "<label>" [-f "<file>"]...
 * The -D flag tells tmux to run as a foreground server (no fork).
 * On Unix the forked server inherits cfg_files; here they must be passed on
 * the command line, or a client's -f files never reach the server. cfg_quiet
 * is clear only when -f was given.
 */
void
win32_launch_server(const char *label)
{
	STARTUPINFOEXA si;
	PROCESS_INFORMATION pi;
	char exe[MAX_PATH];
	char cmdline[8192];
	SIZE_T size = 0;
	size_t len;
	unsigned int i;
	DWORD flags = DETACHED_PROCESS | CREATE_NO_WINDOW |
	    EXTENDED_STARTUPINFO_PRESENT;

	if (GetModuleFileNameA(NULL, exe, sizeof exe) == 0)
		return;

	len = snprintf(cmdline, sizeof cmdline,
	    "\"%s\" %s%s-D -S \"%s\"", exe, log_get_level() > 0 ? "-v " : "",
	    log_get_level() > 1 ? "-v " : "", label);
	for (i = 0; !cfg_quiet && i < cfg_nfiles && len < sizeof cmdline; i++)
		len += snprintf(cmdline + len, sizeof cmdline - len,
		    " -f \"%s\"", cfg_files[i]);
	if (len >= sizeof cmdline)
		return;

	memset(&si, 0, sizeof si);
	si.StartupInfo.cb = sizeof si;
	memset(&pi, 0, sizeof pi);
	InitializeProcThreadAttributeList(NULL, 1, 0, &size);
	if ((si.lpAttributeList = malloc(size)) == NULL ||
	    !InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &size)) {
		free(si.lpAttributeList);
		return;
	}
	win32_leave_package(si.lpAttributeList);

	/*
	 * CREATE_BREAKAWAY_FROM_JOB detaches the server from any job object
	 * the parent belongs to (e.g., sshd's session job). Without this,
	 * closing an SSH connection kills the tmux server along with all
	 * processes in the job. Fall back without the flag if the job
	 * doesn't allow breakaway (ERROR_ACCESS_DENIED).
	 */
	if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE,
	    flags | CREATE_BREAKAWAY_FROM_JOB, NULL, NULL, &si.StartupInfo,
	    &pi)) {
		if (GetLastError() != ERROR_ACCESS_DENIED ||
		    !CreateProcessA(NULL, cmdline, NULL, NULL, FALSE, flags,
		    NULL, NULL, &si.StartupInfo, &pi)) {
			DeleteProcThreadAttributeList(si.lpAttributeList);
			free(si.lpAttributeList);
			return;
		}
	}
	DeleteProcThreadAttributeList(si.lpAttributeList);
	free(si.lpAttributeList);

	CloseHandle(pi.hThread);
	CloseHandle(pi.hProcess);
}
