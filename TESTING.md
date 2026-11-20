# Testing at-tmux interactive changes

Read `CLAUDE.md` for the native build and test commands.

## Isolated regression checks

Build Debug and put the same packaged `conpty.dll` and `OpenConsole.exe` used by
the installed release beside `build/Debug/tmux.exe`. Run each test through
`regress/win32-run.sh`, with `TEST_TMUX` naming that executable. Every test owns
and cleans up its private servers; never substitute the live server when a test
fails. On Linux and macOS run the portable scripts directly with `TEST_TMUX`
naming the native build.

Run `regress/win32-pane-clear.sh` for Windows rendering changes. Its attached
client must preserve both panes and the native double-line border when either
pane clears, including when terminal features explicitly request left/right
scrolling margins. Those margins cannot pass through the Windows console.
After upgrading an older server, check `info` for missing `Enmg`, `Dsmg`,
`Clmg` and `Cmg` capabilities on its existing attached clients, then repeat the
clear/reflow check without reattaching. Upgrade state must not restore them.

## Try the normal entry point

Stage the tested executable and packaged console dependencies in a fresh runtime
directory outside build output. Start a private inner server and attach its client
inside a pane of a separate private outer server. Capture the outer pane to inspect
what the inner client actually drew. Send keys to the inner attached client with
`send-keys -K`, never desktop key injection.

Read the live `Ctrl+B` binding, `prefix`/`prefix2`, `@at-menu` and `@fzt-automate`.
Copy those into the private server's configuration rather than loading the full
home configuration and its unrelated hooks. Keep the real installed fzt picker.
Open the changed behavior the way Nelson would (`Ctrl+B` and the at menu's row,
or the key it is bound to) and read what the inner client drew. Mouse and
selection changes are verified in the actual terminal on a home PC Nelson is
not at (the home config's `terminal.md`); screenshots alone do not prove them.

The conversation strip and its side panel are at-claude's (AGT-49); at-tmux has
neither, so they are tested in at-claude.

## Deliver to the existing terminal

Finish the repository's PR, CI and signed release workflow. Home-sync installs
under `C:\Program Files\at-home\tmux\current` and upgrades servers in place;
there is no extra legacy publishing step.

Before reconciliation, read the actual live `at` PID, executable path, upgrade
status, pane IDs/process IDs and attached clients. Afterward confirm the new
server process uses the managed installation, its upgrade status is clear and
the pre-existing panes and client survived. If an interaction delays the upgrade,
inspect its reported reason and preserve that interaction.

Find this conversation's pane by its `@claude-session`, not a stale inherited
`TMUX_PANE`, and inspect the rendered screen of the change there. Leave other
work alone. Remove the preview split and private servers created for this task,
restore the conversation's view and dimensions, and recheck the installed
executable and visible result immediately before handing over. The user never
needs to restart or reopen the terminal.

A preview split shown to him before a change ships is read back before it's
described: the shown pane is alive (`tmux display -p -t <pane> '#{pane_dead}'`
prints `0`) and its capture shows the case being described.
