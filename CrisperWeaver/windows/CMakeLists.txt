# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(jarvisol LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "jarvisol")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Suppress MSVC 14.51+ deprecation of <experimental/coroutine> used by
# permission_handler_windows 0.2.1. The plugin hasn't migrated to C++20
# <coroutine> yet; this define silences the static_assert until it does.
add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# ── LiteRT runtime bundle ─────────────────────────────────────────────────────
# Bundle the Python 3.11 runtime + litert-lm dependencies into
#   Release\runtime\litert_lm\
# so the Release is fully portable (no dependency on Hermes/pipx/uv).
#
# Uses CMAKE_INSTALL_CONFIG_NAME (set by cmake --install --config <X>)
# which works correctly with multi-config generators (Visual Studio).
# CMAKE_BUILD_TYPE is NOT used here because it is undefined under VS.
#
# If bundling fails the install is aborted with FATAL_ERROR so the Release
# is never silently incomplete.
# ─────────────────────────────────────────────────────────────────────────────
get_filename_component(_litert_bundle_script
  "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/bundle_litert_runtime.ps1"
  ABSOLUTE)

install(CODE "
  if(\"\${CMAKE_INSTALL_CONFIG_NAME}\" STREQUAL \"Release\"
     OR \"\${CMAKE_INSTALL_CONFIG_NAME}\" STREQUAL \"Profile\")

    set(_target_dir \"${CMAKE_INSTALL_PREFIX}/runtime/litert_lm\")
    message(STATUS \"[LiteRT] Bundling runtime → \${_target_dir}\")

    execute_process(
      COMMAND powershell -NonInteractive -ExecutionPolicy Bypass
        -File \"${_litert_bundle_script}\"
        -TargetDir \"\${_target_dir}\"
      RESULT_VARIABLE _litert_rc
      OUTPUT_VARIABLE _litert_out
      ERROR_VARIABLE  _litert_err
    )

    message(STATUS \"\${_litert_out}\")
    if(NOT _litert_rc EQUAL 0)
      message(FATAL_ERROR
        \"[LiteRT] Runtime bundle FAILED (exit code=\${_litert_rc}).\\n\"
        \"\${_litert_err}\\n\"
        \"The Release build is NOT portable without the LiteRT runtime.\\n\"
        \"Fix the bundle script or the source venv and rebuild.\")
    endif()
    message(STATUS \"[LiteRT] Runtime bundle OK.\")
  else()
    message(STATUS \"[LiteRT] Skipping runtime bundle for \${CMAKE_INSTALL_CONFIG_NAME} build.\")
  endif()
" COMPONENT Runtime)

# ─────────────────────────────────────────────────────────────────────────────
# Voice Bake bundle — python_bake\ + tools\voice_bake\ + chatterbox_weights\
#
# JARVISOL_VOICE_BAKE=ON  (default) : Voice Bake annoncé dans le Release.
#   Le bundle python_bake\ + poids est OBLIGATOIRE.
#   Toute absence (script, Python, poids, manifest) = FATAL_ERROR.
#   Le Release n'est jamais produit avec un Voice Bake partiellement cassé.
#
# JARVISOL_VOICE_BAKE=OFF : Voice Bake délibérément absent.
#   VoiceBakingService.isSupported retourne false (manifest absent).
#   L'UI Voice Bake est désactivée. Aucun FATAL_ERROR.
#
# Note : Le build Debug ne bundle pas — VoiceBakingService.isSupported
#        retourne toujours true en Debug (kDebugMode=true).
# ─────────────────────────────────────────────────────────────────────────────
option(JARVISOL_VOICE_BAKE "Bundle Voice Bake Python runtime + Chatterbox weights" OFF)

get_filename_component(_voice_bake_script
  "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/bundle_voice_bake.ps1"
  ABSOLUTE)

install(CODE "
  if(\"\${CMAKE_INSTALL_CONFIG_NAME}\" STREQUAL \"Release\"
     OR \"\${CMAKE_INSTALL_CONFIG_NAME}\" STREQUAL \"Profile\")

    if(\"${JARVISOL_VOICE_BAKE}\")
      # Voice Bake annoncé : bundle OBLIGATOIRE — FATAL_ERROR si incomplet.
      if(NOT EXISTS \"${_voice_bake_script}\")
        message(FATAL_ERROR
          \"[VoiceBake] bundle_voice_bake.ps1 introuvable : ${_voice_bake_script}\\n\"
          \"Build configurée JARVISOL_VOICE_BAKE=ON mais le script de bundle est absent.\\n\"
          \"Créez-le ou repassez -DJARVISOL_VOICE_BAKE=OFF pour un Release sans Voice Bake.\")
      endif()

      message(STATUS \"[VoiceBake] Bundling python_bake\\ + weights → \${CMAKE_INSTALL_PREFIX}\")

      execute_process(
        COMMAND powershell -NonInteractive -ExecutionPolicy Bypass
          -File \"${_voice_bake_script}\"
          -TargetDir \"\${CMAKE_INSTALL_PREFIX}\"
        RESULT_VARIABLE _vb_rc
        OUTPUT_VARIABLE _vb_out
        ERROR_VARIABLE  _vb_err
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_STRIP_TRAILING_WHITESPACE
      )
      message(STATUS \"\${_vb_out}\")
      if(NOT _vb_rc EQUAL 0)
        message(FATAL_ERROR
          \"[VoiceBake] Bundle FAILED (exit code=\${_vb_rc}).\\n\"
          \"\${_vb_err}\\n\"
          \"Le Release n'est PAS portable pour Voice Bake.\\n\"
          \"Corrigez bundle_voice_bake.ps1 ou passez -DJARVISOL_VOICE_BAKE=OFF.\")
      endif()

      # Le manifest est la preuve que le bundle s'est terminé correctement
      # et que tous les composants critiques sont validés.
      if(NOT EXISTS \"\${CMAKE_INSTALL_PREFIX}/python_bake/voice_bake_manifest.json\")
        message(FATAL_ERROR
          \"[VoiceBake] Bundle terminé sans manifest — intégrité non prouvée.\\n\"
          \"voice_bake_manifest.json manquant sous python_bake/.\")
      endif()

      message(STATUS \"[VoiceBake] Bundle OK — manifest présent.\")
    else()
      # JARVISOL_VOICE_BAKE=OFF : désactivation volontaire, pas d'erreur.
      # L'absence du manifest fait que VoiceBakingService.isSupported=false
      # en Release, ce qui désactive l'UI Voice Bake.
      message(STATUS \"[VoiceBake] Skipped — JARVISOL_VOICE_BAKE=OFF (Voice Bake désactivé).\")
    endif()
  else()
    message(STATUS \"[VoiceBake] Skipping bundle for \${CMAKE_INSTALL_CONFIG_NAME} build.\")
  endif()
" COMPONENT Runtime)
