# at-protocol: what the server says to an at-terminal client

at-tmux and at-terminal are one program in two processes: neither is ever used without
the other (HOMECFG-60, ATT-7). Where they need to say something the terminal protocol
can't, they say it in at-protocol (https://forgejo.romaine.life/romaine-life/at-protocol),
one package both compile, pinned in `dep/vcpkg-overlay-ports/at-protocol/portfile.cmake`:
its `REF` is the one place this build's version of the language is chosen, and the build
says that commit in its hello. `#{at_protocol_version}` shows it.

## The handshake (tty-at.c)

With its opening requests to a client terminal (`tty_send_requests`), the server sends
`hello`, an APC string `ESC _ at; <base64> ESC \`. A terminal that speaks the language
answers on its input with its own `hello`; `tty_keys_at` reads it, as the device
attributes replies are read.

- The same version: the client speaks at-protocol (`tty->at_speaks`), and is drawn again.
- Another version: the server tells that client on one line and, when its own file on
  disk is newer than the running process (home-sync installed a release and switched the
  `current` junction under it), hands itself to it with `upgrade-server`. Otherwise
  home-sync's next run brings the pair together. Either way that client keeps getting
  sixel, so nothing is lost in between.
- No answer (any other terminal, a test server's pane): sixel, as always.

## Images

A client that speaks at-protocol is sent each virtual image (kitty graphics `a=T` with
`U=1`, image-placeholder.c) once, with its pixels as the program sent them and the
grid of cells the whole picture fills (`image-store`), under an ID of the server's (`at_id`): the program's ID is its own pane's, and every pane's pictures go to the one terminal (TMUX-222). Then a run of placeholders is one
`image-place`, naming the picture's cells and the terminal's. The terminal keeps the
picture and writes those cells into its text buffer, where its own scrolling and
redrawing carry them. When the image goes, every client that has it gets `image-drop`.

A virtual image restored by `upgrade-server` from a build that kept no pixels goes as
sixel until the program sends it again.

## Testing

`regress/win32-placed-images.sh` plays the terminal: it sends the inner client a hello
with the wrong version and reads the message, then one with `#{at_protocol_version}` and
reads the placements where sixel was.
