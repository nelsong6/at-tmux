/* Native, client-local side panels. No pane program or saved layout is created. */
#include <sys/types.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <unistd.h>
#endif
#include "tmux.h"

static u_int
panel_min(u_int a, u_int b)
{
	return (a < b ? a : b);
}

static uint64_t panel_next_generation;

/* The panel stays this wide, and leaves the window this much of the terminal. */
#define PANEL_WIDTH_MINIMUM 24
#define PANEL_WINDOW_MINIMUM 30

struct panel_line {
	char *text;
	u_int item;
};

struct panel_data {
	struct menu *menu;
	struct screen screen;
	struct panel_line *lines;
	u_int nlines;
	u_int width;
	u_int source;
	char *generation;
	u_int top;
	u_int tabs;
	int choice;
	int focused;
	int resizing;

	/*
	 * Text selected with the mouse, as on a webpage: a press marks where it
	 * starts, a drag selects to the mouse, and the release copies it. A press
	 * and release with no drag is a click. Points are a line and a column of
	 * its text, so the selection scrolls with the rows.
	 */
	int pressed;
	int dragged;
	int selected;
	u_int sel_width;
	u_int sel_line[2];
	u_int sel_col[2];
	uint64_t click_time;
	u_int click_line;
	u_int click_col;
	u_int clicks;
};

static int panel_sel_range(struct panel_data *, u_int *, u_int *, u_int *,
    u_int *);

u_int
panel_width(struct client *c)
{
	struct window_pane *wp;
	u_int width;

	if (c->panel == NULL || c->session == NULL || c->session->curw == NULL ||
	    c->tty.sx < 50 || c->tty.sy < status_line_size(c) + 6)
		return (0);
	wp = window_pane_find_by_id(c->panel->source);
	if (wp == NULL || wp->window != c->session->curw->window)
		return (0);
	width = options_get_number(global_options, "panel-width");
	if (width == 0)
		return (panel_min(56, c->tty.sx / 3));
	width = panel_min(width, c->tty.sx - PANEL_WINDOW_MINIMUM);
	return (width < PANEL_WIDTH_MINIMUM ? PANEL_WIDTH_MINIMUM : width);
}

/* The panel-width option changed: every open panel, and the windows beside them. */
void
panel_resized(void)
{
	struct client *c;

	recalculate_sizes();
	TAILQ_FOREACH(c, &clients, entry) {
		if (c->panel == NULL || c->session == NULL)
			continue;
		tty_update_client_offset(c);
		c->flags |= CLIENT_REDRAWWINDOW|CLIENT_REDRAWSTATUS|CLIENT_REDRAWBORDERS;
	}
}

static void
panel_free_lines(struct panel_data *pd)
{
	u_int i;
	for (i = 0; i < pd->nlines; i++)
		free(pd->lines[i].text);
	free(pd->lines);
	pd->lines = NULL;
	pd->nlines = 0;
}

/* The spaces a row starts with, kept on each line it wraps onto. */
static u_int
panel_indent(const char *text)
{
	u_int indent = 0;
	const char *end;

	while (*text != '\0') {
		if (text[0] == '#' && text[1] == '[') {
			if ((end = strchr(text, ']')) == NULL)
				break;
			text = end + 1;
		} else if (*text == ' ') {
			indent++;
			text++;
		} else
			break;
	}
	return (indent);
}

