/* The keyboard hook's gates: Alt+Tab, and the Win tap (TMUX-248). */
#include <stdio.h>
#include <stdlib.h>
#include "../win32/alt-tab.h"
#include "../win32/win-tap.h"

#define CHECK(e) do { if (!(e)) { \
	fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #e); exit(1); \
} } while (0)

#define LWIN WIN32_WIN_TAP_LWIN
#define RWIN WIN32_WIN_TAP_RWIN
#define TAP(vk, down, was, mod) win32_win_tap(&gate, (vk), (down), (was), (mod))

static void
win_tap(void)
{
	struct win32_win_tap	gate = { 0 };

	/* A tap, twice: the gate starts over after each. */
	CHECK(!TAP(LWIN, 1, 0, 0));
	CHECK(TAP(LWIN, 0, 1, 0));
	CHECK(!TAP(LWIN, 1, 0, 0));
	CHECK(TAP(LWIN, 0, 1, 0));

	/* The right Win key taps too, and a held Win's repeats still tap. */
	CHECK(!TAP(RWIN, 1, 0, 0));
	CHECK(!TAP(RWIN, 1, 1, 0));
	CHECK(!TAP(RWIN, 1, 1, 0));
	CHECK(TAP(RWIN, 0, 1, 0));

	/* Win+L and Win+Shift+S stay Windows'. */
	CHECK(!TAP(LWIN, 1, 0, 0));
	CHECK(!TAP('L', 1, 0, 0));
	CHECK(!TAP('L', 0, 1, 0));
	CHECK(!TAP(LWIN, 0, 1, 0));
	CHECK(!TAP(LWIN, 1, 0, 0));
	CHECK(!TAP(0xa0, 1, 0, 0));
	CHECK(!TAP(0xa0, 0, 1, 0));
	CHECK(!TAP(LWIN, 0, 1, 0));

	/* Ctrl, Alt or Shift held as Win goes down, even if let go first. */
	CHECK(!TAP(LWIN, 1, 0, 1));
	CHECK(!TAP(LWIN, 0, 1, 1));
	CHECK(!TAP(LWIN, 1, 0, 1));
	CHECK(!TAP(LWIN, 0, 1, 0));

	/* Both Win keys are a chord, and the next tap still works. */
	CHECK(!TAP(LWIN, 1, 0, 0));
	CHECK(!TAP(RWIN, 1, 0, 0));
	CHECK(!TAP(RWIN, 0, 1, 0));
	CHECK(!TAP(LWIN, 0, 1, 0));
	CHECK(!TAP(LWIN, 1, 0, 0));
	CHECK(TAP(LWIN, 0, 1, 0));

	/* A key let go while Win is down isn't a new key. */
	CHECK(!TAP(LWIN, 1, 0, 0));
	CHECK(!TAP('A', 0, 1, 0));
	CHECK(TAP(LWIN, 0, 1, 0));

	/*
	 * A release the hook never sees (the lock screen's, or at-terminal's hook
	 * taking the tap first): the next press is fresh.
	 */
	CHECK(!TAP(LWIN, 1, 0, 0));
	CHECK(!TAP(LWIN, 1, 0, 0));
	CHECK(TAP(LWIN, 0, 1, 0));
	puts("PASS: Win tap alone, chords, modifiers, repeat and missed release");
}

int
main(void)
{
	int taken = 0, alt, ctrl, win, shift, enabled;

	for (alt = 0; alt < 2; alt++)
	for (ctrl = 0; ctrl < 2; ctrl++)
	for (win = 0; win < 2; win++)
	for (shift = 0; shift < 2; shift++)
	for (enabled = 0; enabled < 4; enabled++) {
		int expected = alt && !ctrl && !win &&
		    (enabled & (shift ? 2 : 1));
		CHECK(win32_alt_tab_take(&taken, 1, alt, ctrl, win,
		    shift, enabled) == (expected ? 2 : 0));
		if (expected)
			CHECK(win32_alt_tab_take(&taken, 1, 0, 1, 1, 0, 0) == 1);
		CHECK(win32_alt_tab_take(&taken, 0, 0, 0, 0, 0, 0) ==
		    (expected ? 1 : 0));
		CHECK(!taken);
		CHECK(win32_alt_tab_take(&taken, 0, 1, 0, 0, 0, 3) == 0);
	}
	puts("PASS: Alt+Tab modifiers, registration, repeat and release");
	win_tap();
	return (0);
}
