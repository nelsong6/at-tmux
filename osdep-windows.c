/*
 * OS-dependent functions for Windows.
 * Implements osdep_get_name(), osdep_get_cwd(), osdep_event_init(), and the
 * pid-based win32_pane_command() that format.c uses here instead.
 */

#ifdef _WIN32

#include <sys/types.h>
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#include "tmux.h"

#include <windows.h>
#include <tlhelp32.h>
#include "win32/alt-tab.h"
#include "win32/win-tap.h"

/*
 * A pane's fd is a socket bridged from ConPTY and names no process; format.c
 * calls win32_pane_command() with the pane's pid instead.
 */
char *
osdep_get_name(int fd, char *tty)
{
	(void)fd;
	(void)tty;
	return (NULL);
}

static ULONGLONG
win32_process_start(DWORD pid)
{
	HANDLE		h;
	FILETIME	created, exited, kernel, user;
	ULONGLONG	t = 0;

	h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
	if (h == NULL)
		return (0);
	if (GetProcessTimes(h, &created, &exited, &kernel, &user))
		t = ((ULONGLONG)created.dwHighDateTime << 32) | created.dwLowDateTime;
	CloseHandle(h);
	return (t);
}

/*
 * The name of what a pane is running. On Unix tmux names the terminal's
 * foreground process group; a job the shell starts leads its own group, and
 * that job's children stay in it. The equivalent here is the shell's newest
 * child, else the shell itself: Claude Code stays "claude" while it runs
 * commands of its own. conhost.exe, ConPTY's host, is not a job. A child must
 * have started after the shell, or its parent pid was reused.
 */
char *
win32_pane_command(pid_t pid)
{
	HANDLE		 snap;
	PROCESSENTRY32W	 pe;
	ULONGLONG	 shell_start, start, best_start = 0;
	WCHAR		 shell_name[MAX_PATH] = L"", best[MAX_PATH] = L"";
	char		 name[MAX_PATH * 3], *dot;

	if (pid <= 0)
		return (NULL);
	shell_start = win32_process_start((DWORD)pid);

	snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
	if (snap == INVALID_HANDLE_VALUE)
		return (NULL);
	pe.dwSize = sizeof pe;
	for (BOOL ok = Process32FirstW(snap, &pe); ok;
	    ok = Process32NextW(snap, &pe)) {
		if (pe.th32ProcessID == (DWORD)pid) {
			wcscpy_s(shell_name, MAX_PATH, pe.szExeFile);
			continue;
		}
		if (pe.th32ParentProcessID != (DWORD)pid ||
		    _wcsicmp(pe.szExeFile, L"conhost.exe") == 0)
			continue;
		start = win32_process_start(pe.th32ProcessID);
		if (start < shell_start || start <= best_start)
			continue;
		best_start = start;
		wcscpy_s(best, MAX_PATH, pe.szExeFile);
	}
	CloseHandle(snap);

	if (*best == L'\0')
		wcscpy_s(best, MAX_PATH, shell_name);
	if (*best == L'\0')
		return (NULL);
	WideCharToMultiByte(CP_UTF8, 0, best, -1, name, sizeof name, NULL, NULL);
	if ((dot = strrchr(name, '.')) != NULL && _stricmp(dot, ".exe") == 0)
		*dot = '\0';
	return (xstrdup(name));
}

/*
 * win32_pane_command for many panes from one look at the process table, so a
 * session-set snapshot costs one snapshot however many panes there are.
 * names[i] is NULL where pids[i] has no name.
 */
