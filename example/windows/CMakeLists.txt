# The part of a Flutter windows/CMakeLists.txt that flutter_build_tools reads:
# the executable name becomes windows.exe (example_app.exe). A real project has
# the whole file, written by `flutter create`.
cmake_minimum_required(VERSION 3.14)
project(example_app LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "example_app")
