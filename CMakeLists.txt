cmake_minimum_required(VERSION 3.16)
project(tmux C)

# Require Windows 10 1809+ for ConPTY
set(CMAKE_SYSTEM_VERSION 10.0.17763.0)

# Use MSVC runtime
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

# Options

# Find libevent
find_package(libevent CONFIG QUIET)
if(NOT libevent_FOUND)
    # Try pkg-config as fallback
    find_package(PkgConfig)
    if(PKG_CONFIG_FOUND)
        pkg_check_modules(LIBEVENT REQUIRED libevent)
    else()
        # Manual search
        find_path(LIBEVENT_INCLUDE_DIRS event2/event.h)
        find_library(LIBEVENT_LIBRARIES NAMES event libevent)
        if(NOT LIBEVENT_INCLUDE_DIRS OR NOT LIBEVENT_LIBRARIES)
            message(FATAL_ERROR "libevent not found. Install via vcpkg: vcpkg install libevent")
        endif()
    endif()
endif()

# cmd-parse.c generation from cmd-parse.y
# Try to find bison (WinFlexBison on Windows)
find_program(BISON_EXECUTABLE NAMES win_bison bison)
if(BISON_EXECUTABLE)
    add_custom_command(
        OUTPUT ${CMAKE_CURRENT_SOURCE_DIR}/cmd-parse.c
        COMMAND ${BISON_EXECUTABLE} -o ${CMAKE_CURRENT_SOURCE_DIR}/cmd-parse.c
                ${CMAKE_CURRENT_SOURCE_DIR}/cmd-parse.y
        DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/cmd-parse.y
        COMMENT "Generating cmd-parse.c from cmd-parse.y"
    )
else()
    if(NOT EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/cmd-parse.c)
        message(FATAL_ERROR
            "bison/win_bison not found and cmd-parse.c does not exist.\n"
            "Install WinFlexBison via vcpkg: vcpkg install winflex")
    else()
        message(STATUS "Using pre-generated cmd-parse.c")
    endif()
endif()

# Core tmux source files
set(TMUX_SOURCES
    alerts.c
    arguments.c
    attributes.c
    cfg.c
    client.c
    cmd.c
    cmd-adopt-pane.c
    cmd-attach-session.c
    cmd-bind-key.c
    cmd-break-pane.c
    cmd-capture-pane.c
    cmd-choose-tree.c
    cmd-close.c
    cmd-command-prompt.c
    cmd-confirm-before.c
    cmd-copy-mode.c
    cmd-copy-name.c
    cmd-detach-client.c
    cmd-display-menu.c
    cmd-display-message.c
    cmd-display-palette.c
    cmd-play-sound.c
    cmd-display-panes.c
    cmd-find.c
    cmd-export-pane.c
    cmd-find-window.c
    cmd-if-shell.c
    cmd-join-pane.c
    cmd-kill-pane.c
    cmd-kill-server.c
    cmd-kill-session.c
    cmd-key-trace.c
    cmd-kill-window.c
    cmd-list-buffers.c
    cmd-list-clients.c
    cmd-list-keys.c
    cmd-list-panes.c
    cmd-list-sessions.c
    cmd-list-windows.c
    cmd-load-buffer.c
    cmd-lock-server.c
    cmd-move-window.c
    cmd-new-session.c
    cmd-new-window.c
    cmd-parse.c
    cmd-paste-buffer.c
    cmd-pipe-pane.c
    cmd-queue.c
    cmd-refresh-client.c
    cmd-rename-session.c
    cmd-reorder-session.c
    cmd-rename-window.c
    cmd-reopen-window.c
    cmd-restore-set.c
    cmd-resize-pane.c
    cmd-resize-window.c
    cmd-respawn-pane.c
    cmd-respawn-window.c
    cmd-rotate-window.c
    cmd-run-shell.c
    cmd-save-buffer.c
    cmd-select-layout.c
    cmd-select-pane.c
    cmd-select-window.c
    cmd-send-keys.c
    cmd-server-access.c
    cmd-set-buffer.c
    cmd-set-environment.c
    cmd-set-option.c
    cmd-set-status.c
    cmd-show-environment.c
    cmd-show-messages.c
    cmd-show-options.c
    cmd-show-prompt-history.c
    cmd-source-file.c
    cmd-split-window.c
    cmd-start-program.c
    cmd-swap-pane.c
    cmd-swap-window.c
    cmd-switch-client.c
    cmd-toggle-status-bars.c
    cmd-unbind-key.c
    cmd-upgrade-server.c
    cmd-wait-for.c
    colour.c
    control.c
    control-notify.c
    environ.c
    file.c
    format.c
    format-draw.c
    grid.c
    grid-reader.c
    grid-view.c
    hyperlinks.c
    image.c
    image-kitty.c
    image-placeholder.c
    image-sixel.c
    input.c
    input-keys.c
    job.c
    key-bindings.c
    at-defaults.c
    key-string.c
    layout.c
    layout-custom.c
    layout-set.c
    log.c
    menu.c
    mode-tree.c
    names.c
    notify.c
    options.c
    options-table.c
    paste.c
    popup.c
    proc.c
    regsub.c
    resize.c
    screen.c
    screen-redraw.c
    screen-write.c
    server.c
    server-acl.c
    server-client.c
    server-fn.c
    server-upgrade.c
    flight.c
    key-trace.c
    session-set.c
    session.c
    sort.c
    spawn.c
    status.c
    style.c
    tmux.c
    tty.c
    tty-acs.c
    tty-draw.c
    tty-at.c
    tty-features.c
    tty-keys.c
    tty-record.c
    tty-term.c
    utf8.c
    utf8-combined.c
    window.c
    window-buffer.c
    window-client.c
    window-clock.c
    window-copy.c
    window-customize.c
    window-tree.c
    xmalloc.c
)

