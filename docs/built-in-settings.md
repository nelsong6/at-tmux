# Built-in settings

Every Windows build carries the at system's settings in `at-defaults.c`, and the server
reads no configuration file of its own, so every server starts the same (TMUX-210).
Nelson's rule: every instance of the app behaves the same, and a setting kept in a file
outside it is a way for instances to drift. A setting is changed by changing
`at-defaults.c`; `-f` and `source-file` still load a file when asked (the tests use them).

They hold what the home configuration (`windows.conf` and shell-config's shared
`tmux.conf`) used to: windows numbered from 1, the mouse, no prefix, Ctrl+B and Alt+Tab
opening the at menu, the Windows-style keys, the Ctrl+T chords, the command aliases in the
at menu, the hidden bypass label, the system session and the conversation strip's formats.
The shell is pwsh unless whoever starts the server names one in `SHELL`.

- **Options** take these values as their defaults (`at_defaults_option`, called from
  `options_default`), so `set -u` returns to them.
- **User options and key bindings** are commands queued after tmux's own default bindings,
  before any client. The snapshot `upgrade-server` uses to tell this build's defaults from
  what was set later (TMUX-207) is taken after them, user options included, so a changed
  setting reaches a running server at its next upgrade.
- **The at server alone**, the one at-terminal shows (its socket name ends in `-at`), gets
  its session set, Win+`, the alerts listener and strip-owner. A test or throwaway server
  has none of them.

A running server started before this build had the settings from the home configuration.
At the upgrade, a binding identical to this build's default becomes that default, and its
global options other than user options give way to the built-in ones (upgrade state
version 5). Test: `regress/win32-at-defaults.sh`, and `win32-upgrade-defaults.sh` for the
upgrade.