void
win32_pane_commands(pid_t *pids, u_int n, char **names)
{
	HANDLE		 snap;
	PROCESSENTRY32W	 pe;
	ULONGLONG	*shell_start, *best_start, start;
	WCHAR		(*shell_name)[MAX_PATH], (*best)[MAX_PATH];
	char		 name[MAX_PATH * 3], *dot;
	u_int		 i;

	for (i = 0; i < n; i++)
		names[i] = NULL;
	if (n == 0)
		return;
	snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
	if (snap == INVALID_HANDLE_VALUE)
		return;

	shell_start = xcalloc(n, sizeof *shell_start);
	best_start = xcalloc(n, sizeof *best_start);
	shell_name = xcalloc(n, sizeof *shell_name);
	best = xcalloc(n, sizeof *best);
	for (i = 0; i < n; i++)
		shell_start[i] = win32_process_start((DWORD)pids[i]);

	pe.dwSize = sizeof pe;
	for (BOOL ok = Process32FirstW(snap, &pe); ok;
	    ok = Process32NextW(snap, &pe)) {
		for (i = 0; i < n; i++) {
			if (pids[i] <= 0)
				continue;
			if (pe.th32ProcessID == (DWORD)pids[i]) {
				wcscpy_s(shell_name[i], MAX_PATH, pe.szExeFile);
				continue;
			}
			if (pe.th32ParentProcessID != (DWORD)pids[i] ||
			    _wcsicmp(pe.szExeFile, L"conhost.exe") == 0)
				continue;
			start = win32_process_start(pe.th32ProcessID);
			if (start < shell_start[i] || start <= best_start[i])
				continue;
			best_start[i] = start;
			wcscpy_s(best[i], MAX_PATH, pe.szExeFile);
		}
	}
	CloseHandle(snap);

	for (i = 0; i < n; i++) {
		if (*best[i] == L'\0')
			wcscpy_s(best[i], MAX_PATH, shell_name[i]);
		if (*best[i] == L'\0')
			continue;
		WideCharToMultiByte(CP_UTF8, 0, best[i], -1, name, sizeof name,
		    NULL, NULL);
		if ((dot = strrchr(name, '.')) != NULL &&
		    _stricmp(dot, ".exe") == 0)
			*dot = '\0';
		names[i] = xstrdup(name);
	}
	free(best);
	free(shell_name);
	free(best_start);
	free(shell_start);
}

/*
 * Does pid descend from ancestor, or is it ancestor? Each parent must have
 * started before its child, or the child's parent pid was reused by a later
 * process and the chain ends there.
 */
int
win32_pid_descends(pid_t pid, pid_t ancestor)
{
	HANDLE		 snap;
	PROCESSENTRY32W	 pe;
	DWORD		 cur, parent;
	ULONGLONG	 cur_start, parent_start;
	int		 found, depth;

	if (pid <= 0 || ancestor <= 0)
		return (0);
	if (pid == ancestor)
		return (1);
	snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
	if (snap == INVALID_HANDLE_VALUE)
		return (0);
	cur = (DWORD)pid;
	cur_start = win32_process_start(cur);
	for (depth = 0; depth < 64; depth++) {
		found = 0;
		pe.dwSize = sizeof pe;
		for (BOOL ok = Process32FirstW(snap, &pe); ok;
		    ok = Process32NextW(snap, &pe)) {
			if (pe.th32ProcessID == cur) {
				found = 1;
				break;
			}
		}
		if (!found || (parent = pe.th32ParentProcessID) == 0 ||
		    parent == cur)
			break;
		parent_start = win32_process_start(parent);
		if (parent_start == 0 ||
		    (cur_start != 0 && parent_start > cur_start))
			break;
		if (parent == (DWORD)ancestor) {
			CloseHandle(snap);
			return (1);
		}
		cur = parent;
		cur_start = parent_start;
	}
	CloseHandle(snap);
	return (0);
}

/*
 * A process's working directory sits in its PEB, and pwsh's Set-Location
 * doesn't change it anyway; format.c falls back to the folder the pane
 * reports itself (OSC 7).
 */
char *
osdep_get_cwd(int fd)
{
	(void)fd;
	return (NULL);
}

/*
 * Initialize the event system.
 */
struct event_base *
osdep_event_init(void)
{
	return (event_init());
}

/*
 * Are all the modifiers in a key still physically held? Terminals report
 * presses, not releases, so this asks Windows for the keyboard of the desktop
 * the server runs on.
 */
int
desktop_modifiers_held(key_code modifiers)
{
	if ((modifiers & KEYC_CTRL) && !(GetAsyncKeyState(VK_CONTROL) & 0x8000))
		return (0);
	if ((modifiers & KEYC_META) && !(GetAsyncKeyState(VK_MENU) & 0x8000))
		return (0);
	if ((modifiers & KEYC_SHIFT) && !(GetAsyncKeyState(VK_SHIFT) & 0x8000))
		return (0);
	return (1);
}

/*
 * Keys pressed anywhere on the desktop with the Windows key held, for the
 * global key table. A low-level keyboard hook sees them before Windows hands
 * out hotkeys and passes Win keys on, so a key another program registered
 * (Windows Terminal's summon) still reaches it. Bound Alt+Tab keys are taken
 * from Windows, and with Win+` bound a lone Win tap is Win+`. The hook's
 * thread writes each
 * key to a socket that the event loop reads. Every other key goes the same way
 * with no key_code, for the key trace: only that one went down, and when.
 */
static SOCKET		global_keys[2] = { INVALID_SOCKET, INVALID_SOCKET };
static struct event	global_keys_event;
static DWORD		global_keys_down; /* held key, to skip auto-repeat */
static volatile LONG	global_alt_tab;
static int		global_alt_tab_down;
static volatile LONG	global_win_tap; /* Win+` is bound */
static struct win32_win_tap global_win_tap_gate;