# Windows-specific osdep
set(TMUX_OSDEP_SOURCES
    osdep-windows.c
)

# compat library sources (subset needed for Windows)
# Note: closefrom, daemon, setenv, getprogname, getpeereid, clock_gettime
# are provided by win32/win32-compat.c; forkpty/fdforkpty are replaced by ConPTY
set(TMUX_COMPAT_SOURCES
    compat/imsg.c
    compat/imsg-buffer.c
    compat/vis.c
    compat/unvis.c
    compat/strlcpy.c
    compat/strlcat.c
    compat/strtonum.c
    compat/asprintf.c
    compat/reallocarray.c
    compat/recallocarray.c
    compat/explicit_bzero.c
    compat/freezero.c
    compat/getdtablecount.c
    compat/getdtablesize.c
    # htonll.c/ntohll.c not needed - winsock2.h provides these
    compat/base64.c
    compat/strndup.c
    # strnlen: MSVC CRT provides strnlen; we define HAVE_STRNLEN in platform.h
    compat/memmem.c
    compat/getline.c
    compat/fgetln.c
    compat/strcasestr.c
    compat/getopt_long.c
    compat/err.c
)

# win32 layer sources
set(TMUX_WIN32_SOURCES
    win32/win32-compat.c
    win32/win32-crash.c
    win32/win32-ipc.c
    win32/win32-process.c
    win32/win32-pty.c
    win32/win32-signal.c
    win32/win32-terminfo.c
    win32/win32-tty.c
    win32/win32-regex.c
)

# utf8proc answers how wide a character is. compat/utf8proc.c is not built: it passes
# code points in wchar_t, 16 bits here, so utf8.c calls the library directly.
find_package(utf8proc CONFIG REQUIRED)

# at-protocol: the language the server speaks to an at-terminal client (ATT-7,
# docs/at-protocol.md), pinned in dep/vcpkg-overlay-ports/at-protocol.
find_package(at-protocol CONFIG REQUIRED)

# display-palette's command descriptions, from tmux.1
add_executable(palette-descriptions tools/palette-descriptions.c)
target_compile_definitions(palette-descriptions PRIVATE _CRT_SECURE_NO_WARNINGS)
add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/palette-descriptions.h
    COMMAND palette-descriptions ${CMAKE_CURRENT_SOURCE_DIR}/tmux.1
            ${CMAKE_CURRENT_BINARY_DIR}/palette-descriptions.h
    DEPENDS palette-descriptions ${CMAKE_CURRENT_SOURCE_DIR}/tmux.1
    COMMENT "Generating palette-descriptions.h from tmux.1"
)

# Build tmux executable
add_executable(tmux
    ${CMAKE_CURRENT_BINARY_DIR}/palette-descriptions.h
    ${TMUX_SOURCES}
    ${TMUX_OSDEP_SOURCES}
    ${TMUX_COMPAT_SOURCES}
    ${TMUX_WIN32_SOURCES}
)

