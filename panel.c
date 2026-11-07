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

static void
panel_reflow(struct client *c)
{
	struct panel_data *pd = c->panel;
	u_int width = panel_width(c), i, used, remaining, top_item = UINT_MAX, choice_item = UINT_MAX;
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
		for (;;) {
			remaining = format_width(text);
			line = i < pd->tabs ? xstrdup(text) : format_trim_left(text, width - 2);
			used = format_width(line);
			pd->lines = xreallocarray(pd->lines, pd->nlines + 1, sizeof *pd->lines);
			pd->lines[pd->nlines].text = line;
			pd->lines[pd->nlines++].item = i;
			if (i < pd->tabs || remaining <= used || used == 0)
				break;
			next = format_trim_right(text, remaining - used);
			free(text);
			text = next;
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
	u_int width = panel_width(c), height, y, top, row, i, cell;
	const char *text;
	if (width == 0)
		return;
	panel_reflow(c);
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
			cell = (width - 2) / pd->tabs;
			for (i = 0; i < pd->tabs; i++) {
				screen_write_cursormove(&ctx, 1 + i * cell, y, 0);
				format_draw(&ctx, &gc, cell,
				    pd->menu->items[i].name, NULL, 0);
			}
			continue;
		} else if (y == height - 1)
			text = pd->focused ? "Esc close | Tab return | Shift-drag select" : "Click panel | Shift-drag selects text";
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

static int
panel_selectable(struct panel_data *pd, int row)
{
	const char *name;
	if (row < 0 || row >= (int)pd->nlines)
		return (0);
	row = pd->lines[row].item;
	name = pd->menu->items[row].name;
	return (name != NULL && *name != '-' &&
	    pd->menu->items[row].command != NULL &&
	    *pd->menu->items[row].command != '\0');
}

int
panel_key(struct client *c, struct key_event *event)
{
	struct panel_data *pd = c->panel;
	struct mouse_event *m = &event->m;
	struct window_pane *wp;
	struct cmd_find_state fs;
	struct cmdq_state *state;
	char *error;
	u_int width = panel_width(c), height, top, i, rows;
	int row, step, n, click, released, held;
	key_code key = event->key & ~KEYC_MASK_FLAGS;
	if (width == 0)
		return (0);
	panel_reflow(c);
	height = c->tty.sy - status_line_size(c);
	top = status_at_line(c) == 0 ? status_line_size(c) : 0;
	rows = height - 2 - (pd->tabs != 0);
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
			row = panel_min(pd->tabs - 1, (m->x - (c->tty.sx - width) - 1) /
			    ((width - 2) / pd->tabs));
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
		pd->choice = -1;
		if (key == KEYC_PPAGE)
			pd->top = pd->top >= pd->tabs + rows ? pd->top - rows : pd->tabs;
		else if (pd->top + rows < pd->nlines)
			pd->top = panel_min(pd->top + rows, pd->nlines - (rows));
		goto redraw;
	}
	step = key == KEYC_UP ? -1 : key == KEYC_DOWN ? 1 : 0;
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
	if (!panel_selectable(pd, pd->choice))
		return (1);
	wp = window_pane_find_by_id(pd->source);
	if (wp == NULL) {
		panel_clear(c);
		return (1);
	}
	cmd_find_from_pane(&fs, wp, 0);
	state = cmdq_new_state(&fs, NULL, 0);
	if (strstr(pd->menu->items[pd->lines[pd->choice].item].command,
	    "#{panel_action_generation}") != NULL) {
		free(pd->generation);
		xasprintf(&pd->generation, "p%lu-%llu", (unsigned long)getpid(),
		    (unsigned long long)++panel_next_generation);
		cmdq_add_format(state, "panel_action_generation", "%s", pd->generation);
	}
	if (cmd_parse_and_append(pd->menu->items[pd->lines[pd->choice].item].command, NULL, c,
	    state, &error) == CMD_PARSE_ERROR) {
		cmdq_append(c, cmdq_get_error(error));
		free(error);
	}
	cmdq_free_state(state);
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
