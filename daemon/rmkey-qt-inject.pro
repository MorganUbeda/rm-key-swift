QT       -= gui

TARGET = rmkey_qt_inject
TEMPLATE = lib
CONFIG += c++11

SOURCES += rmkey-qt-inject.cpp

# Only need core module (QCoreApplication, QGuiApplication, QKeyEvent, etc.
# are available via the core module in Qt6)
QT -= gui

# Output as a shared library (for LD_PRELOAD)
CONFIG += shared