static void
panel_reflow(struct client *c)
{
	struct panel_data *pd = c->panel;
	u_int width = panel_width(c), i, used, remaining, top_item = UINT_MAX, choice_item = UINT_MAX;
	u_int indent, skip, limit;
	char *text, *line, *next;
	if (width == 0 || width == pd->width)
		return;
	if (pd->top < pd->nlines)
		top_item = pd->lines[pd->top].item;
	if (pd->choice >= 0 && (u_int)pd->choice < pd->nlines)
		choice_item = pd->lines[pd->choice].item;
	panel_free_lines(pd);
	pd->width = width;
	for (i = 0; i < pd->menu->count; i++) {
		text = xstrdup(pd->menu->items[i].name == NULL ? "" :
		    pd->menu->items[i].name + (*pd->menu->items[i].name == '-'));
		limit = width - 2;
		indent = panel_indent(text);
		if (indent >= limit / 2)
			indent = 0;
		for (;;) {
			remaining = format_width(text);
			skip = 0;
			if (i < pd->tabs || remaining <= limit)
				line = xstrdup(text);
			else {
				/* A long row breaks at its last space that fits. */
				used = format_break(text, limit, indent);
				line = format_trim_left(text, used != 0 ? used : limit);
				skip = used != 0;
			}
			used = format_width(line);
			pd->lines = xreallocarray(pd->lines, pd->nlines + 1, sizeof *pd->lines);
			pd->lines[pd->nlines].text = line;
			pd->lines[pd->nlines++].item = i;
			if (i < pd->tabs || remaining <= used + skip || used == 0)
				break;
			next = format_trim_right(text, remaining - used - skip);
			free(text);
			xasprintf(&text, "%*s%s", (int)indent, "", next);
			free(next);
		}
		free(text);
	}
	for (i = pd->tabs; i < pd->nlines; i++) {
		if (pd->lines[i].item == top_item) {
			pd->top = i;
			top_item = UINT_MAX;
		}
		if (pd->lines[i].item == choice_item) {
			pd->choice = i;
			choice_item = UINT_MAX;
		}
	}
	if (pd->top >= pd->nlines)
		pd->top = pd->tabs;
	if (pd->choice >= (int)pd->nlines)
		pd->choice = -1;
}

/*
 * Where tab i is on the tab row: at x, taking w columns. The tabs sit side by side
 * a gap apart from the rows' margin, each taking the gap after it too; when they
 * don't fit, each gets an equal share of the row.
 */
static void
panel_tab(struct panel_data *pd, u_int width, u_int i, u_int *x, u_int *w)
{
	u_int j, total = 0;

	for (j = 0; j < pd->tabs; j++)
		total += format_width(pd->menu->items[j].name) + 2;
	if (total > width - 2) {
		*w = (width - 2) / pd->tabs;
		*x = 1 + i * *w;
		return;
	}
	*x = 2;
	for (j = 0; j < i; j++)
		*x += format_width(pd->menu->items[j].name) + 2;
	*w = format_width(pd->menu->items[i].name) + 2;
}

void
panel_clear(struct client *c)
{
	struct panel_data *pd = c->panel;
	if (pd == NULL)
		return;
	c->panel = NULL;
	menu_free(pd->menu);
	panel_free_lines(pd);
	free(pd->generation);
	screen_free(&pd->screen);
	free(pd);
	if (c->session != NULL) {
		recalculate_sizes();
		tty_update_client_offset(c);
		c->flags |= CLIENT_REDRAWWINDOW|CLIENT_REDRAWSTATUS|CLIENT_REDRAWBORDERS;
	}
}

struct screen *
panel_mode(struct client *c)
{
	if (panel_width(c) != 0 && c->panel->focused)
		return (&c->panel->screen);
	return (NULL);
}

int
panel_open(struct client *c, struct menu *menu, struct window_pane *wp,
    u_int tabs, const char *generation, int update, const char *expected)
{
	struct panel_data *pd;
	if (expected != NULL && (c->panel == NULL || c->panel->generation == NULL ||
	    strcmp(c->panel->generation, expected) != 0)) {
		menu_free(menu);
		return (1);
	}
	if (update && (c->panel == NULL || generation == NULL ||
	    c->panel->generation == NULL ||
	    strcmp(c->panel->generation, generation) != 0)) {
		menu_free(menu);
		return (1);
	}
	if (c->tty.sx < 50 || c->tty.sy < status_line_size(c) + 6)
		return (-1);
	if (c->panel == NULL) {
		c->panel = xcalloc(1, sizeof *c->panel);
		screen_init(&c->panel->screen, 1, 1, 0);
	} else
		menu_free(c->panel->menu);
	pd = c->panel;
	pd->menu = menu;
	pd->width = 0;
	free(pd->generation);
	pd->generation = generation != NULL ? xstrdup(generation) : NULL;
	pd->tabs = panel_min(tabs, menu->count);
	pd->source = wp->id;
	if (!update && expected == NULL)
		pd->focused = 1;
	if (!update) {
		pd->top = pd->tabs;
		pd->selected = pd->pressed = pd->dragged = 0;
	}
	pd->choice = -1;
	panel_reflow(c);
	recalculate_sizes();
	tty_update_client_offset(c);
	c->flags |= CLIENT_REDRAWWINDOW|CLIENT_REDRAWSTATUS|CLIENT_REDRAWBORDERS;
	return (0);
}

