# Each invocation owns its sockets, including clients started inside panes.
# The scripts send cmd.exe commands and expect its prompt.
SHELL=$COMSPEC
export SHELL

if [ -z "$TEST_SOCKET" ]; then
	_socket_dir=$(mktemp -d) || exit 1
	_socket_name=${_socket_dir##*/}
	TEST_SOCKET=tmux-test-${_socket_name#*.}
	rmdir "$_socket_dir"
	unset _socket_dir _socket_name
fi
export TEST_SOCKET

# ci_desktop: a CI runner with a desktop of its own, where a test may simulate
# key presses. On a developer's PC they would land on their desktop, and a
# runner in session 0 (a service's, as upstairspc's Forgejo runner) has none
# that takes input.
ci_desktop() {
	[ -n "$CI" ] || return 1
	_session=$("$(cygpath "$SYSTEMROOT")/System32/WindowsPowerShell/v1.0/powershell.exe" \
	    -NoProfile -Command '[Diagnostics.Process]::GetCurrentProcess().SessionId' | tr -d '\r')
	[ -n "$_session" ] && [ "$_session" != 0 ]
}