# Compiler definitions
target_compile_definitions(tmux PRIVATE
    _WIN32
    WIN32_LEAN_AND_MEAN
    _CRT_SECURE_NO_WARNINGS
    _CRT_NONSTDC_NO_DEPRECATE
    PACKAGE_NAME="tmux"
    PACKAGE_VERSION="3.6a-win32"
    TMUX_CONF="${CMAKE_INSTALL_PREFIX}/etc/tmux.conf"
    # Functions provided by compat/ source files we compile:
    # Do NOT define HAVE_X for these - compat.h needs to declare them
    # and the compat .c files provide implementations.
    # The HAVE_IMSG flag tells tmux to use the compat imsg.
    HAVE_IMSG
    HAVE_EVENT2_EVENT_H
    ENABLE_SIXEL
    HAVE_AT_PROTOCOL
    HAVE_STDINT_H
)

# Include directories
target_include_directories(tmux PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/compat
    ${CMAKE_CURRENT_SOURCE_DIR}/win32
)

# libevent include/link
if(libevent_FOUND)
    target_link_libraries(tmux PRIVATE libevent::core libevent::extra)
elseif(LIBEVENT_INCLUDE_DIRS)
    target_include_directories(tmux PRIVATE ${LIBEVENT_INCLUDE_DIRS})
    target_link_libraries(tmux PRIVATE ${LIBEVENT_LIBRARIES})
endif()

# Windows system libraries
target_link_libraries(tmux PRIVATE
    ws2_32
    advapi32
    kernel32
    user32
    shell32
    ole32
    ntdll
    winmm
    wtsapi32
)

target_link_libraries(tmux PRIVATE utf8proc::utf8proc at-protocol::at-protocol)

# MSVC-specific settings
if(MSVC)
    target_compile_options(tmux PRIVATE
        /W3
        /wd4005  # macro redefinition
        /wd4018  # signed/unsigned mismatch
        /wd4028  # parameter differs
        /wd4047  # indirection levels differ
        /wd4090  # const qualifier
        /wd4133  # incompatible types
        /wd4146  # unary minus on unsigned
        /wd4244  # conversion, possible loss of data
        /wd4267  # size_t to int
        /wd4456  # local declaration hides
        /wd4457  # parameter hides
        /wd4701  # potentially uninitialized
        /wd4702  # unreachable code
        /wd4996  # deprecated POSIX names
    )
    # A release ships its PDB, so a crash log names function, file and line.
    # /DEBUG alone turns off the optimizations a Release link has by default.
    # /Z7 keeps each object's debug information in the object, which sccache can
    # cache (it can't a shared /Zi PDB); the link still writes tmux.pdb.
    target_compile_options(tmux PRIVATE $<$<CONFIG:Release>:/Z7>)
    target_link_options(tmux PRIVATE
        $<$<CONFIG:Release>:/DEBUG>
        $<$<CONFIG:Release>:/OPT:REF>
        $<$<CONFIG:Release>:/OPT:ICF>
    )
    # Use C11
    set_property(TARGET tmux PROPERTY C_STANDARD 11)
endif()

# Windows error reporting loads this to write the crash log of a process that
# failed too abruptly to write its own.
add_library(tmux-wer SHARED win32/tmux-wer.c win32/win32-crash.c)
target_compile_definitions(tmux-wer PRIVATE _CRT_SECURE_NO_WARNINGS)
add_dependencies(tmux tmux-wer)

add_executable(alt-tab-test regress/alt-tab.c)

# tmux.exe loads conpty.dll and OpenConsole.exe, the pseudoconsole Windows Terminal
# ships, from its own folder, so the package carries them: Microsoft's NuGet package,
# through Artifact Keeper.
set(CONPTY_VERSION 1.25.260930003)
set(CONPTY_PACKAGE ${CMAKE_CURRENT_BINARY_DIR}/conpty-${CONPTY_VERSION}.nupkg)
file(DOWNLOAD
    https://artifacts.home.romaine.life/nuget/nuget/v3/flatcontainer/microsoft.windows.console.conpty/${CONPTY_VERSION}/microsoft.windows.console.conpty.${CONPTY_VERSION}.nupkg
    ${CONPTY_PACKAGE}
    EXPECTED_HASH SHA256=02b07b349af66d801159bdf9e440d4a1ce78bb951f37fc8609731665afdae7ee
    TLS_VERIFY ON)
file(ARCHIVE_EXTRACT INPUT ${CONPTY_PACKAGE} DESTINATION ${CMAKE_CURRENT_BINARY_DIR}/conpty
    PATTERNS runtimes/win-x64/native/conpty.dll build/native/runtimes/x64/OpenConsole.exe)

