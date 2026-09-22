# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.25)
project(LDTXAudioEngineDetailedTests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
enable_testing()

add_executable(ldtx-audio-engine-detailed-tests
  ../../Sources/LDTXAudioEngine/AudioMixEngine.cpp
  ../../Sources/LDTXAudioEngine/WorkspaceAudioEngine.cpp
  AudioEngineTests.cpp
)
target_include_directories(ldtx-audio-engine-detailed-tests PRIVATE
  ../../Sources/LDTXAudioEngine/include
  ../../Sources/LDTXAudioEngine
)
target_link_libraries(ldtx-audio-engine-detailed-tests PRIVATE
  "-framework AudioToolbox"
  "-framework CoreAudio"
  "-framework CoreFoundation"
  "-framework CoreMedia"
)
add_test(NAME ldtx-audio-engine-detailed-tests COMMAND ldtx-audio-engine-detailed-tests)

option(LDTX_AUDIO_ENGINE_TSAN "Enable Thread Sanitizer" OFF)
if(LDTX_AUDIO_ENGINE_TSAN)
  target_compile_options(ldtx-audio-engine-detailed-tests PRIVATE -fsanitize=thread)
  target_link_options(ldtx-audio-engine-detailed-tests PRIVATE -fsanitize=thread)
endif()
