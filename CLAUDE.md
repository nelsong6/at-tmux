# Claude Code Project Notes — tmux-windows

Read [AGENTS.md](AGENTS.md) for the required live-terminal preparation and manual
testing handoff. Interactive changes must be ready in the existing terminal
before reporting completion.

## Checkout and temporary work locations

`D:\repos\at-tmux` is the default-branch checkout. Create every branch worktree
under `D:\workspace\at-tmux\<branch>`, including release preparation,
verification and throwaway worktrees. Never create sibling `at-tmux-*` folders
under `D:\repos`; a release or temporary build is not an exception. Before
`git worktree add`, verify the absolute destination is under the workspace root.
Keep staged runtimes outside both the repos directory and build output, as
described in `AGENTS.md`.

## MSYS2 / Git Bash Shell Quirks

### Ending test servers
Never end tmux.exe by name (`taskkill //IM tmux.exe`, `Stop-Process -Name tmux`): on a desktop that also ends at-terminal's live server and every window open in it (HOMECFG-97). End only the tmux running from this checkout's `build` folder, before a rebuild (the linker fails with `LNK1104: cannot open file 'tmux.exe'` while it runs):
```bash
bash regress/win32-stop-build.sh
```

### Single-slash flags
MSYS2 converts single-slash flags (`/F`) passed to native commands into paths (`F:/`). Write them with **double slashes** (`//F`).

### MSYS2 path conversion
MSYS2 converts Unix-style paths passed to native Windows executables. This affects:
- Relative paths like `regress/conf/foo.conf` may become `C\:/src/tmux/regress/conf/foo.conf`
- The escaped colon (`C\:`) has a literal backslash before the colon
- Code checking `path[1] == ':'` for Windows drive letters must also check `path[1] == '\\' && path[2] == ':'`

### Test temp variables
Never use `TMP` as a shell variable name in test scripts — it shadows Windows `%TMP%` and causes `GetTempFileName()` ACCESS_DENIED errors in child processes. Use `OUT` instead.

## Build Commands

```bash
# Debug build (from Git Bash)
bash regress/win32-stop-build.sh
powershell.exe -NoProfile -Command "& { cmd.exe /c '\"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat\" x64 >nul 2>&1 && cmake --build C:\src\tmux\build --config Debug' }"

# Run tests
TEST_TMUX=./build/Debug/tmux.exe bash regress/win32-run.sh win32-basic.sh
```

## Test Suite

