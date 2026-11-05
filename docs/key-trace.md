# Key trace

When typing stops reaching a program while its output keeps coming, the question is
which step dropped the keys. The server follows each key by time only; it never keeps
which key it was. `tmux key-trace` prints the last 128:

```
2.1s ago: seen +0ms, read +14ms, went to pane %79
1.4s ago: seen +0ms, read +9ms, went to a menu or popup
0.3s ago: seen +0ms, never read
```

`seen` is when the server's loop heard of the press and `read` when the key arrived from
the client, both counted from the press itself. `went to` is what took it: a pane, a
menu or popup, the command prompt, a panel, a message, copy mode, a key binding, or a
pane with input off.

On Windows a press comes from the keyboard hook behind the global key table, so the
trace needs a binding in that table, and it counts only presses made while the
terminal of the client in use is in front. Keys the terminal keeps for itself, such as
its zoom, are seen and never read; one alone says nothing, so the server speaks up from
the second.

When keys stop, the server says so without being asked: in `show-messages`, in
`~/.tmux/errors/tmux-<pid>.log` and in the flight record.

| Message | Where the keys stopped |
| --- | --- |
| `keys pressed in the terminal are not reaching tmux` | the terminal or the attached client |
| `the server took N ms to see a key` | the server's own loop was held up |
| `keys are stuck going into pane %N` | between the server and the pane's console |

Each of the first and third has a matching line when keys move again. If keys read as
`went to pane` and the program still doesn't react, they got as far as its console, so
the stop is in the program.

`key-trace -p` records a press as the hook would, for a test or to check the path with
no key pressed.

The one-second timer runs only while a key is unaccounted for.
