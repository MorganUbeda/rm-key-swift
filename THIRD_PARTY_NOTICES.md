# Third-party notices

`rm-key` is not affiliated with, endorsed by, or supported by reMarkable AS. “reMarkable” is used descriptively to identify the compatible device.

This file summarizes third-party software and platform components relevant to source or binary distribution of this project.

## libssh2

The macOS app currently uses `libssh2` through the SwiftPM system-library target `Clibssh2`.

`libssh2` is distributed under a revised BSD-style license. If you distribute a binary build that includes or links `libssh2`, reproduce the following notice in the app bundle, disk image, release notes, or other materials distributed with the binary.

```text
Copyright (C) 2004-2007 Sara Golemon <sarag@libssh2.org>
Copyright (C) 2005,2006 Mikhail Gusarov <dottedmag@dottedmag.net>
Copyright (C) 2006-2007 The Written Word, Inc.
Copyright (C) 2007 Eli Fant <elifantu@mail.ru>
Copyright (C) 2009-2023 Daniel Stenberg
Copyright (C) 2008, 2009 Simon Josefsson
Copyright (C) 2000 Markus Friedl
Copyright (C) 2015 Microsoft Corp.
All rights reserved.

Redistribution and use in source and binary forms,
with or without modification, are permitted provided
that the following conditions are met:

Redistributions of source code must retain the above
copyright notice, this list of conditions and the
following disclaimer.

Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following
disclaimer in the documentation and/or other materials
provided with the distribution.

Neither the name of the copyright holder nor the names
of any other contributors may be used to endorse or
promote products derived from this software without
specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
OF SUCH DAMAGE.
```

Source: <https://libssh2.org/license.html>

## Qt

The tablet-side injector is C++ code that dynamically links against Qt libraries already present on the user's reMarkable Paper Pro, especially Qt Core and Qt Gui. This repository does **not** distribute reMarkable firmware files or Qt runtime libraries copied from the tablet.

The local `tablet-sysroot/` used during development has contained Qt 6.8.2 shared libraries such as `libQt6Core.so.6`, `libQt6Gui.so.6`, and `libQt6Quick.so.6`. Qt Core, Qt GUI, and Qt Quick are available under commercial licenses from The Qt Company and under free software licenses including LGPLv3/GPL terms. These are **not** permissive licenses like MIT or BSD.

Do not commit or redistribute Qt libraries copied from a tablet unless you are prepared to comply with the applicable Qt license terms for binary redistribution. For LGPL distribution, that generally includes preserving notices, providing the LGPL/GPL license texts, making the corresponding Qt source available for the exact library version and modifications, and allowing users to replace/relink the LGPL libraries.

reMarkable publishes SDK/toolchain downloads for supported devices on its developer portal, and maintains a public `qtbase` mirror with Qt 6 branches, including Qt 6.8.2. This is useful for source/reference purposes, but it does not by itself make tablet-extracted binaries permissively licensed or safe to commit to this repository.

Qt licensing information: <https://doc.qt.io/qt-6/licensing.html>

reMarkable developer SDK information: <https://developer.remarkable.com/documentation/sdk>

reMarkable Qt base mirror: <https://github.com/reMarkable/qtbase>

## reMarkable firmware files

The local `tablet-sysroot/` directory is intentionally ignored. It may contain Qt libraries copied from a user's own tablet for local linking. Do not commit or redistribute files extracted from reMarkable firmware unless you have permission to do so.