# The at-protocol commit this build speaks, beside tmux.exe and as its own release
# asset, for home-sync to install it with the at-terminal that speaks the same (ATT-7).
set(AT_PROTOCOL_PORT ${CMAKE_CURRENT_SOURCE_DIR}/dep/vcpkg-overlay-ports/at-protocol/portfile.cmake)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${AT_PROTOCOL_PORT})
file(STRINGS ${AT_PROTOCOL_PORT} AT_PROTOCOL_REF REGEX "^set\\(REF [0-9a-f]+\\)")
string(REGEX REPLACE "^set\\(REF ([0-9a-f]+)\\).*$" "\\1" AT_PROTOCOL_REF "${AT_PROTOCOL_REF}")
if(NOT AT_PROTOCOL_REF)
    message(FATAL_ERROR "no set(REF <commit>) in ${AT_PROTOCOL_PORT}")
endif()
# The commit and a LF, as releases have always had it; file(WRITE) ends it CRLF on Windows.
file(CONFIGURE OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/at-protocol.txt CONTENT "${AT_PROTOCOL_REF}\n" NEWLINE_STYLE UNIX)

# Install: everything at the prefix root, each file a release asset under its own
# name (pipeline-templates' release suite, PIPT-33).
install(TARGETS tmux RUNTIME DESTINATION .)
install(FILES
    $<TARGET_FILE:tmux-wer>
    $<TARGET_PDB_FILE:tmux>
    ${CMAKE_CURRENT_BINARY_DIR}/conpty/runtimes/win-x64/native/conpty.dll
    ${CMAKE_CURRENT_BINARY_DIR}/conpty/build/native/runtimes/x64/OpenConsole.exe
    ${CMAKE_CURRENT_BINARY_DIR}/at-protocol.txt
    DESTINATION .)

# Tests: the regress/ scripts, each run by Git Bash through win32-run.sh. pipeline-
# templates' cmake suite runs them on every PR that changes the code, four at a
# time, and a failing one keeps the change from the PCs (PIPT-21). Each test has
# a folder of its own under t/ (regress/win32-stage.cmake): its own copy of the
# tmux.exe it runs and what that test needs beside it. Its TEMP is a folder of its
# own too, under a short root: libevent makes its socket pairs from a temporary
# file name, which must fit an AF_UNIX path (108 characters).
# win32-run.sh fails a test that leaves anything running from its folder
# (TEST_BUILD) and ends it, so it touches no other test's processes; TEST_SOCKET
# names the test's own servers (\\.\pipe\tmux-<user>-<label>). TIMEOUT is seconds.
enable_testing()
find_program(TMUX_TEST_BASH bash PATHS "$ENV{ProgramFiles}/Git/bin" NO_DEFAULT_PATH)
find_program(TMUX_TEST_PWSH pwsh)
if(NOT TMUX_TEST_BASH OR NOT TMUX_TEST_PWSH)
    message(FATAL_ERROR "the tests need Git for Windows' bash ($ENV{ProgramFiles}/Git/bin) and pwsh")
endif()
set(TMUX_TEST_DIR ${CMAKE_CURRENT_BINARY_DIR}/t)
# The Windows PowerShell the tests' panes run, with no profile
# (regress/win32-noprofile.c): the account's profile printed into the panes.
add_executable(test-powershell regress/win32-noprofile.c)
set_target_properties(test-powershell PROPERTIES OUTPUT_NAME powershell
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/test-powershell)
set(TMUX_TEST_CONPTY ${CMAKE_CURRENT_BINARY_DIR}/conpty-files)
file(COPY ${CMAKE_CURRENT_BINARY_DIR}/conpty/runtimes/win-x64/native/conpty.dll
    ${CMAKE_CURRENT_BINARY_DIR}/conpty/build/native/runtimes/x64/OpenConsole.exe
    DESTINATION ${TMUX_TEST_CONPTY})
set_property(GLOBAL PROPERTY TMUX_TEST_STAGE "")
string(MD5 TMUX_TEST_TEMP "${CMAKE_CURRENT_BINARY_DIR}")
string(SUBSTRING ${TMUX_TEST_TEMP} 0 8 TMUX_TEST_TEMP)
file(TO_CMAKE_PATH "$ENV{TEMP}/tmux-tests-${TMUX_TEST_TEMP}" TMUX_TEST_TEMP)
string(LENGTH "${TMUX_TEST_TEMP}" length)
if(length GREATER 70)
    message(FATAL_ERROR "TEMP is too long for the tests' temporary folders: ${TMUX_TEST_TEMP}")
