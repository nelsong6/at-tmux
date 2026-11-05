# Flight record

Every server keeps a small file mapped into memory, `~/.tmux/flight/<socket>-<pid>.rec`
(`TMUX_FLIGHT_DIR` moves it): when and how it started, the build, the package and job
it runs inside, when it last did any work, the format it was expanding, and its last
256 events. Writing to it is a plain memory write, and the system keeps the pages when
the process dies, so a kill with no chance to clean up still leaves it. There is no
timer: the server stamps it while doing its normal work.

A clean end (`kill-server`, the last session closing, `upgrade-server`) writes a line
to `~/.tmux/errors/tmux-<pid>.log` and removes the record. So a record left by a dead
server means the server ended without saying so. The system drops a server's hold on
its file when the process goes, which is how the next server on that socket tells a
dead server's record from a live one's.

That next server writes `~/.tmux/flight/ended/tmux-<pid>.log`, adds a line to
`show-messages`, and shows it to the first client to attach. Reports older than 30
days are removed. `ended:` is one of:

- `crashed: <reason>`: an exception, a bad C runtime argument, `abort()` or tmux's
  own `fatal`. On Windows `%TEMP%\tmux-crash-<pid>.log` holds the stack.
- `with no record of why`: killed from outside, or a failure nothing in the process
  could catch, such as heap corruption's fail-fast.

`last worked` is the last second the server's loop ran. `client lost` is the moment an
attached client saw the connection drop, which is the time of death, and reads `not
recorded` if no client was attached. Then only `last worked` and the next server's
start bound it.

The record names no killer: a process's exit isn't visible to the process. It doesn't
survive a power cut, since the pages may not have reached the disk.

## Leaving packages

A server started from a packaged desktop app (the Claude desktop app, for one) would
stay in the app's container, and the app's next update would end it. So
`win32_launch_server` and `upgrade-server` both start the server with the desktop app
breakaway policy. `CREATE_BREAKAWAY_FROM_JOB` alone reports success and leaves the
child in the container. `ran as:` in a report says where the server really was.
