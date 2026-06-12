#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(perl -ne "print \$1 if /^our \\\$VERSION\s*=\s*['\"]([^'\"]+)['\"]/" Koha/Plugin/De/StadtbuechereiTuebingen/LibraryOfThings.pm)
KPZ="koha-plugin-library-of-things-${VERSION}.kpz"

rm -f "$KPZ"
zip -r "$KPZ" Koha -x '*.DS_Store'
echo "Gebaut: $KPZ"