/*
 * What the hook sends for each key: the key, and the process owning the
 * window in the foreground when it was pressed (0 if none). A low-level hook
 * that takes long is skipped by Windows, so the hook only asks for the
 * window's process; key_bindings_global works out whether it is the client's
 * terminal.
 */
struct win32_global_key {
	key_code	key;
	uint64_t	at;
	DWORD		foreground;
};

/* The key a virtual key types, unshifted, with the modifiers held. */
static key_code
win32_global_key(DWORD vk)
{
	UINT		ch;
	key_code	key;

	ch = MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR) & 0x7fffffff;
	if (ch <= ' ' || ch > '~')
		return (KEYC_NONE);
	key = tolower(ch) | KEYC_SUPER;
	if (GetAsyncKeyState(VK_CONTROL) & 0x8000)
		key |= KEYC_CTRL;
	if (GetAsyncKeyState(VK_MENU) & 0x8000)
		key |= KEYC_META;
	if (GetAsyncKeyState(VK_SHIFT) & 0x8000)
		key |= KEYC_SHIFT;
	return (key);
}

/* Does this virtual key only change what other keys mean, typing nothing? */
static int
win32_key_is_modifier(DWORD vk)
{
	switch (vk) {
	case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT:
	case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL:
	case VK_MENU: case VK_LMENU: case VK_RMENU:
	case VK_LWIN: case VK_RWIN:
	case VK_CAPITAL: case VK_NUMLOCK: case VK_SCROLL:
		return (1);
	}
	return (0);
}

/* Never blocks: a hook that does holds up the keyboard of the whole desktop. */
static int
win32_global_keys_send(key_code key)
{
	struct win32_global_key	 gk;
	HWND			 fg;

	gk.key = key;
	gk.at = get_timer();
	gk.foreground = 0;
	if ((fg = GetForegroundWindow()) != NULL)
		GetWindowThreadProcessId(fg, &gk.foreground);
	return (send(global_keys[1], (char *)&gk, sizeof gk, 0) == sizeof gk);
}

/* One key of a tap's Win+`, marked as the tap's. */
static void
win32_global_win_tap_key(INPUT *in, WORD vk, WORD scan, DWORD flags)
{
	memset(in, 0, sizeof *in);
	in->type = INPUT_KEYBOARD;
	in->ki.wVk = vk;
	in->ki.wScan = scan;
	in->ki.dwFlags = flags;
	in->ki.dwExtraInfo = WIN32_WIN_TAP_TAG;
}

/*
 * The Win key tapped on its own is Win+`, as at-terminal's hook makes it, so a
 * tap summons at-terminal when none is running to catch it (TMUX-248). The
 * tap's release is held back and sent again behind a press and release of `,
 * so this hook and anything else answering Win+` (at-terminal's hotkey) see
 * one, and Windows, seeing a key between Win's press and release, keeps Start
 * shut. With at-terminal running too, whichever hook sees the release first
 * sends the keys and the other passes them by their tag. True if the release
 * was taken.
 */
static int
win32_global_win_tap(KBDLLHOOKSTRUCT *k, int down)
{
	INPUT	in[3];
	int	modifier;

	modifier = !!((GetAsyncKeyState(VK_CONTROL) |
	    GetAsyncKeyState(VK_MENU) | GetAsyncKeyState(VK_SHIFT)) & 0x8000);
	if (!win32_win_tap(&global_win_tap_gate, k->vkCode, down,
	    !!(GetAsyncKeyState(k->vkCode) & 0x8000), modifier))
		return (0);

	win32_global_win_tap_key(&in[0], VK_OEM_3, 0x29, 0);
	win32_global_win_tap_key(&in[1], VK_OEM_3, 0x29, KEYEVENTF_KEYUP);
	win32_global_win_tap_key(&in[2], (WORD)k->vkCode, (WORD)k->scanCode,
	    KEYEVENTF_KEYUP|KEYEVENTF_EXTENDEDKEY);
	if (SendInput(3, in, sizeof in[0]) == 3)
		return (1);

	/* Refused: the release goes on (Start opens too) and Win+` runs. */
	win32_global_keys_send('`'|KEYC_SUPER);
	return (0);
}

