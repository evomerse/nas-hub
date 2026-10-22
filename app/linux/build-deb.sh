#!/usr/bin/env bash
# Compile l'app pour Linux dans un conteneur Ubuntu 22.04 (compatible Zorin OS 17+, Ubuntu 22.04+)
# et produit un paquet .deb. Usage : ./build-deb.sh [chemin du SDK Flutter] [dossier de sortie]
set -euo pipefail
cd "$(dirname "$0")/.."
FLUTTER_DIR="${1:-$HOME/development/flutter}"
OUT_DIR="$(realpath -m "${2:-build/deb}")"
mkdir -p "$OUT_DIR"
VERSION="$(grep -m1 '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')"

docker run --rm \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e VERSION="$VERSION" \
  -v "$PWD":/src:ro -v "$FLUTTER_DIR":/flutter-ro:ro -v "$OUT_DIR":/out \
  ubuntu:22.04 bash -euxc '
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils zip clang cmake ninja-build \
  pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev liblzma-dev libstdc++-12-dev dpkg-dev
cp -a /flutter-ro /flutter
git config --global --add safe.directory "*"
export PATH=/flutter/bin:$PATH
mkdir /build && cd /src && tar --exclude=./build --exclude=./.dart_tool --exclude=./android -cf - . | tar -xf - -C /build
cd /build
flutter config --no-analytics --enable-linux-desktop
flutter pub get
flutter build linux --release

PKG=/pkg/nas-hub
mkdir -p $PKG/DEBIAN $PKG/opt/nas-hub $PKG/usr/bin $PKG/usr/share/applications $PKG/usr/share/icons/hicolor/scalable/apps
cp -a build/linux/x64/release/bundle/. $PKG/opt/nas-hub/
ln -s /opt/nas-hub/nas_hub $PKG/usr/bin/nas-hub
cp linux/packaging/nas-hub.desktop $PKG/usr/share/applications/
cp linux/packaging/nas-hub.svg $PKG/usr/share/icons/hicolor/scalable/apps/
SIZE=$(du -sk $PKG | cut -f1)
cat > $PKG/DEBIAN/control <<CTL
Package: nas-hub
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Depends: libgtk-3-0, libsecret-1-0, libegl1, libgles2, libjsoncpp25 | libjsoncpp1, libstdc++6, libc6 (>= 2.35)
Installed-Size: $SIZE
Maintainer: NAS Hub <nas-hub@localhost>
Description: Tableau de bord NAS (CasaOS)
 CPU, RAM, disques, réseau, sessions Jellyfin en direct et appareils connectés.
CTL
dpkg-deb --build --root-owner-group $PKG /out/nas-hub_${VERSION}_amd64.deb
chown $HOST_UID:$HOST_GID /out/*.deb
'
echo "Paquet : $OUT_DIR/nas-hub_${VERSION}_amd64.deb"