endif()

# tmux_test(NAME SCRIPT KIND [TIMEOUT s] [LOCK resource]): KIND names what sits
# beside the test's tmux.exe (win32-stage.cmake).
function(tmux_test name script kind)
    cmake_parse_arguments(T "" "TIMEOUT;LOCK" "" ${ARGN})
    set(dir ${TMUX_TEST_DIR}/${name})
    add_test(NAME ${name} COMMAND ${TMUX_TEST_BASH} regress/win32-run.sh ${script}
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
    get_property(tests GLOBAL PROPERTY TMUX_TEST_STAGE)
    list(LENGTH tests number)
    file(TO_NATIVE_PATH ${TMUX_TEST_TEMP}/${number} temp)
    # Git Bash's mktemp reads TMPDIR before TEMP.
    set(environment TEST_TMUX=${dir}/tmux.exe TEST_BUILD=${dir} TEMP=${temp} TMP=${temp}
        TEST_POWERSHELL=${dir}/shell/powershell.exe
        TMPDIR=${TMUX_TEST_TEMP}/${number})
    set(fixtures staged)
    if(kind STREQUAL "keys")
        list(APPEND environment TEST_LEGACY_TMUX=${dir}/legacy-keys/tmux.exe
            TEST_DEFAULTS_TMUX=${dir}/other-defaults/tmux.exe
            TEST_FOOTER_TMUX=${dir}/footer-panel/tmux.exe)
        list(APPEND fixtures keys-staged)
    endif()
    # TIMEOUT is win32-run.sh's: it stops the test then and ends what the test
    # left running. CTest's own limit comes a minute later so that cleanup runs;
    # at the same limit CTest stopped win32-run.sh first, and what the test left
    # held the job open (TMUX-250).
    if(T_TIMEOUT)
        list(APPEND environment TEST_TIMEOUT=${T_TIMEOUT})
    endif()
    set_tests_properties(${name} PROPERTIES ENVIRONMENT "${environment}"
        FIXTURES_REQUIRED "${fixtures}")
    if(T_TIMEOUT)
        math(EXPR limit "${T_TIMEOUT} + 60")
        set_tests_properties(${name} PROPERTIES TIMEOUT ${limit})
    endif()
    if(T_LOCK)
        set_tests_properties(${name} PROPERTIES RESOURCE_LOCK ${T_LOCK})
    endif()
    set_property(GLOBAL APPEND PROPERTY TMUX_TEST_STAGE "${name}=${kind}=${number}")
endfunction()

# The build's tmux.exe, with no ConPTY beside it: Windows' own console. A global
# key is registered for the whole desktop, so the tests that bind one take turns.
foreach(script win32-key-trace win32-basic win32-at-defaults win32-claude-swarm
        win32-format-strings win32-conf-syntax)
    tmux_test(${script} ${script}.sh build)
endforeach()
foreach(script conf-crlf win32-pty-close win32-keys win32-csi-u win32-late-terminal
        win32-detach-exec)
    tmux_test(${script} ${script}.sh build TIMEOUT 300)
endforeach()
foreach(script win32-has-session win32-file win32-strftime win32-char-width
        win32-tty-pending win32-clock win32-respawn-failed win32-respawn-hold)
    tmux_test(${script} ${script}.sh build)
endforeach()
foreach(script win32-message-log win32-run-shell-background)
    tmux_test(${script} ${script}.sh build TIMEOUT 300)
endforeach()
foreach(script win32-layout win32-attach-size win32-cell-size win32-wrap)
    tmux_test(${script} ${script}.sh build)
endforeach()
tmux_test(win32-control-client win32-control-client.sh build LOCK global-keys)
foreach(script win32-hidden-text win32-client-name)
    tmux_test(${script} ${script}.sh build TIMEOUT 180)
endforeach()
foreach(script win32-pane-clear win32-popup-output)
    tmux_test(${script} ${script}.sh build TIMEOUT 300)
endforeach()
foreach(script win32-linesize win32-palette)
    tmux_test(${script} ${script}.sh build)
endforeach()
foreach(script win32-process-watch win32-environment win32-child-path
        win32-pipe-pane-close)
    tmux_test(${script} ${script}.sh build TIMEOUT 300)
endforeach()
foreach(script win32-keep-alive win32-set-status win32-single-window win32-copy-name
        win32-caller win32-reorder-session win32-session-set win32-hidden-session)
    tmux_test(${script} ${script}.sh build)
endforeach()
foreach(script win32-restore-programs win32-session-offer win32-restore-set
        win32-new-window-draw win32-new-window-options
        win32-option-rename win32-system-app)
    tmux_test(${script} ${script}.sh build TIMEOUT 300)
endforeach()
# A crash read with the PDB beside the exe.
tmux_test(win32-session-ended win32-session-ended.sh pdb TIMEOUT 300)
tmux_test(win32-global-foreground win32-global-foreground.sh build TIMEOUT 300 LOCK global-keys)
# An at server, so it binds the desktop's keys until its config unbinds them.
tmux_test(win32-session-hold win32-session-hold.sh build TIMEOUT 300 LOCK global-keys)
# Runs alt-tab-test.exe from beside tmux.exe.
tmux_test(win32-start-program win32-start-program.sh alt-tab TIMEOUT 300 LOCK global-keys)

# Beside conpty.dll and OpenConsole.exe, as a release runs: a console changes
# hands only through conpty.dll.
foreach(script win32-pty-close win32-pane-clear win32-popup-output win32-sixel
        win32-sixel-cap win32-placed-images win32-option-redraw win32-upgrade
        win32-move-pane win32-close
        win32-flight win32-whole-sequences)
    tmux_test(conpty-${script} ${script}.sh conpty)
endforeach()

# Upgrades between this build and builds with other key numbers and defaults,
# built from the pre-footer commit, the last footer and side panel commit and
# from this one changed
# (build-upgrade-key-fixtures.ps1). It compiles four files at a time, so it takes
# all four of CTest's slots while it runs.
foreach(script win32-upgrade-keys win32-upgrade-defaults)
    tmux_test(conpty-${script} ${script}.sh keys TIMEOUT 300)
endforeach()
add_test(NAME build-key-fixtures COMMAND ${TMUX_TEST_PWSH} -NoLogo -NoProfile -NonInteractive
    -File regress/build-upgrade-key-fixtures.ps1 -CMake ${CMAKE_COMMAND}
    -Build ${CMAKE_CURRENT_BINARY_DIR} -Conpty ${TMUX_TEST_CONPTY}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
set_tests_properties(build-key-fixtures PROPERTIES FIXTURES_SETUP keys PROCESSORS 4)

# The package of a home PC: its PDB beside tmux.exe and none at the build path.
tmux_test(package-win32-crash-log win32-crash-log.sh package TIMEOUT 300)

get_property(TMUX_TEST_STAGE GLOBAL PROPERTY TMUX_TEST_STAGE)
set(TMUX_TEST_STAGE_FILE ${CMAKE_CURRENT_BINARY_DIR}/test-stage-$<CONFIG>.cmake)
file(GENERATE OUTPUT ${TMUX_TEST_STAGE_FILE} CONTENT "set(TESTS \"${TMUX_TEST_STAGE}\")
set(EXE \"$<TARGET_FILE:tmux>\")
set(WER \"$<TARGET_FILE:tmux-wer>\")
set(ALTTAB \"$<TARGET_FILE:alt-tab-test>\")
set(POWERSHELL \"$<TARGET_FILE:test-powershell>\")
set(PDB \"$<TARGET_PDB_FILE:tmux>\")
set(CONPTY \"${TMUX_TEST_CONPTY}\")
set(DIR \"${TMUX_TEST_DIR}\")
set(TEMP \"${TMUX_TEST_TEMP}\")
set(FIXTURES \"${CMAKE_CURRENT_BINARY_DIR}\")
")
foreach(mode stage keys restore)
    add_test(NAME ${mode}-tests COMMAND ${CMAKE_COMMAND} -DMODE=${mode}
        -DSTAGE=${TMUX_TEST_STAGE_FILE} -P ${CMAKE_CURRENT_SOURCE_DIR}/regress/win32-stage.cmake)
endforeach()
set_tests_properties(stage-tests PROPERTIES FIXTURES_SETUP staged)
set_tests_properties(keys-tests PROPERTIES FIXTURES_SETUP keys-staged
    FIXTURES_REQUIRED "keys;staged")
set_tests_properties(restore-tests PROPERTIES FIXTURES_CLEANUP staged)

# Print summary
message(STATUS "")
message(STATUS "tmux Windows build configuration:")
message(STATUS "  Version:    3.6a-win32")
message(STATUS "")
