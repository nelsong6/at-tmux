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
