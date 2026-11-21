/*
 * The Win key pressed and released on its own is Win+` (TMUX-248), as
 * at-terminal's own hook makes it (ATT-16), so a tap summons at-terminal even
 * when none is running. Fed every key the hook sees except the keys a tap sends
 * (WIN32_WIN_TAP_TAG, at-terminal's tag too); true for the release that ends a
 * tap. was_down: the key was already held (a held key's repeat). modifier:
 * Ctrl, Alt or Shift is down.
 */
#ifndef TMUX_WIN_TAP_H
#define TMUX_WIN_TAP_H

#define WIN32_WIN_TAP_TAG 0x41545754 /* "ATWT" */
#define WIN32_WIN_TAP_LWIN 0x5b
#define WIN32_WIN_TAP_RWIN 0x5c

struct win32_win_tap {
	unsigned int	held;
	int		armed;
};

static int
win32_win_tap(struct win32_win_tap *gate, unsigned int vk, int down,
    int was_down, int modifier)
{
	int	tap;

	if (vk != WIN32_WIN_TAP_LWIN && vk != WIN32_WIN_TAP_RWIN) {
		if (down)
			gate->armed = 0;
		return (0);
	}
	if (down) {
		if (vk == gate->held && was_down)
			return (0);
		if (gate->held != 0 && gate->held != vk) {
			/* The other Win key while one is held: a chord. */
			gate->armed = 0;
			return (0);
		}
		/* A fresh press, or one after a release the hook never saw. */
		gate->held = vk;
		gate->armed = !modifier;
		return (0);
	}
	tap = gate->armed && vk == gate->held;
	gate->armed = 0;
	gate->held = 0;
	return (tap);
}

#endif
