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
};

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
	if (!update)
		pd->top = pd->tabs;
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
	struct grid_cell gc, selected;
	u_int width = panel_width(c), height, y, top, row, i, x, w;
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
			    "#[dim] Click to use   Shift-drag select" : prompt ?
			    "#[dim] / commands   Esc close   Tab back to pane   Shift-drag select" :
			    "#[dim] Esc close   Tab back to pane   Shift-drag select";
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
 * that runs something, with its name as drawn, its key and whether it is a tab,
 * then the panel's own actions, told apart from a row by their number.
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
		cb(arg, PANEL_ACTION_ROW, mi->name, key, mi->command, i < pd->tabs);
	}
	cb(arg, PANEL_ACTION_CLOSE, "Close the panel", "Escape", NULL, 0);
	cb(arg, PANEL_ACTION_UNFOCUS, "Give the keyboard back to the pane", "Tab",
	    NULL, 0);
	cb(arg, PANEL_ACTION_PAGE_UP, "Scroll the panel up a page", "PageUp", NULL,
	    0);
	cb(arg, PANEL_ACTION_PAGE_DOWN, "Scroll the panel down a page", "PageDown",
	    NULL, 0);
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
	u_int width = panel_width(c), height, top, i, rows, x, w;
	int row, step, n, click, released, held;
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
		if (click && !released && m->x == c->tty.sx - width &&
		    m->y >= top && m->y < top + height) {
			pd->resizing = 1;
			return (1);
		}
		if (m->x < c->tty.sx - width || m->y < top || m->y >= top + height) {
			if (click)
				pd->focused = 0;
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
	}
}

void
panel_upgrade_restore(struct upgrade_reader *o, struct client *c)
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
	}
}
#endif
