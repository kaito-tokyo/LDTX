# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
#
# SPDX-License-Identifier: Apache-2.0

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
enable_testing()

add_executable(ldtx-audio-engine-cmake-tests
  ../../Packages/LDTXAudioKit/Sources/LDTXAudioKitCore/Compositor/AudioMixEngine.cpp
  ../../Packages/LDTXAudioKit/Sources/LDTXAudioKitCore/Receiver/WorkspaceAudioEngine.cpp
  AudioEngineTests.cpp
  AudioMixEngineTests.cpp
)
target_include_directories(ldtx-audio-engine-cmake-tests PRIVATE
  ../../Tests
  ../../Packages/LDTXAudioKit/Sources/LDTXAudioKitCore/include
  ../../Packages/LDTXAudioKit/Sources/LDTXAudioKitCore/Receiver
  ../../Packages/LDTXAudioKit/Sources/LDTXAudioKitCore/Compositor/Internal
)
target_link_libraries(ldtx-audio-engine-cmake-tests PRIVATE
  "-framework AudioToolbox"
  "-framework CoreAudio"
  "-framework CoreFoundation"
  "-framework CoreMedia"
)
add_test(NAME ldtx-audio-engine-cmake-tests COMMAND ldtx-audio-engine-cmake-tests)

if(LDTX_AUDIO_ENGINE_TSAN)
  target_compile_options(ldtx-audio-engine-cmake-tests PRIVATE -fsanitize=thread)
  target_link_options(ldtx-audio-engine-cmake-tests PRIVATE -fsanitize=thread)
endif()
