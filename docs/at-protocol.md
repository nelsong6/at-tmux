# at-protocol: what the server says to an at-terminal client

at-tmux and at-terminal are one program in two processes: neither is ever used without
the other (HOMECFG-60, ATT-7). Where they need to say something the terminal protocol
can't, they say it in at-protocol (https://forgejo.romaine.life/romaine-life/at-protocol),
one package both compile, pinned in `dep/vcpkg-overlay-ports/at-protocol/portfile.cmake`:
its `REF` is the one place this build's version of the language is chosen, and the build
says that commit in its hello. `#{at_protocol_version}` shows it.

Every build speaks it (`HAVE_AT_PROTOCOL`), since at-terminal is built on Rio for
Windows, macOS and Linux (ATT-19, TMUX-239). The Windows build gets the package through
vcpkg from Forgejo (`CMakeLists.txt`). The Mac and Linux builds can't reach Forgejo, so
`configure` runs `dep/fetch.sh`, which reads the same `REF` from the portfile and
fetches that commit from the package's GitHub push mirror
(https://github.com/romaine-life/at-protocol, private, so git needs a GitHub sign-in) into
`dep/at-protocol`, again only when the `REF` changes; changing the portfile runs
`configure` again. `--disable-at-protocol` builds without it: no hello, sixel to every
terminal, and `#{at_protocol_version}` empty. at-protocol carries images, so it needs
them, which every build now has (`--disable-sixel` turns them off).

## The handshake (tty-at.c)

With its opening requests to a client terminal (`tty_send_requests`), the server sends
`hello`, an APC string `ESC _ at; <base64> ESC \`. A terminal that speaks the language
answers on its input with its own `hello`; `tty_keys_at` reads it, as the device
attributes replies are read.

- The same version: the client speaks at-protocol (`tty->at_speaks`), and is drawn again.
- Another version: the server tells that client on one line and, when its own file on
  disk is newer than the running process (home-sync installed a release and switched the
  `current` junction under it, or on a Mac or Linux machine a new build was installed
  over it: `proc_pidpath`, `/proc/self/exe`), hands itself to it with `upgrade-server`.
  Otherwise home-sync's next run brings the pair together. Either way that client keeps
  getting sixel, so nothing is lost in between.
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
reads the placements where sixel was. `regress/at-protocol.sh` does the same on macOS and
Linux, and checks the build speaks the version the portfile pins.

## Terminal features

A terminal that names itself `Rio` or `at-terminal` in its XTVERSION answer gets the
features Rio has (`tty-features.c`): curly and coloured underlines, the kitty keyboard
protocol, synchronized output, OSC 8 and OSC 7, cursor colour and style, and focus
reports.
