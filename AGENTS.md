# Working on at-tmux

Read [CLAUDE.md](CLAUDE.md) for build commands, regression tests, Windows shell
quirks, process cleanup, and release publishing.

## Make changes ready in the existing terminal

For changes to interactive behavior, completing the task includes making the
tested build available in the user's existing at-terminal session. A successful
checkout build and regression run alone are not a complete handoff.

- Identify the actual live server and its executable. The home terminal normally
  uses `tmux -L at`; query `display-message -p '#{pid}|#{socket_path}|#{server_upgrade}'`
  and inspect that process's executable path. Inherited `TMUX` and `TMUX_PANE` can
  be stale after an earlier upgrade or when work runs through the Codex app.
- Build and run the relevant regressions. Windows upgrade tests require
  `conpty.dll` and `OpenConsole.exe` beside the test executable; use the same
  packaged dependencies as the live release, not Windows' built-in console.
- Stage the tested executable and those dependencies in a fresh local runtime
  directory, outside the build output. Keep the previous executable path for
  rollback, and record pane IDs/process IDs and attached clients before upgrading.
  Running directly from build output locks the executable against later rebuilds.
- Use `tmux -L at upgrade-server <absolute-staged-tmux.exe>` to move the live
  server in place. This preserves existing windows and pane processes. Never kill
  or restart the live server, and never end `tmux.exe` processes by name.
- Wait for the new server PID, confirm that its executable is the staged build
  and `#{server_upgrade}` is clear, and check that the existing panes and clients
  survived. A requested or pending upgrade is not evidence that it finished.
  If it waits for a popup, prompt, copy mode, or job, inspect the reported reason;
  do not discard the user's interaction to force it through.
- Verify the changed behavior on that live server. For palette changes, inspect
  the rows produced there as well as running the isolated palette regressions.
  Exercise the actual configured `fzt-automate` picker too: a test picker that
  only records rows does not verify the UI the user sees. It can be exercised
  safely with an attached client inside a separate tmux server, capturing the
  outer pane and sending keys to the inner client (`send-keys -K`).
  Check the live binding (`list-keys`) rather than guessing a shortcut. The home
  config currently opens the tmux palette with **Ctrl+B**.
- Home-sync reconciles the live server to the installed tmux release and can
  replace a staged development build. Other development sessions also share the
  live `at` server. Recheck its PID and executable immediately before the handoff;
  if they changed, inspect the new executable and verify the feature again.
  If reconciliation keeps replacing the development build, take the fix through
  the normal reviewed release and installation workflow. Repeatedly requesting
  another temporary upgrade does not resolve that handoff failure.
- In the final response, say which existing terminal/server is ready and give
  exact steps and the expected visible result. Do not tell the user to open a new
  window or restart their terminal to load the change. If preparation failed,
  report that explicitly instead of calling the change ready.

For the status picker, the manual check is: in the existing at-terminal window,
press **Ctrl+B**, find `set-session-status`, open it, and confirm that `working`,
`waiting`, and `done` are selectable rows. Enter should apply the selected status;
Escape should leave it unchanged. `set-window-status` offers the same choices for
only the current window. Choosing a session status affects every window in that
session, so simply opening the choices and cancelling is enough to inspect the UI.

Local preparation is separate from publishing a release. Follow the publishing
workflow in `CLAUDE.md` when merging/releasing is part of the task.
