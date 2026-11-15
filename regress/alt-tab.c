#include <stdio.h>
#include <stdlib.h>
#include "../win32/alt-tab.h"

#define CHECK(e) do { if (!(e)) { \
	fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #e); exit(1); \
} } while (0)

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
	return (0);
}
