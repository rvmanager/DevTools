cmake_minimum_required(VERSION 3.16)
project(fgit)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Find required packages
find_package(PkgConfig REQUIRED)
find_package(CURL REQUIRED)

# Find nlohmann/json
find_package(nlohmann_json REQUIRED)

# Create executable
add_executable(fgit fgit.cpp)

# Link libraries
target_link_libraries(fgit 
    PRIVATE 
    CURL::libcurl
    nlohmann_json::nlohmann_json
)

# Set compiler flags
target_compile_options(fgit PRIVATE 
    -Wall 
    -Wextra 
    -std=c++17
)