void
panel_draw(struct client *c)
{
	struct panel_data *pd = c->panel;
	struct screen_write_ctx ctx;
	struct grid_cell gc, selected, mode, cell;
	u_int width = panel_width(c), height, y, top, row, i, x, w;
	u_int sl, sc, el, ec, from, to;
	const char *text;
	struct key_table *table;
	int prompt;
	if (width == 0)
		return;
	panel_reflow(c);
	/* The footer names / as the panel's prompt when the panel key table binds it. */
	table = key_bindings_get_table("panel", 0);
	prompt = table != NULL && key_bindings_get(table, '/') != NULL;
	height = c->tty.sy - status_line_size(c);
	top = status_at_line(c) == 0 ? status_line_size(c) : 0;
	screen_resize(&pd->screen, width, height, 0);
	pd->screen.mode = MODE_MOUSE_ALL|MODE_MOUSE_BUTTON;
	memcpy(&gc, &grid_default_cell, sizeof gc);
	style_apply(&gc, c->session->curw->window->options, "menu-style", NULL);
	selected = gc;
	style_apply(&selected, c->session->curw->window->options,
	    pd->focused ? "menu-selected-style" : "menu-border-style", NULL);
	screen_write_start(&ctx, &pd->screen);
	screen_write_clearscreen(&ctx, gc.bg);
	for (y = 0; y < height; y++) {
		screen_write_cursormove(&ctx, 0, y, 0);
		screen_write_putc(&ctx, &gc, '|');
		if (y == 0)
			text = pd->menu->title;
		else if (y == 1 && pd->tabs != 0) {
			for (i = 0; i < pd->tabs; i++) {
				panel_tab(pd, width, i, &x, &w);
				screen_write_cursormove(&ctx, x, y, 0);
				format_draw(&ctx, &gc, w,
				    pd->menu->items[i].name, NULL, 0);
			}
			continue;
		} else if (y == height - 1)
			text = !pd->focused ?
			    "#[dim] Click to use" : prompt ?
			    "#[dim] / commands   Esc close   Tab back to pane" :
			    "#[dim] Esc close   Tab back to pane";
		else {
			row = pd->top + y - 1 - (pd->tabs != 0);
			text = row < pd->nlines ? pd->lines[row].text : NULL;
		}
		if (text != NULL)
			format_draw(&ctx, y > 0 && y < height - 1 &&
			    (int)(pd->top + y - 1 - (pd->tabs != 0)) == pd->choice ? &selected : &gc,
			    y == 0 ? width - 6 : width - 2, text, NULL, 0);
		if (y == 0) {
			screen_write_cursormove(&ctx, width - 4, y, 0);
			screen_write_puts(&ctx, &gc, "[x]");
		}
	}
	screen_write_stop(&ctx);
	/* The selected text takes copy mode's colours. */
	if (panel_sel_range(pd, &sl, &sc, &el, &ec)) {
		memcpy(&mode, &grid_default_cell, sizeof mode);
		style_apply(&mode, c->session->curw->window->options, "mode-style",
		    NULL);
		for (y = 1 + (pd->tabs != 0); y < height - 1; y++) {
			row = pd->top + y - 1 - (pd->tabs != 0);
			if (row < sl || row > el)
				continue;
			from = row == sl ? sc : 0;
			to = row == el ? ec : width - 3;
			for (x = from; x <= to; x++) {
				grid_get_cell(pd->screen.grid, 1 + x, y, &cell);
				if (cell.flags & GRID_FLAG_PADDING)
					continue;
				cell.fg = mode.fg;
				cell.bg = mode.bg;
				grid_set_cell(pd->screen.grid, 1 + x, y, &cell);
			}
		}
	}
	for (y = 0; y < height; y++)
		tty_draw_line(&c->tty, &pd->screen, 0, y, width,
		    c->tty.sx - width, top + y, &gc, NULL);
}

/* An item that runs something: not blank, not an informational row. */
static int
panel_item_selectable(struct panel_data *pd, u_int item)
{
	const char *name;
	if (item >= pd->menu->count)
		return (0);
	name = pd->menu->items[item].name;
	return (name != NULL && *name != '-' &&
	    pd->menu->items[item].command != NULL &&
	    *pd->menu->items[item].command != '\0');
}

