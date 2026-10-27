# AeroChat 0.6.1 (klient Telegrama, załączniki, rozmowy głosowe)

Klient komunikatora w stylu iOS 6 dla jailbreakowanego iPhone'a (armv7). Łączy się z Telegramem
własnym, napisanym od zera klientem MTProto 2.0 (oficjalnie dozwolone klienty firm trzecich).

## Co nowego w 0.6.0
- **Rozmowy głosowe przez Telegram** (1:1, tylko dźwięk, bez żadnego dodatkowego serwera): w czacie z użytkownikiem
  jest przycisk „☎". Rozmowa idzie przez serwery przekaźnikowe Telegrama, zaszyfrowana kluczem uzgodnionym
  tylko między rozmówcami (wymiana Diffiego-Hellmana jak w oficjalnych aplikacjach).
- Ekran rozmowy: odbierz / odrzuć, wycisz mikrofon, głośnik, zakończ, licznik czasu. Wyciszenie widzi też rozmówca.
- Połączenia przychodzące dzwonią (dźwięk + wibracja), gdy aplikacja jest uruchomiona i połączona z Telegramem
  (także w tle, jeśli trwa rozmowa — aplikacja ma tryb pracy w tle „audio"). Telefon nie dostaje powiadomień
  push, więc zamknięta aplikacja nie zadzwoni.
- Wiadomości o rozmowach („Rozmowa głosowa, 3:12", „Nieodebrana rozmowa") pojawiają się w czacie.
- Pod spodem: własny silnik rozmów w C (protokół libtgvoip 2.4.4, pakiety UDP, szyfrowanie MTProto 2.0,
  bufor opóźnień), kodek Opus (stałoprzecinkowy, 16 kHz) i dźwięk przez AudioUnit z usuwaniem echa.
- Ograniczenia: bez wideo (przychodzące wideorozmowy są odrzucane), bez weryfikacji emotikonami, bez rozmów
  grupowych. Rozmowa zadziała tylko, jeśli aplikacja rozmówcy nadal obsługuje starszą bibliotekę rozmów 2.4.4
  (oficjalne aplikacje ją deklarują, ale nie dało się tego sprawdzić na prawdziwym serwerze).

## Co nowego w 0.5.0
- **Otwieranie załączników**: zdjęcia i wideo mają miniatury w dymkach; dotknięcie pobiera plik (z paskiem
  postępu w procentach) i otwiera go w podglądzie iOS (zdjęcia, wideo MP4, audio MP3/M4A, PDF, dokumenty Office).
  Pliki są w `Library/Caches/AeroChat` (iOS może je sam czyścić; "Wyloguj" kasuje je od razu).
- Załączniki leżą na różnych serwerach Telegrama niż konto, więc aplikacja otwiera dodatkowe połączenia do
  tych serwerów (z przeniesieniem autoryzacji) i zapamiętuje ich klucze.
- Pliki powyżej 25 MB: pytanie o potwierdzenie. Formaty, których iOS 6 nie obsługuje (głosówki OGG/Opus, WebM,
  WebP): propozycja "pobierz i otwórz w innej aplikacji". Naklejki są na razie tylko opisem.
- **Nowy ekran powitalny**: zamiast suwaka zwykły przycisk "Zaloguj się numerem telefonu", ikona rysowana kodem,
  link "Nie teraz, zostań w trybie demo".

## Zmiany w 0.4.0
- **Motyw "iOS 6 Len"**: ciemnoszary len z ekranu konfiguracji iOS 6 (tło bierzemy z systemowego koloru UIKit,
  własny wzór jest tylko zapasem), grafitowe wiersze i paski.
- **Nowy ekran setup w stylu asystenta iOS 5/6**: powitanie z ikoną i przyciskiem (od 0.5.0; wcześniej suwak),
  potem grupowane tabele na lnie: numer telefonu, kod, hasło (jeśli konto je ma), na końcu ekran "Gotowe".
- **Logowanie samym numerem telefonu**: klucze `api_id` / `api_hash` są wbudowane w aplikację przy budowaniu,
  więc użytkownik ich nie widzi. Telegram wymaga ich od każdego klienta, więc założ je JEDEN RAZ (poniżej).
  Gdy klucze nie są wbudowane, okno setup pokazuje dodatkową sekcję na ich wpisanie.

### Wbudowanie kluczy (raz, w repozytorium GitHub)
1. my.telegram.org → "API development tools" → utwórz aplikację → skopiuj `api_id` i `api_hash`.
2. Repozytorium → Settings → Secrets and variables → Actions → New repository secret:
   `TG_API_ID` (liczba) i `TG_API_HASH` (32 znaki).
3. Actions → Run workflow. Workflow sam tworzy `ACConfigLocal.h` (jest w `.gitignore`).
Uwaga: klucze trafiają do pliku .deb, więc nie udostępniaj go publicznie, jeśli nie chcesz ich ujawniać.

## Zmiany w 0.3.0
- **Okno setup** (pokazuje się przy pierwszym uruchomieniu, potem w Ustawienia → Telegram):
  1. klucze `api_id` i `api_hash` z my.telegram.org,
  2. numer telefonu (np. `+48 600 123 456`; 9 cyfr bez kierunkowego = Polska),
  3. kod z SMS-a lub z aplikacji Telegram na innym urządzeniu,
  4. hasło dwuskładnikowe, jeśli konto je ma.
- Po zalogowaniu na liście są **prawdziwe czaty**: osoby, grupy, kanały. Historia, wysyłanie tekstu,
  nowe wiadomości na żywo, liczniki nieprzeczytanych, status "online / był(a) …".
- Załączniki w tej wersji pokazywały się tylko jako opis w nawiasie (od 0.5.0 da się je otwierać).
- **Tryb demo** zostaje: bez logowania lista z przykładowymi rozmowami (przycisk "Pomiń").
- Sesja jest zapamiętana w `Documents/aerochat.plist` (klucz autoryzacji). "Wyloguj" ją usuwa.

## Skąd wziąć api_id i api_hash
1. Wejdź na https://my.telegram.org (np. w Safari na telefonie albo na komputerze).
2. Zaloguj się swoim numerem (kod przyjdzie do Telegrama).
3. "API development tools" → utwórz aplikację (nazwa i skrót dowolne, platforma np. "iOS").
4. Przepisz `App api_id` (liczba) i `App api_hash` (32 znaki) do okna setup.

## Jak to działa (skrót)
- `tg_mt.c` – transport TCP "intermediate", wymiana kluczy (RSA + Diffie-Hellman), szyfrowana sesja
  MTProto 2.0 (AES-IGE, SHA-256), potwierdzenia, ponawianie przy złej soli i czasie, hasło 2FA (SRP).
- `tg_tl.c` – silnik TL sterowany schematem `Resources/api.tl` (layer 222): zamienia JSON na bajty
  zapytań i odpowiedzi na JSON, więc w aplikacji nie ma ręcznie wpisanych identyfikatorów.
- `ac_voip.c` – silnik rozmów: pakiety libtgvoip (nagłówek v9), szyfrowanie KDF2/AES-IGE, INIT/INIT_ACK, ping,
  wyciszanie, bufor opóźnień i kodowanie Opus. `ac_dh.c` – wymiana kluczy DH rozmów. `ACAudio.m` – mikrofon i
  głośnik (AudioUnit), `ACCall.m` – sygnalizacja phone.* i stan rozmowy, `ACCallController.m` – ekran rozmowy.
- `opus/` – kodek Opus 1.3.1 (licencja BSD w `opus/COPYING`), zbudowany w wersji stałoprzecinkowej.
- `tg_crypto.c`, `tg_bn.c` – SHA-1/256/512, PBKDF2, AES-256, liczby 2048-bitowe, rozpakowywanie gzip.
  Wszystko własne (bez OpenSSL), bez dzielenia 64-bitowego i bibliotek, których nie ma w iOS 6.
- `ACTelegram.m` – logowanie, czaty, historia, wysyłanie, aktualizacje; `ACSetupController.m` – okno setup.

## Budowanie
1. Wrzuć zawartość na GitHub do repo (np. `slam0/AeroChat`).
2. Actions → "Zbuduj AeroChat" → **Run workflow** (nie "Re-run all jobs").
3. Gotowy `.deb` jest w artefaktach. Zainstaluj przez Cydia/Filza.

## Czego jeszcze nie ma
- Zdjęcia, pliki, głosówki, naklejki (tylko tekst), odpowiedzi, edycja i usuwanie własnych wiadomości.
- Dłuższa historia (ładuje się 50 ostatnich wiadomości z rozmowy), powiadomienia w tle.
- Czaty tajne, rozmowy wideo i grupowe.

## Testy
Silnik kryptograficzny, silnik TL (6867 losowych obiektów porównanych z biblioteką Telethon), klient MTProto
(wymiana kluczy, sesja, gzip, kontenery, zła sól i czas) oraz hasło SRP zostały sprawdzone na komputerze
względem implementacji referencyjnych i lokalnego serwera-atrapy. Silnik rozmów rozmawia na komputerze z
oryginalną biblioteką libtgvoip (obie role, 10–15% gubionych pakietów, wyciszanie; dźwięk docierał w obie strony),
a wymiana kluczy DH została porównana z Pythonem. **Prawdziwy serwer Telegrama ani iPhone
nie były używane**, więc aplikacja nie była testowana na urządzeniu.