static LRESULT CALLBACK
win32_global_keys_hook(int code, WPARAM wp, LPARAM lp)
{
	KBDLLHOOKSTRUCT	*k = (KBDLLHOOKSTRUCT *)lp;
	key_code	 key;

	if (code != HC_ACTION)
		return (CallNextHookEx(NULL, code, wp, lp));
	if (InterlockedCompareExchange(&global_win_tap, 0, 0) &&
	    k->dwExtraInfo != WIN32_WIN_TAP_TAG &&
	    win32_global_win_tap(k, wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN))
		return (1);
	if (k->vkCode == VK_TAB) {
		int shifted = !!(GetAsyncKeyState(VK_SHIFT) & 0x8000);
		int take = win32_alt_tab_take(&global_alt_tab_down,
		    wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN,
		    !!(k->flags & LLKHF_ALTDOWN),
		    !!(GetAsyncKeyState(VK_CONTROL) & 0x8000),
		    !!((GetAsyncKeyState(VK_LWIN) |
		    GetAsyncKeyState(VK_RWIN)) & 0x8000), shifted,
		    InterlockedCompareExchange(&global_alt_tab, 0, 0));

		if (take == 1)
			return (1);
		if (take == 2) {
			key = (shifted ? KEYC_BTAB : '\t') | KEYC_META;
			if (win32_global_keys_send(key))
				return (1);
			global_alt_tab_down = 0;
		}
	}
	if (wp == WM_KEYUP || wp == WM_SYSKEYUP) {
		if (k->vkCode == global_keys_down)
			global_keys_down = 0;
	} else if ((GetAsyncKeyState(VK_LWIN) | GetAsyncKeyState(VK_RWIN)) & 0x8000) {
		if (k->vkCode != global_keys_down) {
			key = win32_global_key(k->vkCode);
			if (key != KEYC_NONE) {
				global_keys_down = k->vkCode;
				win32_global_keys_send(key);
			}
		}
	} else if (!win32_key_is_modifier(k->vkCode))
		win32_global_keys_send(KEYC_NONE);
	return (CallNextHookEx(NULL, code, wp, lp));
}

static DWORD WINAPI
win32_global_keys_thread(LPVOID arg)
{
	MSG	msg;

	(void)arg;
	if (SetWindowsHookExW(WH_KEYBOARD_LL, win32_global_keys_hook,
	    GetModuleHandleW(NULL), 0) == NULL)
		return (0);
	while (GetMessageW(&msg, NULL, 0, 0) > 0)
		/* nothing */;
	return (0);
}

static void
win32_global_keys_read(evutil_socket_t fd, __unused short events,
    __unused void *arg)
{
	struct win32_global_key	gk;

	if (recv((SOCKET)fd, (char *)&gk, sizeof gk, MSG_WAITALL) != sizeof gk)
		return;
	if (gk.key == KEYC_NONE)
		key_trace_pressed(gk.at, (pid_t)gk.foreground);
	else
		key_bindings_global(gk.key, (pid_t)gk.foreground);
}

/*
 * Start the hook, once, when the global table first gets a key. The hook sees
 * every key, so there is nothing to do for each one.
 */
void
desktop_global_key_add(key_code key)
{
	int	sv[2];
	HANDLE	thread;
	u_long	nonblocking = 1;

	if (key == ('\t' | KEYC_META))
		InterlockedOr(&global_alt_tab, 1);
	else if (key == (KEYC_BTAB | KEYC_META))
		InterlockedOr(&global_alt_tab, 2);
	else if (key == ('`' | KEYC_SUPER))
		InterlockedExchange(&global_win_tap, 1);

	if (global_keys[0] != INVALID_SOCKET)
		return;
	if (win32_socketpair(AF_INET, SOCK_STREAM, 0, sv) != 0)
		return;
	global_keys[0] = (SOCKET)sv[0];
	global_keys[1] = (SOCKET)sv[1];
	ioctlsocket(global_keys[1], FIONBIO, &nonblocking);
	event_set(&global_keys_event, sv[0], EV_READ|EV_PERSIST,
	    win32_global_keys_read, NULL);
	event_add(&global_keys_event, NULL);
	thread = CreateThread(NULL, 0, win32_global_keys_thread, NULL, 0, NULL);
	if (thread != NULL)
		CloseHandle(thread);
}

/* Stop taking Alt+Tab or the Win tap as soon as its global binding goes. */
void
desktop_global_key_remove(key_code key)
{
	if (key == ('\t' | KEYC_META))
		InterlockedAnd(&global_alt_tab, ~1L);
	else if (key == (KEYC_BTAB | KEYC_META))
		InterlockedAnd(&global_alt_tab, ~2L);
	else if (key == ('`' | KEYC_SUPER))
		InterlockedExchange(&global_win_tap, 0);
}

#endif /* _WIN32 */
