cmake_minimum_required(VERSION 3.25)
project(LDTX LANGUAGES CXX)

option(LDTX_AUDIO_ENGINE_TSAN "Enable Thread Sanitizer" ON)

enable_testing()
add_subdirectory(Tests/LDTXAudioEngineDetailedTests)