static int
panel_selectable(struct panel_data *pd, int row)
{
	if (row < 0 || row >= (int)pd->nlines)
		return (0);
	return (panel_item_selectable(pd, pd->lines[row].item));
}

/* The rows the panel has for its items, between its title, tab row and footer. */
static u_int
panel_rows(struct client *c)
{
	return (c->tty.sy - status_line_size(c) - 2 - (c->panel->tabs != 0));
}

/* The selection's ends in order, the start first; 0 if nothing is selected. */
static int
panel_sel_range(struct panel_data *pd, u_int *sl, u_int *sc, u_int *el,
    u_int *ec)
{
	int first;

	if (!pd->selected || pd->sel_width != pd->width ||
	    pd->sel_line[0] >= pd->nlines || pd->sel_line[1] >= pd->nlines)
		return (0);
	first = (pd->sel_line[0] < pd->sel_line[1] ||
	    (pd->sel_line[0] == pd->sel_line[1] &&
	    pd->sel_col[0] <= pd->sel_col[1])) ? 0 : 1;
	*sl = pd->sel_line[first];
	*sc = pd->sel_col[first];
	*el = pd->sel_line[!first];
	*ec = pd->sel_col[!first];
	return (1);
}

/* A line's text as the panel draws it, in a screen one row high. */
static void
panel_line_screen(struct panel_data *pd, u_int line, struct screen *s)
{
	struct screen_write_ctx ctx;

	screen_init(s, pd->width - 2, 1, 0);
	screen_write_start(&ctx, s);
	format_draw(&ctx, &grid_default_cell, pd->width - 2,
	    pd->lines[line].text, NULL, 0);
	screen_write_stop(&ctx);
}

static int
panel_blank(struct screen *s, u_int x)
{
	struct grid_cell gc;

	grid_get_cell(s->grid, x, 0, &gc);
	return ((~gc.flags & GRID_FLAG_PADDING) && gc.data.size == 1 &&
	    *gc.data.data == ' ');
}

/* The blank columns a line starts with, or UINT_MAX if it is all blank. */
static u_int
panel_leading(struct screen *s, u_int last)
{
	u_int x;

	for (x = 0; x <= last; x++) {
		if (!panel_blank(s, x))
			return (x);
	}
	return (UINT_MAX);
}

/*
 * Copy the selection to a paste buffer and the terminal's clipboard. A row
 * wrapped onto the next line is joined back with a space, the indentation the
 * copied rows share (the margin the panel's rows start with) is left out of
 * each, and so are the spaces the selection starts and ends with.
 */
static void
panel_copy(struct client *c)
{
	struct panel_data *pd = c->panel;
	struct screen s;
	struct grid_cell gc;
	u_int sl, sc, el, ec, line, x, from, to, last = pd->width - 3;
	u_int margin = UINT_MAX, lead;
	char *buf = NULL;
	size_t len = 0, keep, start = 0;

	if (!panel_sel_range(pd, &sl, &sc, &el, &ec))
		return;
	for (line = sl; line <= el; line++) {
		if (line != sl && pd->lines[line].item == pd->lines[line - 1].item)
			continue;
		panel_line_screen(pd, line, &s);
		lead = panel_leading(&s, last);
		if ((line != sl || sc <= lead) && lead < margin)
			margin = lead;
		screen_free(&s);
	}
	for (line = sl; line <= el; line++) {
		panel_line_screen(pd, line, &s);
		from = line == sl ? sc : 0;
		to = line == el ? ec : last;
		if (line != sl) {
			buf = xrealloc(buf, len + 1);
			if (pd->lines[line].item == pd->lines[line - 1].item) {
				while (from < to && panel_blank(&s, from))
					from++;
				buf[len++] = ' ';
			} else {
				if (margin != UINT_MAX)
					from = margin;
				buf[len++] = '\n';
			}
		}
		keep = len;
		for (x = from; x <= to; x++) {
			grid_get_cell(s.grid, x, 0, &gc);
			if (gc.flags & GRID_FLAG_PADDING)
				continue;
			buf = xrealloc(buf, len + gc.data.size);
			memcpy(buf + len, gc.data.data, gc.data.size);
			len += gc.data.size;
		}
		while (len > keep && buf[len - 1] == ' ')
			len--;
		screen_free(&s);
	}
	while (start < len && (buf[start] == ' ' || buf[start] == '\n'))
		start++;
	while (len > start && (buf[len - 1] == ' ' || buf[len - 1] == '\n'))
		len--;
	if (len == start) {
		free(buf);
		return;
	}
	memmove(buf, buf + start, len - start);
	len -= start;
	tty_set_selection(&c->tty, "", buf, len);
	paste_add(NULL, buf, len);
}

