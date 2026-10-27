#!/bin/bash
# Buduje aplikację i tworzy plik .deb w folderze packages/
# Użycie:  ./build.sh            (sam wybiera SDK)
#          SDKVER=9.3 ./build.sh (wymusza wersję SDK)
set -e
cd "$(dirname "$0")"

export THEOS="${THEOS:-$HOME/theos}"
if [ ! -d "$THEOS/makefiles" ]; then
  echo "Nie widzę Theosa w $THEOS. Najpierw go zainstaluj (patrz README.md, krok 2)."
  exit 1
fi

# SDK, które umie 32-bitowy armv7 (iOS 10.3 i starsze). Bierzemy NAJSTARSZE dostępne,
# bo jest najbliższe iOS 6.
if [ -z "$SDKVER" ]; then
  for v in 6.1 6.0 7.0 7.1 8.0 8.1 8.2 8.3 8.4 9.0 9.1 9.2 9.3 10.0 10.1 10.2 10.3; do
    if [ -d "$THEOS/sdks/iPhoneOS$v.sdk" ]; then SDKVER="$v"; break; fi
  done
fi
if [ -z "$SDKVER" ]; then
  echo "Nie znalazłem SDK iOS 10.3 ani starszego w $THEOS/sdks. Są tam:"
  ls "$THEOS/sdks" || true
  echo "Skopiuj tam folder iPhoneOS6.1.sdk (patrz README.md) i uruchom skrypt jeszcze raz."
  exit 1
fi
echo "==> Używam SDK iOS $SDKVER"

chmod 755 layout/DEBIAN/postinst 2>/dev/null || true

# Usuwamy stare paczki i pliki z poprzednich budowań, żeby nie trafiły do nowego pakietu.
rm -rf packages .theos

echo "==> Repozytorium: ${GITHUB_REPOSITORY:-lokalnie}, wersja kodu: ${GITHUB_SHA:-brak}"
echo "==> Plik control, który zobaczył budowanie:"
grep -E '^(Package|Version|Author|Maintainer):' control || true

MAKE=make
command -v gmake >/dev/null 2>&1 && MAKE=gmake

$MAKE clean >/dev/null 2>&1 || true
$MAKE package SDKVER="$SDKVER" FINALPACKAGE=1

echo
echo "==> Gotowe. Plik do zainstalowania na telefonie:"
ls -1 packages/*.deb
