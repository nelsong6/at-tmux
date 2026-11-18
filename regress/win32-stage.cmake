# CTest's setup and cleanup for the tests (CMakeLists.txt):
#   cmake -DMODE=<mode> -DSTAGE=<test-stage-<config>.cmake> -P win32-stage.cmake
# STAGE sets TESTS (name=kind=number for each test), EXE, WER, ALTTAB, POWERSHELL,
# PDB, CONPTY, DIR, TEMP and FIXTURES.
#
# stage:   gives each test but the key upgrade ones DIR/<name>, made afresh: its
#          own tmux.exe and what its kind puts beside it, shell/powershell.exe
#          (POWERSHELL, its panes' PowerShell, TEST_POWERSHELL), and an empty
#          TEMP/<number> for its TEMP. build: tmux-wer.dll. alt-tab: tmux-wer.dll
#          and alt-tab-test.exe. pdb: tmux-wer.dll and tmux.pdb. conpty:
#          conpty.dll and OpenConsole.exe. package: all of them, the build's own
#          tmux.pdb moved there, so none is at the path stored in the exe, as on a
#          home PC.
# keys:    the same for the key upgrade tests (conpty, and in legacy-keys/,
#          shifted-keys/ and other-defaults/ the fixtures FIXTURES holds).
# restore: moves the package's tmux.pdb back to PDB, for the build and its
#          install, and removes TEMP.
cmake_minimum_required(VERSION 3.16)
include(${STAGE})

set(package "")
foreach(test IN LISTS TESTS)
    string(REPLACE "=" ";" test "${test}")
    list(GET test 1 kind)
    if(kind STREQUAL "package")
        list(GET test 0 package)
        set(package "${DIR}/${package}")
    endif()
endforeach()

# A run stopped before its cleanup left the PDB in the package. (keys runs after
# stage has moved it, so leaves it there.)
if(NOT MODE STREQUAL "keys" AND package AND NOT EXISTS "${PDB}" AND EXISTS "${package}/tmux.pdb")
    file(RENAME "${package}/tmux.pdb" "${PDB}")
endif()
if(MODE STREQUAL "restore")
    file(REMOVE_RECURSE "${TEMP}")
    return()
endif()

foreach(test IN LISTS TESTS)
    string(REPLACE "=" ";" test "${test}")
    list(GET test 0 name)
    list(GET test 1 kind)
    list(GET test 2 number)
    set(keys OFF)
    if(kind STREQUAL "keys")
        set(keys ON)
    endif()
    if((MODE STREQUAL "keys" AND keys) OR (MODE STREQUAL "stage" AND NOT keys))
        set(dir "${DIR}/${name}")
        file(REMOVE_RECURSE "${dir}" "${TEMP}/${number}")
        file(MAKE_DIRECTORY "${dir}" "${TEMP}/${number}")
        set(files "${EXE}")
        if(kind STREQUAL "build" OR kind STREQUAL "alt-tab" OR kind STREQUAL "pdb" OR kind STREQUAL "package")
            list(APPEND files "${WER}")
        endif()
        if(kind STREQUAL "alt-tab")
            list(APPEND files "${ALTTAB}")
        endif()
        if(kind STREQUAL "pdb")
            list(APPEND files "${PDB}")
        endif()
        if(kind STREQUAL "conpty" OR kind STREQUAL "keys" OR kind STREQUAL "package")
            list(APPEND files "${CONPTY}/conpty.dll" "${CONPTY}/OpenConsole.exe")
        endif()
        file(COPY ${files} DESTINATION "${dir}")
        file(COPY "${POWERSHELL}" DESTINATION "${dir}/shell")
        if(kind STREQUAL "keys")
            foreach(fixture legacy-keys shifted-keys other-defaults)
                file(COPY "${FIXTURES}/${fixture}/Debug/tmux.exe"
                    "${CONPTY}/conpty.dll" "${CONPTY}/OpenConsole.exe"
                    DESTINATION "${dir}/${fixture}")
            endforeach()
        endif()
    endif()
endforeach()

# Last, once every test that copies it has.
if(MODE STREQUAL "stage" AND package)
    if(NOT EXISTS "${PDB}")
        message(FATAL_ERROR "no ${PDB} to put in the package")
    endif()
    file(RENAME "${PDB}" "${package}/tmux.pdb")
endif()