/*
 * Select the word at a point, as a double click does, or with whole set the
 * row it is part of, every line it wrapped onto, as a triple click does.
 */
static void
panel_select_word(struct panel_data *pd, u_int line, u_int col, int whole)
{
	struct screen s;
	u_int first = line, end = line, from = col, to = col;
	u_int last = pd->width - 3;

	if (whole) {
		while (first > pd->tabs &&
		    pd->lines[first - 1].item == pd->lines[line].item)
			first--;
		while (end + 1 < pd->nlines &&
		    pd->lines[end + 1].item == pd->lines[line].item)
			end++;
		panel_line_screen(pd, first, &s);
		for (from = 0; from < last && panel_blank(&s, from); from++)
			/* nothing */;
		screen_free(&s);
		panel_line_screen(pd, end, &s);
		for (to = last; to > 0 && panel_blank(&s, to); to--)
			/* nothing */;
		screen_free(&s);
	} else {
		panel_line_screen(pd, line, &s);
		if (!panel_blank(&s, col)) {
			while (from > 0 && !panel_blank(&s, from - 1))
				from--;
			while (to < last && !panel_blank(&s, to + 1))
				to++;
		}
		screen_free(&s);
	}
	pd->selected = 1;
	pd->sel_width = pd->width;
	pd->sel_line[0] = first;
	pd->sel_col[0] = from;
	pd->sel_line[1] = end;
	pd->sel_col[1] = to;
}

/*
 * The line and column of the text under the mouse, kept to the rows shown. With
 * scroll set, the mouse above or below them scrolls a line, so a drag past
 * either end keeps selecting. 0 if the panel has no rows.
 */
static int
panel_point(struct client *c, struct mouse_event *m, u_int top, u_int width,
    int scroll, u_int *line, u_int *col)
{
	struct panel_data *pd = c->panel;
	u_int first = top + 1 + (pd->tabs != 0), rows = panel_rows(c);
	u_int x0 = c->tty.sx - width + 1, last = width - 3;

	if (pd->nlines <= pd->tabs)
		return (0);
	*col = m->x < x0 ? 0 : panel_min(m->x - x0, last);
	if (m->y < first) {
		if (scroll && pd->top > pd->tabs)
			pd->top--;
		*line = pd->top;
		*col = 0;
	} else if (m->y >= first + rows) {
		if (scroll && pd->top + rows < pd->nlines)
			pd->top++;
		*line = pd->top + rows - 1;
		*col = last;
	} else
		*line = pd->top + (m->y - first);
	if (*line >= pd->nlines) {
		*line = pd->nlines - 1;
		*col = last;
	}
	return (1);
}

/* Scroll a page up or down; the highlight goes, as it does for the keys. */
static void
panel_page(struct client *c, int up)
{
	struct panel_data *pd = c->panel;
	u_int rows = panel_rows(c);

	pd->choice = -1;
	if (up)
		pd->top = pd->top >= pd->tabs + rows ? pd->top - rows : pd->tabs;
	else if (pd->top + rows < pd->nlines)
		pd->top = panel_min(pd->top + rows, pd->nlines - rows);
	c->flags |= CLIENT_REDRAWOVERLAY;
}

/*
 * Run an item's command from the source pane, as a click or its key would. A
 * command naming #{panel_action_generation} gets a fresh generation first.
 */
static void
panel_run(struct client *c, u_int item)
{
	struct panel_data *pd = c->panel;
	struct window_pane *wp;
	struct cmd_find_state fs;
	struct cmdq_state *state;
	const char *command;
	char *error;

	if (!panel_item_selectable(pd, item))
		return;
	wp = window_pane_find_by_id(pd->source);
	if (wp == NULL) {
		panel_clear(c);
		return;
	}
	command = pd->menu->items[item].command;
	cmd_find_from_pane(&fs, wp, 0);
	state = cmdq_new_state(&fs, NULL, 0);
	if (strstr(command, "#{panel_action_generation}") != NULL) {
		free(pd->generation);
		xasprintf(&pd->generation, "p%lu-%llu", (unsigned long)getpid(),
		    (unsigned long long)++panel_next_generation);
		cmdq_add_format(state, "panel_action_generation", "%s", pd->generation);
	}
	if (cmd_parse_and_append(command, NULL, c, state, &error) == CMD_PARSE_ERROR) {
		cmdq_append(c, cmdq_get_error(error));
		free(error);
	}
	cmdq_free_state(state);
}

