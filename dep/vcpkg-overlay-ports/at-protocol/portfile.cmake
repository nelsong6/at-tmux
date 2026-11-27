# at-protocol, the language at-tmux and at-terminal speak (ATT-7): REF is the one
# place its version is chosen, and the build says it in its hello.
set(REF 8de81ed169f1434044313ff6c472b535da3be31a)
vcpkg_from_git(
    OUT_SOURCE_PATH SOURCE_PATH
    URL https://forgejo.romaine.life/romaine-life/at-protocol.git
    REF ${REF}
)
vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DAT_PROTOCOL_VERSION=${REF}
        -DAT_PROTOCOL_TESTS=OFF
)
vcpkg_cmake_install()
vcpkg_cmake_config_fixup(PACKAGE_NAME at-protocol CONFIG_PATH lib/cmake/at-protocol)
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
file(WRITE "${CURRENT_PACKAGES_DIR}/share/${PORT}/copyright" "romaine-life/at-protocol, private")
