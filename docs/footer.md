# Pane footers

`pane-footer` is a tmux format for a row at the bottom of one pane. It takes the row out
of that pane, is as wide as it, and moves and resizes with it, so a split shows one for
each pane that has one. Changing a pane's row doesn't change the window's size, so
nothing else moves. An empty format (the default) leaves the pane its full height.
`pane-footer-style` sets its base style.

`pane-footer-condition` is a format evaluated for the pane. Its default is `1`; an empty
or `0` result gives the row back to the pane. The condition does not run `#()` jobs; keep
asynchronous content in `pane-footer`.

```tmux
set -g pane-footer ' Current task: #{@task}'
set -g pane-footer-style 'fg=default,bg=default'
```

The footer supports normal tmux formats, asynchronous `#()` jobs, styles and
`range=user|name` regions. End each region with `#[norange]`. Footer mouse events have
their own names (`MouseDown1Footer`, `WheelUpFooter`, and so on), with the clicked pane
as the mouse target, so `select-pane -t =` focuses it. `#{mouse_status_range}` reports
the clicked region.

The home configuration uses `tmux-strip` from at-home-tools to read each pane's
Claude/Codex conversation identity and local PR/work-package records. The existing
first-message hooks mark the active conversation; the condition shows the strip only for
that conversation, until it exits. Empty agent sessions, shells and app panes do not
reserve a row. It binds a footer click to that conversation's links menu. tmux itself
stays independent of any particular agent, issue tracker or PR host.