/* Run a key bound in the panel key table from the source pane; 0 if unbound. */
static int
panel_bound(struct client *c, struct key_event *event, key_code key)
{
	struct key_table *table;
	struct key_binding *bd;
	struct window_pane *wp;
	struct cmd_find_state fs;

	table = key_bindings_get_table("panel", 0);
	if (table == NULL || (bd = key_bindings_get(table, key)) == NULL)
		return (0);
	wp = window_pane_find_by_id(c->panel->source);
	if (wp == NULL) {
		panel_clear(c);
		return (1);
	}
	cmd_find_from_pane(&fs, wp, 0);
	key_bindings_dispatch(bd, NULL, c, event, &fs);
	return (1);
}

/*
 * Every action the panel offers, for a palette (display-palette -P): each item
 * that runs something, with the command name display-panel -N gave it (NULL
 * without one), its name as drawn, its key and whether it is a tab, then the
 * panel's own actions, told apart from a row by their number.
 */
void
panel_actions(struct client *c, panel_action_cb cb, void *arg)
{
	struct panel_data *pd = c->panel;
	struct menu_item *mi;
	const char *key;
	u_int i;

	if (pd == NULL)
		return;
	for (i = 0; i < pd->menu->count; i++) {
		if (!panel_item_selectable(pd, i))
			continue;
		mi = &pd->menu->items[i];
		key = NULL;
		if (mi->key != KEYC_UNKNOWN && mi->key != KEYC_NONE)
			key = key_string_lookup_key(mi->key, 0);
		cb(arg, PANEL_ACTION_ROW, mi->command_name, mi->name, key,
		    mi->command, i < pd->tabs);
	}
	cb(arg, PANEL_ACTION_CLOSE, "close-panel", "Close the panel", "Escape",
	    NULL, 0);
	cb(arg, PANEL_ACTION_UNFOCUS, "unfocus-panel",
	    "Give the keyboard back to the pane", "Tab", NULL, 0);
	cb(arg, PANEL_ACTION_PAGE_UP, "page-up", "Scroll the panel up a page",
	    "PageUp", NULL, 0);
	cb(arg, PANEL_ACTION_PAGE_DOWN, "page-down",
	    "Scroll the panel down a page", "PageDown", NULL, 0);
}

/*
 * Do an action panel_actions offered. A row runs only if the panel still has an
 * item with its command, and runs as that item, so a pick made while the panel
 * moved to another view does nothing.
 */
void
panel_act(struct client *c, int action, const char *command)
{
	struct panel_data *pd = c->panel;
	u_int i;

	if (pd == NULL)
		return;
	switch (action) {
	case PANEL_ACTION_ROW:
		for (i = 0; command != NULL && i < pd->menu->count; i++) {
			if (panel_item_selectable(pd, i) &&
			    strcmp(pd->menu->items[i].command, command) == 0) {
				panel_run(c, i);
				return;
			}
		}
		break;
	case PANEL_ACTION_CLOSE:
		panel_clear(c);
		break;
	case PANEL_ACTION_UNFOCUS:
		pd->focused = 0;
		c->flags |= CLIENT_REDRAWOVERLAY;
		break;
	case PANEL_ACTION_PAGE_UP:
	case PANEL_ACTION_PAGE_DOWN:
		if (panel_width(c) != 0) {
			panel_reflow(c);
			panel_page(c, action == PANEL_ACTION_PAGE_UP);
		}
		break;
	}
}

