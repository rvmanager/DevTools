cmake_minimum_required(VERSION 3.16)
project(pptt)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Create executable
add_executable(pptt pptt.cpp)

# Set compiler flags
target_compile_options(pptt PRIVATE 
    -Wall 
    -Wextra 
    -std=c++17
)

# Link filesystem library if needed (some older compilers require explicit linking)
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND CMAKE_CXX_COMPILER_VERSION VERSION_LESS 9.0)
    target_link_libraries(pptt stdc++fs)
endif()
