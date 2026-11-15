/* A taken Tab keeps its release, even when focus or modifiers change. */
#ifndef TMUX_ALT_TAB_H
#define TMUX_ALT_TAB_H

static int
win32_alt_tab_take(int *taken, int down, int alt, int ctrl, int win,
    int shifted, int enabled)
{
	if (!down) {
		int release = *taken;
		*taken = 0;
		return (release);
	}
	if (*taken)
		return (1);
	if (alt && !ctrl && !win && (enabled & (shifted ? 2 : 1))) {
		*taken = 1;
		return (2);
	}
	return (0);
}

#endif
