# AeroChat 0.3.0 (klient Telegrama)

Klient komunikatora w stylu iOS 6 dla jailbreakowanego iPhone'a (armv7). Łączy się z Telegramem
własnym, napisanym od zera klientem MTProto 2.0 (oficjalnie dozwolone klienty firm trzecich).

## Co nowego w 0.3.0
- **Okno setup** (pokazuje się przy pierwszym uruchomieniu, potem w Ustawienia → Telegram):
  1. klucze `api_id` i `api_hash` z my.telegram.org,
  2. numer telefonu (np. `+48 600 123 456`; 9 cyfr bez kierunkowego = Polska),
  3. kod z SMS-a lub z aplikacji Telegram na innym urządzeniu,
  4. hasło dwuskładnikowe, jeśli konto je ma.
- Po zalogowaniu na liście są **prawdziwe czaty**: osoby, grupy, kanały. Historia, wysyłanie tekstu,
  nowe wiadomości na żywo, liczniki nieprzeczytanych, status "online / był(a) …".
- Załączniki (zdjęcia, pliki, głosówki) pokazują się na razie jako opis w nawiasie, np. `[Zdjęcie]`.
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
- Czaty tajne i połączenia.

## Testy
Silnik kryptograficzny, silnik TL (6867 losowych obiektów porównanych z biblioteką Telethon), klient MTProto
(wymiana kluczy, sesja, gzip, kontenery, zła sól i czas) oraz hasło SRP zostały sprawdzone na komputerze
względem implementacji referencyjnych i lokalnego serwera-atrapy. **Prawdziwy serwer Telegrama ani iPhone
nie były używane**, więc aplikacja nie była testowana na urządzeniu.
