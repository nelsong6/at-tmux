# logline, the home estate's one log line (AHT-204): REF is the one place its version is
# chosen; dep/fetch.sh fetches the same commit for the Mac and Linux builds.
set(REF f70b79296762016b3400e3069dd96ea64770d4a0)
vcpkg_from_git(
    OUT_SOURCE_PATH SOURCE_PATH
    URL https://forgejo.romaine.life/romaine-life/logline.git
    REF ${REF}
)
vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}/c"
    OPTIONS
        -DLOGLINE_TESTS=OFF
)
vcpkg_cmake_install()
vcpkg_cmake_config_fixup(PACKAGE_NAME logline CONFIG_PATH lib/cmake/logline)
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
file(WRITE "${CURRENT_PACKAGES_DIR}/share/${PORT}/copyright" "romaine-life/logline")
