# Independent bottom strip

`status-footer` is a tmux format for a separate row at the bottom of each
attached client. An empty format (the default) disables it. It reserves one
row of pane space, independently of `status`, `status-position`, and the
session/window bar toggles. `status-footer-style` sets its base style.

```tmux
set -g status-footer ' Current task: #{@task}'
set -g status-footer-style 'fg=default,bg=default'
```

The footer supports normal tmux formats, asynchronous `#()` jobs, styles and
`range=user|name` regions. End each region with `#[norange]`. Footer mouse
events have their own names (`MouseDown1Footer`, `WheelUpFooter`, and so on),
so bindings for the existing status bars keep their meaning.
`#{mouse_status_range}` reports the clicked footer region.

The home configuration uses `tmux-strip` from at-home-tools to read each
pane's Claude/Codex conversation identity and local PR/work-package records.
It binds a footer click to that conversation's links menu. tmux itself stays
independent of any particular agent, issue tracker or PR host.
