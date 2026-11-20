# Built-in settings

Every Windows build carries the at system's settings in `at-defaults.c`, and the server
reads no configuration file of its own, so every server starts the same (TMUX-210).
Nelson's rule: every instance of the app behaves the same, and a setting kept in a file
outside it is a way for instances to drift. A setting is changed by changing
`at-defaults.c`; `-f` and `source-file` still load a file when asked (the tests use them).

They hold what the home configuration (`windows.conf` and shell-config's shared
`tmux.conf`) used to: windows numbered from 1, the mouse, no prefix, Ctrl+B and Alt+Tab
opening the at menu, the Windows-style keys, the Ctrl+T chords, the command aliases in the
at menu, the hidden bypass label and the system session. The conversation strip and its
side panel are at-claude's own, drawn in its window and a split beside it (AGT-49);
the at menu's `links` opens the panel through tmux-strip, and Ctrl+Shift+O gives it the
keyboard (`at-claude panel -focus`), as a click on it does.
The shell is pwsh unless whoever starts the server names one in `SHELL`.

- **Options** take these values as their defaults (`at_defaults_option`, called from
  `options_default`), so `set -u` returns to them.
- **User options and key bindings** are commands queued after tmux's own default bindings,
  before any client. The snapshot `upgrade-server` uses to tell this build's defaults from
  what was set later (TMUX-207) is taken after them, user options included, so a changed
  setting reaches a running server at its next upgrade.
- **The at server alone**, the one at-terminal shows (its socket name ends in `-at`), gets
  its session set, Win+`, desktop Alt+Tab, the alerts listener and strip-owner. A test or throwaway server
  has none of them.

Alt+Tab and Alt+Shift+Tab anywhere summon at-terminal and open the at menu's
windows folder. With no client, `start-program -K M-Tab at-terminal.exe` launches
the terminal and delivers the menu key when it attaches. The launch request
is consumed once; Ctrl+Alt+Tab stays with Windows.
at-terminal's own foreground interception still delivers the same root binding,
so whichever hook sees the press first opens one menu. With the menu already
open, Alt+Tab brings at-terminal forward and opens a fresh windows menu in its
place, and Win+` a fresh menu (`display-palette -R` in `@at-menu`, TMUX-225).

A plain drag selects text over any program that didn't ask for drags: one that takes
only clicks (mode 1000, as gvoice-tui and the fzt pickers do) keeps its clicks, and a
drag starts tmux's selection as it does over a program that took no mouse. A program
that asked for drags (1002 or 1003) gets them (TMUX-227; `regress/win32-at-defaults.sh`).

A program's links (OSC 8 hyperlinks, as at-claude draws them) are passed on to
at-terminal, which never names itself, so the `hyperlinks` feature is asked for with the
kitty keyboard protocol and synchronized output. The terminal opens a link on Ctrl+click
and underlines it under the pointer; a plain click, such as one that only focuses a pane,
goes to tmux and the program and opens nothing (ATC-154; `regress/win32-at-defaults.sh`).

At an upgrade, a binding identical to this build's default becomes that default. Test:
`regress/win32-at-defaults.sh`, and `win32-upgrade-defaults.sh` for the upgrade.