int
panel_key(struct client *c, struct key_event *event)
{
	struct panel_data *pd = c->panel;
	struct mouse_event *m = &event->m;
	u_int width = panel_width(c), height, top, i, rows, x, w, line, col;
	int row, step, n, click, released, held;
	uint64_t now;
	key_code key = event->key & ~KEYC_MASK_FLAGS;
	if (width == 0)
		return (0);
	panel_reflow(c);
	height = c->tty.sy - status_line_size(c);
	top = status_at_line(c) == 0 ? status_line_size(c) : 0;
	rows = panel_rows(c);
	if (KEYC_IS_MOUSE(key)) {
		/* Motion with no button held is encoded as a dragged release. */
		click = !MOUSE_WHEEL(m->b) && !MOUSE_DRAG(m->b);
		released = click && MOUSE_RELEASE(m->b);
		held = MOUSE_DRAG(m->b) && !MOUSE_RELEASE(m->b);
		if (pd->resizing) {
			if (held && m->x < c->tty.sx) {
				options_set_number(global_options, "panel-width",
				    c->tty.sx - m->x);
				panel_resized();
			} else if (!held)
				pd->resizing = 0;
			return (1);
		}
		/*
		 * A press on the rows may start a selection: its drag and release
		 * are the panel's wherever the mouse goes. A drag selects, and the
		 * release copies; a release with no drag is a click.
		 */
		if (pd->pressed && held) {
			panel_point(c, m, top, width, 1, &line, &col);
			if (pd->dragged || line != pd->sel_line[0] ||
			    col != pd->sel_col[0]) {
				pd->dragged = pd->selected = 1;
				pd->sel_line[1] = line;
				pd->sel_col[1] = col;
				pd->choice = -1;
			}
			goto redraw;
		}
		if (pd->pressed && released) {
			pd->pressed = 0;
			if (pd->dragged) {
				pd->dragged = 0;
				panel_copy(c);
				goto redraw;
			}
		}
		if (click && !released && m->x == c->tty.sx - width &&
		    m->y >= top && m->y < top + height) {
			pd->resizing = 1;
			return (1);
		}
		if (m->x < c->tty.sx - width || m->y < top || m->y >= top + height) {
			if (click)
				pd->focused = 0;
			if (click && !released)
				pd->selected = 0;
			pd->choice = -1;
			c->flags |= CLIENT_REDRAWOVERLAY;
			return (0);
		}
		if (click)
			pd->focused = 1;
		if (m->y == top && m->x >= c->tty.sx - 4 && released) {
			panel_clear(c);
			return (1);
		}
		if (MOUSE_WHEEL(m->b)) {
			pd->choice = -1;
			if (MOUSE_BUTTONS(m->b) == MOUSE_WHEEL_UP)
				pd->top = pd->top > pd->tabs + 3 ? pd->top - 3 : pd->tabs;
			else if (pd->top + rows < pd->nlines)
				pd->top = panel_min(pd->top + 3, pd->nlines - (rows));
			goto redraw;
		}
		/*
		 * A press clears the selection and marks where the next starts. A
		 * second or third on the same spot of a row that runs nothing selects
		 * its word or the whole row.
		 */
		if (click && !released) {
			pd->selected = 0;
			if (m->x > c->tty.sx - width &&
			    m->y > top + (pd->tabs != 0) && m->y < top + height - 1 &&
			    panel_point(c, m, top, width, 0, &line, &col)) {
				pd->pressed = 1;
				pd->dragged = 0;
				pd->sel_width = pd->width;
				pd->sel_line[0] = pd->sel_line[1] = line;
				pd->sel_col[0] = pd->sel_col[1] = col;
				now = get_timer();
				if (pd->clicks != 0 && line == pd->click_line &&
				    col == pd->click_col &&
				    now - pd->click_time < KEYC_CLICK_TIMEOUT)
					pd->clicks++;
				else
					pd->clicks = 1;
				pd->click_time = now;
				pd->click_line = line;
				pd->click_col = col;
				if (pd->clicks >= 2 && !panel_selectable(pd, line)) {
					panel_select_word(pd, line, col,
					    pd->clicks >= 3);
					panel_copy(c);
					pd->pressed = 0;
				}
			}
		}
		/* A row is highlighted only while the mouse is on it. */
		pd->choice = -1;
		if (m->x == c->tty.sx - width)
			goto redraw;
		if (pd->tabs != 0 && m->y == top + 1) {
			for (row = 0; row < (int)pd->tabs - 1; row++) {
				panel_tab(pd, width, row, &x, &w);
				if (m->x - (c->tty.sx - width) < x + w)
					break;
			}
		} else
			row = (int)(pd->top + m->y - top) - 1 - (pd->tabs != 0);
		if (m->y == top || m->y == top + height - 1)
			goto redraw;
		if (panel_selectable(pd, row)) {
			pd->choice = row;
			if (released)
				goto chosen;
		}
		goto redraw;
	}
	if (!pd->focused || key == KEYC_FOCUS_IN || key == KEYC_FOCUS_OUT)
		return (0);
	if (key == '\033' || key == ('c'|KEYC_CTRL)) {
		panel_clear(c);
		return (1);
	}
	if (key == '\t') {
		pd->focused = 0;
		goto redraw;
	}
	for (i = 0; i < pd->nlines; i++) {
		if (panel_selectable(pd, i) && key != KEYC_NONE &&
		    key == pd->menu->items[pd->lines[i].item].key) {
			pd->choice = i;
			goto chosen;
		}
	}
	if (key == '\r')
		goto chosen;
	if (key == KEYC_PPAGE || key == KEYC_NPAGE) {
		panel_page(c, key == KEYC_PPAGE);
		return (1);
	}
	step = key == KEYC_UP ? -1 : key == KEYC_DOWN ? 1 : 0;
	if (step == 0 && panel_bound(c, event, key))
		return (1);
	if (step != 0) {
		row = pd->choice < 0 ? (step > 0 ? -1 : 0) : pd->choice;
		for (n = 0; n < (int)pd->nlines; n++) {
			row = (row + step + pd->nlines) % pd->nlines;
			if (panel_selectable(pd, row)) {
				pd->choice = row;
				if ((u_int)row >= pd->tabs && (u_int)row < pd->top)
					pd->top = row;
				if ((u_int)row >= pd->top + rows)
					pd->top = row - (rows - 1);
				break;
			}
		}
	}
redraw:
	c->flags |= CLIENT_REDRAWOVERLAY;
	return (1);
chosen:
	if (panel_selectable(pd, pd->choice))
		panel_run(c, pd->lines[pd->choice].item);
	return (1);
}
#ifdef HAVE_SERVER_UPGRADE
void
panel_upgrade_save(struct evbuffer *o, struct client *c)
{
	struct panel_data *pd = c->panel;
	u_int i;
	upw_u32(o, pd != NULL);
	if (pd == NULL)
		return;
	upw_u32(o, pd->source);
	upw_u32(o, pd->tabs);
	upw_u32(o, pd->top);
	upw_u32(o, pd->choice);
	upw_u32(o, pd->focused);
	upw_str(o, pd->generation);
	upw_str(o, pd->menu->title);
	upw_u32(o, pd->menu->count);
	for (i = 0; i < pd->menu->count; i++) {
		upw_str(o, pd->menu->items[i].name);
		upw_u32(o, pd->menu->items[i].key != KEYC_UNKNOWN);
		if (pd->menu->items[i].key != KEYC_UNKNOWN)
			upw_key(o, pd->menu->items[i].key);
		upw_str(o, pd->menu->items[i].command);
		upw_str(o, pd->menu->items[i].command_name);
	}
}

