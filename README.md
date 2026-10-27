# AeroChat 0.1.0 (etap 1: sam wygląd)

Klient komunikatora w stylu **Frutiger Aero + skeuomorfizm** dla iOS 6 (armv7, jailbreak).
Docelowo ma łączyć się z Telegramem (oficjalnie dozwolone klienty firm trzecich).

**W tej wersji nie ma jeszcze połączenia z siecią** – widać demo: 10 rozmów po polsku,
kontakty, ekran czatu z dymkami i ustawienia z motywami.

## Motywy (Ustawienia → Motyw)
Frutiger Aero, Aluminium (szczotkowany metal), Aero Zieleń, Mosiądz, Różowe złoto,
Grafit, Błękit, Czerwień, Zieleń, Fiolet. Zmiana działa od razu i jest zapamiętywana.

## Budowanie
1. Wrzuć zawartość na GitHub do repo (np. `slam0/AeroChat`).
2. Actions → "Zbuduj aplikację" → **Run workflow** (nie "Re-run all jobs").
3. Gotowy `.deb` jest w Release `najnowsza` i w artefaktach. Zainstaluj przez Cydia/Filza.

## Plan
1. (to) interfejs i motywy
2. sonda połączenia z serwerem Telegrama (MTProto)
3. logowanie: numer telefonu + kod SMS (potrzebny własny `api_id` z my.telegram.org)
4. prawdziwe czaty i wysyłanie wiadomości

Aplikacja nie była testowana na urządzeniu.
