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

For the conversation panel, run `regress/panel.sh`. It exercises real attached
clients, conditional footers including a condition which reads panel width,
keyboard and mouse navigation, conversation input while open, scrolling,
resize reflow, stale updates, input-order generations, cancellation, preserved
focus/scroll, and server upgrade persistence. Set `TEST_STRIP` to a built
`tmux-strip` executable to include actual provider navigation. The footer,
palette, format and upgrade suites cover the surrounding contracts.

## Try the normal entry point

Stage the tested executable and packaged console dependencies in a fresh runtime
directory outside build output. Start a private inner server and attach its client
inside a pane of a separate private outer server. Capture the outer pane to inspect
what the inner client actually drew. Send keys to the inner attached client with
`send-keys -K`, never desktop key injection.

Read the live `Ctrl+B` binding, `prefix`/`prefix2`, `@at-menu`, `@fzt-automate`,
strip options, footer click binding and `links` alias. Copy those into the private
server's configuration rather than loading the full home configuration and its
unrelated hooks. Give its source pane a known conversation identity and
`@strip-active` value. If testing a provider build, substitute only its executable
path in the copied `@strip-menu`. Keep the real installed fzt picker.

Open with `Ctrl+B`, type `links`, read the selected row, then Enter. The picker
must close and a native right-hand panel must appear beside the conversation.
Inspect All, PRs, Tickets and History and a real work-package detail. Tab must
return input to the conversation without closing the panel; Escape closes the
focused panel, and the strip arrow reopens it. A refresh must preserve focus and
scroll. Cancelling a pending navigation or refresh must not reopen the panel.
Do not clear the user's real links or open browsers during automated checks.

Text remains selectable with the terminal's Shift-drag gesture, advertised in
the panel footer. Verify dragging and copying real displayed text in the actual
terminal, including while updates arrive. Desktop input requires Nelson's prior
permission; screenshots alone do not prove selection works.

## Deliver to the existing terminal

Finish the repository's PR, CI and signed release workflow. Home-sync installs
under `C:\Program Files\at-home\tmux\current` and upgrades servers in place;
there is no extra legacy publishing step. A provider release that uses a new
panel command waits until the matching native release is installed and the live
servers support it on all home PCs.

Before reconciliation, read the actual live `at` PID, executable path, upgrade
status, pane IDs/process IDs and attached clients. Afterward confirm the new
server process uses the managed installation, its upgrade status is clear and
the pre-existing panes and client survived. If an interaction delays the upgrade,
inspect its reported reason and preserve that interaction.

Find this conversation's pane by its `@codex-session` or `@claude-session`, not a
stale inherited `TMUX_PANE`. Invoke the real installed strip there and inspect the
rendered screen. Close only a panel opened for verification; leave other work
alone. Remove the preview split and private servers created for this task,
restore the conversation's view and dimensions, and recheck the installed
executable and visible result immediately before handing over. The user never
needs to restart or reopen the terminal.

A preview split shown to him before a change ships is read back before it's
described: the shown pane is alive (`tmux display -p -t <pane> '#{pane_dead}'`
prints `0`) and its capture shows the case being described.
