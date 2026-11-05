# Independent bottom strip

`status-footer` is a tmux format for a separate row at the bottom of each
attached client. An empty format (the default) disables it. It reserves one
row of pane space, independently of `status`, `status-position`, and the
session/window bar toggles. `status-footer-style` sets its base style.

`status-footer-condition` is a format evaluated for the current pane. Its
default is `1`; an empty or `0` result hides the footer and returns its row to
the panes. Changing panes or windows recalculates the available height. The
condition does not run `#()` jobs; keep asynchronous content in `status-footer`.

```tmux
set -g status-footer ' Current task: #{@task}'
set -g status-footer-style 'fg=default,bg=default'
```

The footer supports normal tmux formats, asynchronous `#()` jobs, styles and
`range=user|name` regions. End each region with `#[norange]`. Footer mouse
events have their own names (`MouseDown1Footer`, `WheelUpFooter`, and so on),
so bindings for the existing status bars keep their meaning.
`#{mouse_status_range}` reports the clicked footer region.

A `#()` command in the footer runs when first shown, when its text changes (a
new pane's values, a new width) and on `refresh-client -S`. It does not run on
`status-interval` or on any other redraw: the footer shows its last output
until whatever changed that output says so.

`pane-footer` is the same row for one pane: it takes the pane's bottom row, is as wide
as the pane, and moves and resizes with it, so a split shows one for each pane that has
one. The formats run in that pane's context. `pane-footer-condition` and
`pane-footer-style` work as above, per pane, and clicks use the same `...Footer` mouse
names with the clicked pane as the mouse target, so `select-pane -t =` focuses it.
Changing a pane's row doesn't change the window's size, so nothing else moves.

The home configuration uses `tmux-strip` from at-home-tools to read each
pane's Claude/Codex conversation identity and local PR/work-package records.
The existing first-message hooks mark the active conversation; the condition
shows the strip only for that conversation, until it exits. Empty agent
sessions, shells and app panes do not reserve a row.
It binds a footer click to that conversation's persistent right-hand links panel.
The panel is drawn by tmux, keeps All, PRs, Tickets and History tabs visible,
and reserves space beside the conversation without creating a shell or pane.
Tab returns input to the conversation; clicking the panel focuses it again.
Escape closes the focused panel and restores the conversation's width. tmux itself stays
independent of any particular agent, issue tracker or PR host.

Panel verification, including the real configured picker and existing-terminal
delivery, is described in [TESTING.md](../TESTING.md).
