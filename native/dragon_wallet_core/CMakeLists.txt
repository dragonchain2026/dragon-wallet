cmake_minimum_required(VERSION 3.16)
project(dragon_wallet_core C CXX)
add_library(dragon_wallet_core STATIC src/dragon_wallet_core.c)
target_include_directories(dragon_wallet_core PUBLIC include)
set_target_properties(dragon_wallet_core PROPERTIES C_STANDARD 11)

set(FALCON vendor/dragonchain)
add_library(dragon_keys STATIC src/keys.cpp src/system_random.cpp
    ${FALCON}/codec.cpp ${FALCON}/common.cpp ${FALCON}/fft.cpp
    ${FALCON}/fpr.cpp ${FALCON}/keygen.cpp ${FALCON}/rng.cpp
    ${FALCON}/sign.cpp ${FALCON}/vrfy.cpp ${FALCON}/fips202.cpp
    ${FALCON}/pqclean.cpp ${FALCON}/crypto/ripemd160.cpp)
target_include_directories(dragon_keys PUBLIC include PRIVATE ${FALCON})
set_target_properties(dragon_keys PROPERTIES CXX_STANDARD 17 POSITION_INDEPENDENT_CODE ON)
target_compile_options(dragon_keys PRIVATE -fno-fast-math -ffp-contract=off -fstack-protector-strong)
if(ANDROID)
    add_library(dragon_keys_jni SHARED src/keys_jni.cpp)
    target_link_libraries(dragon_keys_jni PRIVATE dragon_keys)
endif()
option(DRAGON_BUILD_KEY_TESTS "Build key compatibility tests" OFF)
if(DRAGON_BUILD_KEY_TESTS)
    enable_testing()
    add_executable(dragon_key_tests tests/keys_test.cpp)
    target_link_libraries(dragon_key_tests PRIVATE dragon_keys)
    add_test(NAME dragon_keys COMMAND dragon_key_tests)
endif()
