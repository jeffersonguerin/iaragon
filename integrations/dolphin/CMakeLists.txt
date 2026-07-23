# Dolphin overlay-icon plugin for iaragon.
#
# Build against the KDE Frameworks generation your Dolphin uses:
#   KF5 (e.g. Kubuntu/Ubuntu 24.04):
#     cmake -B build -DQT_MAJOR_VERSION=5 && cmake --build build && sudo cmake --install build
#   KF6:
#     cmake -B build -DQT_MAJOR_VERSION=6 && cmake --build build && sudo cmake --install build
cmake_minimum_required(VERSION 3.16)
project(iaragon-dolphin-overlay CXX)

set(QT_MAJOR_VERSION 5 CACHE STRING "Qt/KF generation to build against (5 or 6)")
set(KF_MAJOR_VERSION ${QT_MAJOR_VERSION})

find_package(ECM REQUIRED NO_MODULE)
list(APPEND CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)

set(CMAKE_AUTOMOC ON)

find_package(Qt${QT_MAJOR_VERSION} REQUIRED COMPONENTS Core Network)
find_package(KF${KF_MAJOR_VERSION} REQUIRED COMPONENTS KIO)

add_library(iaragonoverlay MODULE
    iaragonoverlayplugin.cpp
    iaragonoverlayplugin.h
)
target_link_libraries(iaragonoverlay
    KF${KF_MAJOR_VERSION}::KIOWidgets
    Qt${QT_MAJOR_VERSION}::Network
)

# Dolphin discovers overlay plugins in the kf<major>/overlayicon plugin
# namespace (see dolphin/src/kitemviews/kfileitemmodelrolesupdater.cpp).
install(TARGETS iaragonoverlay
        DESTINATION ${KDE_INSTALL_QTPLUGINDIR}/kf${KF_MAJOR_VERSION}/overlayicon)