CI runs on Forgejo (`.forgejo/workflows/ci.yml`). Its `build-and-test` job runs on upstairspc's runner (host mode, label `windows-latest`): Visual Studio Build Tools' CMake and vcpkg, libevent from `vcpkg.json` (manifest mode, VS's vcpkg has none other) with a binary cache in the runner's folder, and Git Bash for the tests. It runs these test scripts from `regress/`, each through `win32-run.sh`:
- `win32-message-log.sh` — failed launches keep their caller errors and make no pane, failed program exits are recorded, and error history survives server shutdown, rotates and expires old files (TMUX-41)
- `win32-run-shell-background.sh` — a `run-shell -b` started by a command-line client, a config file or a hook puts its output and failed exit in the message log (the failure in the error log too), never into whichever pane is current, even with a client attached; one started by a key press shows in that client's pane, and one with `-t` in its pane (TMUX-101)
- `win32-basic.sh` — core session/window/pane operations
- `win32-claude-swarm.sh` — multi-session concurrent usage
- `win32-format-strings.sh` — `#{...}` format engine (171 assertions)
- `win32-conf-syntax.sh` — config file parsing (21 files)
- `win32-pty-close.sh` — closing four consoles producing output leaves the server responsive and releases its workers before freeing them (tested with both Windows' console and packaged ConPTY)
- `win32-keys.sh` — key handling (13 tests, tests effects not raw codes)
- `win32-csi-u.sh` — a key in the kitty keyboard protocol's short form (`ESC [ 27 u`) is read as that key, not as `M-[` and typed text (client in a pane of a second server)
- `win32-has-session.sh` — exit code validation
- `win32-key-trace.sh` — the key trace names where a key stopped: pressed and never read, taken by a menu, or stuck going into a pane whose console stopped reading (`win32-suspend.ps1` suspends the console), each with its message and recovery (TMUX-131)
- `win32-file.sh` — `source-file`, `load-buffer` and `save-buffer` from a second client finish, keep the bytes, and fail with exit 1; relative config paths work from a client's folder containing spaces and punctuation
- `conf-crlf.sh` — LF and Windows CRLF continuations give the same options when sourced, parsed without execution or loaded at startup; literal carriage returns stay intact and errors report physical line numbers (also runs on Linux and macOS)
- `win32-strftime.sh` — a `%` sequence Windows' `strftime` doesn't know (`%Q`, `% -`, a trailing `%`) is printed as written and the server keeps running (it ended the server before TMUX-37), and the format is recorded once in `show-messages`
- `win32-respawn-failed.sh` — a pane whose respawn can't start its program reads as one whose program printed why and exited 1: the reason above the "Pane is dead (status 1, …)" line, `#{pane_dead}` 1, `pane-died` run, and `remain-on-exit` keeping or closing it (before TMUX-62 a second failure left it blank and not dead); and it stays usable: another respawn, `capture-pane -P` and `send-keys -R` work on it and the server keeps running (before TMUX-61 the next respawn ended the server)
- `win32-process-watch.sh` — the server sees every child it starts exit: 70 jobs at once, rounds of overlapping jobs that end oldest first, and a job and a pane started beside a program that keeps running (before TMUX-54 a table of 64 filled up and popups, jobs and panes stayed open after their program ended)
- `win32-environment.sh` — changes to global and session environments reach background commands and pane pipes, including PATH lookup through a directory with spaces, removed variables and Unicode values; new panes receive the same values (TMUX-80)
- `win32-child-path.sh` — direct pane and pipe programs resolve through their child environment's PATH, including directories with spaces, session overrides and removed paths (TMUX-86)
- `win32-crash-log.sh` — run on the signed package: a server started through a junction that then moves to the next release, faulting in its own code (`win32-crash.ps1`, a thread started on `xstrdup`), writes a `tmux-crash-<pid>.log` naming function, file and line from the `tmux.pdb` beside the exe, with none at the build path stored in it (TMUX-114)
- `win32-layout.sh` — pane dimension verification (7 tests)
- `win32-control-client.sh` — complex pane operations, and a `-C` client's replies, subscriptions and exit (9 tests)
- `win32-popup-output.sh` — a pane changing behind a popup (erasing to the end of a line or the screen, deleting or inserting characters, scrolling part of its screen, overwriting half a wide character) leaves every popup row and its border alone and still changes beside the popup; a wide character of its own colour across the popup's edge no longer stops the server (TMUX-103; also run beside `conpty.dll`, which is what passes the delete and insert through to tmux)
- `win32-attach-size.sh` — a client attaches at its console's size when the console is resized between identify and attach (runs the client in a pseudo-console via `win32-pty.ps1`)
- `win32-client-name.sh` — two attached clients each have the name `client-<pid>`, since every Windows console reports the tty `CON`: `display-message -c`, `refresh-client -S -t`, `switch-client -c` and `choose-client`'s Enter reach the client named and no other; `#{client_tty}` stays `CON` (before TMUX-119 both were `CON` and all of these reached whichever attached first). `win32-upgrade.sh` checks the name survives `upgrade-server`
- `win32-wrap.sh` — a row a pane wrapped reaches the client's console whole (the client runs in a pane of a second server, whose copy shows what it drew)
- `win32-pane-clear.sh` — clearing either side of a split preserves the other pane and native border in an attached Windows client, even when terminal features request DECSLRM margins; console output cannot preserve those margins, so Windows always uses bounded clear operations
- `win32-linesize.sh` — a double-width or double-height line (DECDWL, DECDHL) wraps at half the pane's width and DECSWL restores it, in the pane and as the client draws it (outer-server pattern as above). That the terminal shows the rows at double size is checked by eye in Windows Terminal (`window-shot`), since no capture reports a row's size
- `panel.sh` — native client-local side panels: attached-client drawing, tabs, keyboard/mouse actions, conversation input while open, scrolling, resize reflow, delayed-update guards and in-place upgrade persistence (also runs on Linux and macOS); `TEST_STRIP` optionally exercises the real strip provider
- `win32-palette.sh` — `display-palette`'s rows and what a pick runs, the picker's stderr being the popup's console (an invalid handle before FZT-75), and a failing picker (not 0, nor 130 for a cancel) keeping the popup open until a key; `win32-palette-pick.ps1` stands in for fzt, and keys reach the pseudo-console client with `send-keys -K`
- `win32-keep-alive.sh` — a session with `keep-alive-window` set opens that window when its last one goes by kill-window, the shell exiting or move-window, and still ends by kill-session or when the replacement's program exits within a second
- `win32-reorder-session.sh` — `reorder-session` moves a session to the front, the back, one place either way, or before or after a named session in the sessions row (the `S:` loop's index order); a bad place changes nothing, and a session made afterwards goes at the end
- `win32-set-status.sh` — `set-window-status` and `set-session-status` set a window's Claude state (the window option `@claude`, its tab color) by hand: `working` and `waiting` set it, `done` unsets it, anything else is refused; the session form sets every window in its session and no other (TMUX-67)
- `win32-caller.sh` — a program in a background pane can target its own window with `{caller}`, and `play-sound` rejects a missing file
- `win32-session-set.sh` — with `@session-set-dir` set the server writes `live/<socket>.set` itself, only when something in it changed (a pane's Claude session, a reported folder, a program started in a pane), records each window it destroys (not one moved, not the at menu's, none at `kill-server`) in `closed-windows`, at most 25, and `reopen-window` rebuilds the newest at its place with its splits, layout, active pane, zoom and Claude session or restarted program, making its session again if it has gone (13 tests)
- `win32-session-offer.sh` — a server offers the snapshot an earlier server of its name left in a menu on the first client to attach (pseudo-console client, keys by `send-keys -K`): Enter rebuilds it in place of the fresh session (sessions in the sessions row's order, as made or as reorder-session left it, not by name; a zoomed window zoomed with its layout; each session's current and last window), Escape archives it, a server no client showed is archived without an offer, `restore-set` rebuilds an archived snapshot beside the sessions there, a set saved before this sign-in comes back with no client and no offer with the first client on the session it showed, and one that can't finish leaves the fresh session and is offered next rather than run again (`@session-set-signin` stands in for the sign-in time)
- `win32-restore-set.sh` — `restore-set` runs a window at a time: reads are answered with `#{server_restore}` and `restore-set` with no file reporting progress, a second restore is refused, a client's `new-window` in a session the restore is making waits for the end while one elsewhere runs, `upgrade-server` says it waits, windows keep their order however a client moves about, a window that can't start loses only itself and is named in the exit, a dying client or a hook running tmux doesn't stop it, the windows it removes aren't closed windows, and `kill-server` or the server dying part way leaves the set to be offered again (TMUX-109). A hook of `run-shell -d` paces the restore, so it is idle rather than heavy
- `win32-busy-server.sh` — clients of a server busy on its main thread wait rather than being told there is no server (before TMUX-109 the 9th got that, each client taking two of 16 connection passes), one heard nothing for ten seconds says so and carries on, and only a server that has gone reads "no server running". `source-file` of a measured length keeps one core busy
- `win32-new-window-draw.sh` — `new-window -W` switches the client only once the new pane has drawn (not on ConPTY's setup alone), fails without switching when the program exits or the window is killed first, and a killed waiting command gives the wait up
- `win32-new-window-options.sh` — `new-window -o name=value` sets window options on the new window before its program can end: with `remain-on-exit=failed` a program that fails at once keeps its window, output and exit status, one that succeeds closes it, a bad `-o` makes no window, and `-W` switches to the dead pane once its message is drawn (TMUX-52)
- `win32-global-foreground.sh` — `#{global_key_terminal_foreground}` is 1 when the client's terminal (a window of a process it runs under) had the focus at a global key, else 0; `win32-foreground.ps1` presses Win+` only on a CI runner with a desktop of its own (`ci_desktop` in `win32-test.sh`), which upstairspc's runner, in session 0, is not; `win32-control-client.sh`'s global key test likewise
- `win32-flight.sh` — a server's flight record (`docs/flight-record.md`): a clean end leaves none and a line saying how, a forced kill leaves a report the next server writes and tells the first client about, with the moment an attached client lost the server, and `upgrade-server` reports nothing (TMUX-40; `regress/flight.sh` covers the same on Linux)
- `win32-footer.sh` — `status-footer` keeps its own row beside the top bars through pane output, prompts, resizing, hidden bars and an upgrade, with its own clicks and condition; a `#()` job in it runs when told by `refresh-client -S` or when its command changes, not on a redraw (TMUX-112)
- `win32-start-program.sh` — `start-program` runs a program from the server with no shell, keeps an argument with spaces whole, and fails with the program's name when it can't start; the Windows CI runner has no desktop, so a press reaching the `global-no-client` table was tested by hand (HOMECFG-94)
- `win32-upgrade.sh` — `upgrade-server` hands a server with an attached client (unfocused, its pane asking for focus reports) to another process without restarting its panes, waits while copy mode is open, carries on when the new build fails, keeps the sessions row's order, and keeps the global environment as it was, less its handover variable `TMUX_UPGRADE`, in it and in new panes (6 tests; runs beside `conpty.dll`)
- `win32-upgrade-keys.sh` — upgrades from the pre-footer build and between builds with deliberately different key numbers, preserving all bindings, custom tables, modifiers, notes, Unicode, unbinds and key options. Upgrade state version 2 names keys; version 1 imports the pre-footer numeric layout when its saved options have no `status-footer`.

No CI builds for macOS: GitHub's macOS runners stopped being dependable, so the work Mac builds this repo itself from the GitHub push mirror (`sh autogen.sh && ./configure --enable-utf8proc && make`, Homebrew's autoconf, automake, pkgconf, libevent and utf8proc) and runs `regress/palette.sh`, `regress/hold.sh`, `regress/upgrade.sh` and `regress/play-sound.sh` there. The macOS keyboard (held modifiers, the global table as registered hotkeys) is `osdep-darwin-keys.c`.

CI's `linux` job does the same on Ubuntu (apt's autoconf, automake, pkg-config, bison, libevent, ncurses and utf8proc) for Nelson's Linux machine, with the same two tests and `regress/upgrade.sh` (`upgrade-server` on Linux: the new build is started from the old server and inherits every pty and socket at the same descriptor number, so nothing restarts). `adopt-pane` takes a pane's pty from another server (`pidfd_getfd`), for moving a server that has no `upgrade-server` onto the fork (profile 2's `bin/tmux-move-server`). The Linux keyboard is `osdep-linux-keys.c`: it reads the keyboards' evdev devices, so it needs the user in the `input` group and works under X11 and Wayland alike; the build is the `tmux-linux` artifact.

`win32-run.sh TEST` fails a test that leaves anything running from the `build` folder 10 s after it ends, naming each process (an error annotation in CI), then ends those; it refuses to start a test while one is already running and ends nothing then (TMUX-35). A test kills every server it starts in its exit trap.

`win32-test.sh` gives each invocation a private `TEST_SOCKET`; secondary servers append a suffix to it. The runner stops a test after `TEST_TIMEOUT` seconds (300 by default), then performs its usual process cleanup. Config parsing also limits each client to `WAIT_TIMEOUT` seconds and reports the fixture being parsed.

They wait with `regress/win32-wait.sh` (poll until a condition holds, fail after 10 s), not fixed sleeps. Match a command's output with `^`: the typed command line holds the same text.

## Where changes land

GitHub (https://github.com/nelsong6/at-tmux) and Forgejo stay in step, so a change can land on either, and the work Mac and Linux machine land theirs on GitHub. `git config core.hooksPath .githooks` makes a push on a Mac or Linux machine build and run the tests CI's `linux` job lists.

A push to `master` on either side fast-forwards the other: `.github/workflows/forgejo-sync.yml` on the NAS's sync runner, because Forgejo is closed to the internet, and `.forgejo/workflows/github-sync.yml`, which signs in to GitHub with the repo secret `GH_SYNC_TOKEN`. Forgejo's push runs CI and the release. Nothing is forced: if `master` moves on both sides, the sync fails and shows in Alerts, and a session merges them.

## Publishing

CI's `release` job makes every master commit whose run passed a Forgejo release, tagged `git describe --tags --always --exclude '*-g*'` (the exclude keeps one release's tag from being the next one's base), holding `tmux-windows-<tag>.zip` (the signed Release `tmux.exe` with its `tmux.pdb`, `conpty.dll` and `OpenConsole.exe`) and its `.sha256`.

A master run the runner dropped leaves that commit with no release. Start it again with `POST /api/v1/repos/nelsong6/at-tmux/actions/workflows/ci.yml/dispatches` and the body `{"ref":"master"}`: it runs and publishes as the push would have. Forgejo's API has no rerun of its own (TMUX-114).

After the complete release is published, CI starts home-sync on every PC. home-sync verifies the signed Windows package, switches `C:\Program Files\at-home\tmux\current`, and reconciles existing servers using `upgrade-server` while preserving their panes. The manual `publish.ps1` was retired by HOMECFG-110; merges need no separate publishing command.

## Winget Package Submission

Package: `arndawg.tmux-windows` in `microsoft/winget-pkgs`.

### How to submit a new version

1. **Sync the fork** before anything else:
   ```bash
   gh api repos/arndawg/winget-pkgs/merge-upstream -X POST -f branch=master
   ```

2. **Create a branch** from the synced master:
   ```bash
   MASTER_SHA=$(gh api repos/arndawg/winget-pkgs/git/refs/heads/master --jq '.object.sha')
   gh api repos/arndawg/winget-pkgs/git/refs -X POST \
     -f ref=refs/heads/arndawg.tmux-windows-VERSION \
     -f sha="$MASTER_SHA"
   ```

3. **Create files via the contents API** (one PUT per file). Do NOT use the git trees API — on a repo this large it produces phantom diffs with hundreds of unrelated files. The contents API creates clean per-file commits:
   ```bash
   CONTENT=$(printf '%s' "$YAML" | base64 -w0)
   gh api repos/arndawg/winget-pkgs/contents/manifests/a/arndawg/tmux-windows/VERSION/FILENAME \
     -X PUT -f message="Add manifest" -f content="$CONTENT" \
     -f branch=arndawg.tmux-windows-VERSION
   ```
   Three files needed: `arndawg.tmux-windows.installer.yaml`, `arndawg.tmux-windows.locale.en-US.yaml`, `arndawg.tmux-windows.yaml`.

4. **Verify** the branch diff before creating the PR:
   ```bash
   gh api repos/arndawg/winget-pkgs/compare/master...arndawg.tmux-windows-VERSION \
     --jq '{ahead_by: .ahead_by, files: [.files[].filename]}'
   ```
   Must show exactly 3 files and 3 commits ahead.

5. **Create the PR** with `gh pr create --repo microsoft/winget-pkgs`.

6. **Validation takes up to 3 hours.** Monitor with:
   ```bash
   gh pr view PRNUM --repo microsoft/winget-pkgs --json labels,comments \
     --jq '{labels: [.labels[].name], latest: .comments[-1].body[:200]}'
   ```
   Look for the `Validation-Completed` label. The Azure DevOps pipeline comment has a badge link.

### Manifest template reference

Copy from the previous version directory in `manifests/a/arndawg/tmux-windows/` — update `PackageVersion`, `InstallerUrl`, `InstallerSha256`, `ReleaseDate`, `ReleaseNotes`, and `ReleaseNotesUrl`.

### Manifest formatting

Do **not** add a trailing blank line to manifest YAML files. Earlier versions (3.6a-win32.1/3/4) had one, but from v3.6a-win32.6 onward we omit it.

## Known Quirks

- A second client reads and writes files for the server synchronously (`file.c`, `_WIN32`): libevent's bufferevent never fires on a file descriptor that isn't a socket, so `source-file`, `load-buffer` and `save-buffer` from a second client hung until HOMECFG-44. The read happens in the client, so a newer client fixes it against an older server
- Command-line arguments arrive in the ANSI code page (no `wmain`/UTF-8 manifest), so non-ASCII in argv is mangled: `display -p '#{s/✳/*/:pane_title}'` inserted `*` between every byte. Put non-ASCII formats in a config file
- `default-shell` with forward slashes (`C:/WINDOWS/system32/cmd.exe`) leaves the first pane dead and the server exits; use backslashes
- A server started from Git Bash passes ignoring Ctrl-C on to its panes (issue 6), so the tests can't exercise Ctrl-C
