cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "activity_sensor.cc"
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Rust owns the privacy classification and event semantics shared by all three
# desktop runners. The Linux runner only observes a minimal X11 sample; Rust
# decides whether that sample may cross into Flutter.
find_program(CARGO_EXECUTABLE cargo REQUIRED)
set(AMADEUS_RUST_MANIFEST "${CMAKE_SOURCE_DIR}/../rust/Cargo.toml")
set(AMADEUS_RUST_LIBRARY
    "${CMAKE_SOURCE_DIR}/../rust/target/release/libamadeus_core.a")
add_custom_command(
  OUTPUT "${AMADEUS_RUST_LIBRARY}"
  COMMAND "${CARGO_EXECUTABLE}" build
          --manifest-path "${AMADEUS_RUST_MANIFEST}" --release
  WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/.."
  DEPENDS
    "${CMAKE_SOURCE_DIR}/../rust/src/lib.rs"
    "${AMADEUS_RUST_MANIFEST}"
  COMMENT "Building Amadeus Rust activity core"
  VERBATIM
)
add_custom_target(amadeus_core_build DEPENDS "${AMADEUS_RUST_LIBRARY}")
add_dependencies(${BINARY_NAME} amadeus_core_build)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::X11 PkgConfig::XSS)
target_link_libraries(${BINARY_NAME} PRIVATE "${AMADEUS_RUST_LIBRARY}")
target_link_libraries(${BINARY_NAME} PRIVATE dl pthread rt m util)

target_include_directories(${BINARY_NAME} PRIVATE
  "${CMAKE_SOURCE_DIR}"
  "${CMAKE_SOURCE_DIR}/../rust/include")
