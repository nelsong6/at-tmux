# Flight record

Every server keeps a small file mapped into memory, `~/.tmux/flight/<socket>-<pid>.rec`
(`TMUX_FLIGHT_DIR` moves it): when and how it started, the build, the package and job
it runs inside, when it last did any work, the format it was expanding, and its last
256 events. Writing to it is a plain memory write, and the system keeps the pages when
the process dies, so a kill with no chance to clean up still leaves it. There is no
timer: the server stamps it while doing its normal work.

A clean end (`kill-server`, the last session closing, `upgrade-server`) writes a line
to `~/.tmux/errors/tmux-<pid>.log` and removes the record. So a record left by a dead
server means the server ended without saying so, unless Windows said it for it (see
Windows ending the session). The system drops a server's hold on its file when the
process goes, which is how the next server on that socket tells a dead server's record
from a live one's.

That next server writes `~/.tmux/flight/ended/tmux-<pid>.log`, adds a line to
`show-messages`, and, unless Windows ended it, shows that line to the first client to
attach. Reports older than 30 days are removed. `ended:` is one of:

- `crashed: <reason>`: an exception, a bad C runtime argument, `abort()`, tmux's
  own `fatal`, or a fail-fast. On Windows `%TEMP%\tmux-crash-<pid>.log` holds the
  stack.
- `with Windows: Windows ended the session at <time>`: a restart, a shutdown or a
  sign-out. Nothing went wrong, so no client is told.
- `before this Windows sign-in: no word from Windows`: the server last worked before
  this sign-in and Windows never told it the session was ending. A power cut, Windows
  failing, or a kill before a later restart read the same.
- `with no record of why`: killed from outside.

`last worked` is the last second the server's loop ran. `client lost` is the moment an
attached client saw the connection drop, which is the time of death, and reads `not
recorded` if no client was attached. Then only `last worked` and the next server's
start bound it.

The record names no killer: a process's exit isn't visible to the process. It may not
survive a power cut, since the pages may not have reached the disk: then there is no
report at all, and if some survived it reads `before this Windows sign-in`.

## Windows ending the session

Windows tells every top-level window the session is ending, and a hidden one counts.
It is the only word a server gets: a process with user32 loaded isn't sent the console
events for sign-out and shutdown. So each server keeps a hidden window on a thread of
its own, blocked in `GetMessage` until a message comes. `WM_ENDSESSION` saying the end
is going ahead marks the record and flushes it to disk, since the process can go as
soon as that returns. `WM_QUERYENDSESSION` is ignored because the shutdown can still
be called off, and `ENDSESSION_CLOSEAPP`, an installer closing the program, leaves the
session running. A sign-out and a forced restart (`shutdown /r /t 60`, which the boot
proof runs) were both seen to deliver it on a real PC, about 100 ms after the first
message.

The sign-in time is the fallback for a server Windows gave no word. It proves when
the server stopped working and no more, so that report doesn't say Windows ended it.

## The session set's menu

A set lost while the PC stayed up is offered with how its server ended, so a crash,
an outside kill and an exit don't look the same. The menu finds the report by the pid
in the snapshot, which holds however many servers came and went since. A report older
than the snapshot belongs to an earlier process with that pid, and counts for nothing.

| Title | The line says | From |
| --- | --- | --- |
| Server crashed | crashed: the reason, and the report's path | `ended: crashed:` |
| Server killed | killed from outside, and the report's path | `ended: with no record of why` |
| Ended with Windows | Windows ended the session, and the report's path | `ended: with Windows` |
| Server shut down | told to exit | the snapshot's `stopped` line, from `kill-server` or a signal |
| Previous session set | ended before this sign-in, and the report's path | `ended: before this Windows sign-in` |
| Previous session set | stopped, and nothing says why | no report and no `stopped` line |

The last happens for a set saved by a build older than this. A set from before this
Windows sign-in ended with the PC and has no line saying how, so the Windows rows
show only when the sign-in time can't be told.

## Fail-fasts on Windows

A fail-fast (heap corruption, a stack cookie) ends the process without running
anything in it, so no handler of ours can write. Windows' error reporting still
sees it, so every tmux process registers `tmux-wer.dll`, from its exe's real folder
rather than the `current` junction, and lists that path under
`HKCU\Software\Microsoft\Windows\Windows Error Reporting\RuntimeExceptionHelperModules`,
which is what lets Windows load it. The failed
process waits while the DLL, in Windows' own process, reads the log path and
symbol folder from it, walks its stack and writes the same log. It leaves the
crash unclaimed, so Windows' own dump and event still happen, and does nothing if
the process's handler already finished. A parent's error mode is inherited, and
a Go parent turns this reporting off, so `win32_crash_init` clears that mode. The
record itself can't be written from outside, so the next server takes the reason
from the crash log.

## Leaving packages

A server started from a packaged desktop app (the Claude desktop app, for one) would
stay in the app's container, and the app's next update would end it. So
`win32_launch_server` and `upgrade-server` both start the server with the desktop app
breakaway policy. `CREATE_BREAKAWAY_FROM_JOB` alone reports success and leaves the
child in the container. `ran as:` in a report says where the server really was.