void
panel_upgrade_restore(struct upgrade_reader *o, struct client *c,
    u_int version)
{
	struct panel_data *pd;
	u_int i, count;
	char *title;
	if (o->left == 0 || !upr_u32(o))
		return;
	pd = c->panel = xcalloc(1, sizeof *pd);
	screen_init(&pd->screen, 1, 1, 0);
	pd->source = upr_u32(o);
	pd->tabs = upr_u32(o);
	pd->top = upr_u32(o);
	pd->choice = upr_u32(o);
	pd->focused = upr_u32(o);
	pd->generation = upr_str(o);
	title = upr_str(o);
	pd->menu = menu_create(title != NULL ? title : "");
	free(title);
	count = upr_u32(o);
	if (count > o->left || pd->tabs > 8 || pd->tabs > count) {
		o->error = 1;
		return;
	}
	pd->menu->items = xcalloc(count, sizeof *pd->menu->items);
	pd->menu->count = count;
	for (i = 0; i < count && !o->error; i++) {
		pd->menu->items[i].name = upr_str(o);
		pd->menu->items[i].key = upr_u32(o) ? upr_key(o) : KEYC_UNKNOWN;
		pd->menu->items[i].command = upr_str(o);
		if (version >= 4)
			pd->menu->items[i].command_name = upr_str(o);
	}
}
#endif
