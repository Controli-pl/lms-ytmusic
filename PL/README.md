# YTMusic — wtyczka YouTube Music dla dodatku Lyrion Music Server (LMS) w Home Assistant OS.

Wtyczka integrująca YouTube Music z Lyrion Music Server (dawniej Logitech/Squeezebox Server). Umożliwia przeglądanie, wyszukiwanie i odtwarzanie muzyki z YouTube Music na wszystkich graczach Squeezebox/LMS, z pełną obsługą ReplayGain i integracją z Home Assistant przez komendy CLI.

## Jak to działa

Wtyczka składa się z dwóch części:

- **Plugin LMS (Perl)** — integruje się z menu, kolejką odtwarzania, ReplayGain i CLI/JSON-RPC LMS.
- **Bridge (Python, `ytmusic_bridge`)** — lokalny serwer HTTP (`127.0.0.1:8008`), który komunikuje się z YouTube Music (przez `ytmusicapi`) i pobiera/remuksuje strumienie audio (przez `yt-dlp` + `ffmpeg`).

Bridge jest uruchamiany i zarządzany automatycznie przez plugin — nie wymaga ręcznego startu. Plugin sprawdza jego gotowość (`/health`) po starcie LMS i zatrzymuje go przy wyłączaniu serwera.

## Funkcje

### Przeglądanie i odtwarzanie
- **Wyszukiwanie** utworów (menu główne + globalne wyszukiwanie LMS).
- **Polecane** — rekomendacje z YouTube Music (sekcje typu "Mixed for you", "My Mix 1-6" itd.), z podglądem zawartości sekcji i możliwością odtworzenia/dodania całej sekcji na raz.
- **Moje playlisty** — playlisty z Twojej biblioteki YouTube Music.
- **Polubione utwory** — biblioteka polubionych utworów.
- **Radio** — na bazie ostatnio odtwarzanego utworu, budowane z menu głównego lub z menu kontekstowego utworu (dokleja radio do kolejki).
- **Menu kontekstowe utworu** — Polub, Szybki zapis (do auto-tworzonej playlisty "Zapisane z LMS"), Dodaj do konkretnej playlisty, Szukaj w YTMusic (dla utworów z innych źródeł, np. biblioteki lokalnej).
- **Integracja z Don't Stop The Music** — dwa tryby: Radio (na bazie ostatniego utworu) i Mix (na bazie kilku ostatnich utworów w kolejce, wyniki miksowane naprzemiennie między seedami).
- **Przewijanie** — pełne wsparcie seek w trakcie odtwarzania.

### ReplayGain
Wtyczka liczy i stosuje ReplayGain automatycznie, bez potrzeby wcześniejszej analizy całej biblioteki:

- **Szybki pomiar** (pierwsze ~25s utworu) — stosowany od razu przy pierwszym odtworzeniu i przy prefetchu utworów w kolejce, żeby nie blokować startu odtwarzania.
- **Głęboka analiza** — po przekroczeniu skonfigurowanego procentu realnie odsłuchanej długości utworu (domyślnie 85%, liczone bez czasu pauzy), wtyczka w tle zamawia dokładniejszy pomiar (połowa utworu albo cały utwór) i zapamiętuje go na przyszłość. Naprawia to przypadki utworów z cichym wstępem i mocnym wejściem w dalszej części, gdzie krótka analiza dawała zawyżony gain. Utwory szybko przeskoczone nie są analizowane ponownie — zero zbędnego obciążenia CPU.
- **Cache trwały** — policzone wartości gainu są trwale zapisywane przez bridge (przetrwają restart LMS), z rosnącą jakością (szybki → połowa → cały utwór), nigdy degradowaną w dół.
- **Prefetch** — gain dla najbliższych utworów w kolejce jest liczony z wyprzedzeniem, w tle, także dla utworów wstawionych przez "Zagraj jako następny".

Ustawienia (Settings → Advanced → YTMusic w interfejsie LMS):

| Ustawienie | Opis |
|---|---|
| Włącz Replay Gain | Główny wyłącznik — wyłączony, gain nie jest liczony ani stosowany dla żadnego utworu |
| Minimalna głośność dla liczenia gainu | Nowy gain jest liczony tylko gdy przynajmniej jeden podłączony gracz ma głośność powyżej tej wartości (0 = liczony zawsze, niezależnie od głośności) |
| Próg odsłuchania dla głębokiej analizy | Po ilu % realnego odsłuchania utworu zamawiana jest dokładniejsza analiza |
| Zakres głębokiej analizy | 25 sekund (brak pogłębiania — wyłącza mechanizm), połowa utworu, albo cały utwór (najdokładniejsze, zalecane) |

## Komendy CLI / JSON-RPC (do użycia z Home Assistant)

Wszystkie komendy wołane są przez usługi integracji Squeezebox: `squeezebox.call_query` (zapytania, wynik w `query_result`) lub `squeezebox.call_method` (akcje, bez zwrotki).

### Wyszukiwanie i odtwarzanie

**Wyszukiwanie** (nie wymaga gracza):
```yaml
service: squeezebox.call_query
data:
  entity_id: media_player.twoj_glosnik
  command: ytmusic
  parameters:
    - search
    - "search:nazwa utworu"
```
Zwraca `count` i listę `item_loop` z `title`/`artist`/`url`/`image`.

**Radio na bazie aktualnie granego utworu** (wymaga gracza, zastępuje resztę kolejki radiem):
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_glosnik
  command: ytmusic
  parameters:
    - trackradio
```

**Radio na bazie dowolnego utworu** (np. z wyników wyszukiwania — czyści kolejkę i zaczyna od razu od podanego `video_id`):
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_glosnik
  command: ytmusic
  parameters:
    - playradio
    - "video_id:BSTsnWoslP4"
```

**Polub aktualnie grany utwór:**
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_glosnik
  command: ytmusic
  parameters:
    - like
```

**Szybki zapis aktualnie granego utworu** (do playlisty "Zapisane z LMS"):
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_glosnik
  command: ytmusic
  parameters:
    - save
```

### Playlisty

**Lista playlist z biblioteki:**
```yaml
service: squeezebox.call_query
data:
  entity_id: media_player.twoj_glosnik
  command: ytmusic
  parameters:
    - playlists
```
Zwraca `count` i `item_loop` z `title`/`playlist_id`/`image`.

**Lista rekomendowanych playlist z sekcji "Polecane"** (np. "My Mix 1", "My Supermix" itd.):
```yaml
service: squeezebox.call_query
data:
  entity_id: media_player.twoj_glosnik
  command: ytmusic
  parameters:
    - homeplaylists
```
Zwraca `count` i `item_loop` z `title`/`playlist_id`/`section`/`image`.

**Zawartość konkretnej playlisty** (podglad utworów, nie odtwarza):
```yaml
service: squeezebox.call_query
data:
  entity_id: media_player.twoj_glosnik
  command: ytmusic
  parameters:
    - playlisttracks
    - "playlist_id:TWOJE_ID"
```

**Zagraj całą playlistę od razu** (czyści kolejkę, dodaje wszystkie utwory, odtwarza):
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_glosnik
  command: ytmusic
  parameters:
    - playplaylist
    - "playlist_id:TWOJE_ID"
```

**Dopisz całą playlistę na koniec kolejki** (bez czyszczenia/odtwarzania):
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_glosnik
  command: ytmusic
  parameters:
    - addplaylist
    - "playlist_id:TWOJE_ID"
```

**Zagraj/dopisz utwory z "płaskiej" sekcji Polecane** (np. sekcje typu "Your daily discover", które zawierają pojedyncze utwory, nie playlisty):
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_glosnik
  command: ytmusic
  parameters:
    - playhomesection
    - "section:Your daily discover"
```
(analogicznie `addhomesection` dla dopisania bez czyszczenia kolejki)

### Zarządzanie ReplayGain z automatyzacji

Pozwala tymczasowo (do restartu LMS) nadpisać ustawienia z panelu Settings, bez zapisywania niczego na dysk — przydatne np. do automatyzacji "wyłącz precyzyjny gain w nocy" albo "wymuś liczenie gainu niezależnie od głośności po 22:00".

**Włącz/wyłącz główny wyłącznik gainu:**
```yaml
service: squeezebox.call_query
data:
  command: ytmusic
  parameters:
    - replaygain
    - "1"   # albo "0", albo "clear" (usuń override, wróć do ustawień z panelu), albo "status" (tylko odczyt)
```
Zwraca `enabled` (aktualny efektywny stan) i `override` (`none` gdy nieaktywny).

**Zmień/wyłącz próg głośności:**
```yaml
service: squeezebox.call_query
data:
  command: ytmusic
  parameters:
    - replaygainvolume
    - "30"   # albo "0" (licz gain zawsze), albo "clear", albo "status"
```
Zwraca `min_volume` i `override`.

## Wymagania i instalacja

1. **Instalacja przez repozytorium** — w LMS: Settings → Plugins → Additional Repositories, wklej adres repo, zapisz i odśwież listę wtyczek. Zainstaluj "YTMusic" z listy.
2. **Uwierzytelnienie YouTube Music** (wymagane do: playlist, polubionych utworów, polubienia, szybkiego zapisu, dodawania do playlist — wyszukiwanie i odtwarzanie działają też bez tego).

### Generowanie pliku uwierzytelniania

1. Otwórz `music.youtube.com` w przeglądarce, zaloguj się na swoje konto.
2. Otwórz Narzędzia deweloperskie (F12) → zakładka **Network**.
3. W polu filtra wpisz `browse`.
4. Kliknij na jakąś playlistę/bibliotekę, żeby wygenerować żądanie `POST .../browse?...`.
5. Kliknij na to żądanie → **Headers** → **Request Headers** → skopiuj całość (w Chrome: prawy klik na nazwę żądania → *Copy → Copy request headers*).
6. W terminalu kontenera LMS (z zainstalowanym `ytmusicapi`) uruchom:
   ```bash
   python3 -m ytmusicapi browser
   ```
7. Wklej skopiowane nagłówki, zatwierdź. Powstanie plik `browser.json`.
8. Przenieś plik do katalogu cache pluginu i zmień nazwę na `ytmusic_auth.json`, np.:
   ```bash
   mv browser.json /config/lms/cache/YTMusic/ytmusic_auth.json
   ```
9. Zrestartuj LMS (albo tylko bridge, jeśli masz do tego dostęp).

**Uwaga:** token uwierzytelniający wygasa po pewnym czasie (typowo kilka tygodni). Jeśli funkcje wymagające logowania zaczną zwracać błąd "auth?" w logach, powtórz powyższe kroki.

## Architektura (dla zainteresowanych/współtwórców)

- `Plugin.pm` — menu OPML, komendy CLI, zarządzanie procesem bridge'a, prefetch i planowanie głębokiej analizy gainu.
- `ProtocolHandler.pm` — rejestracja protokołu `ytmusic://`, logika ReplayGain (`onStream`), cache metadanych (persystowany na dysk, bez pól gainu — te mają jedno źródło prawdy: bridge).
- `DontStopTheMusic.pm` — integracja z mechanizmem automatycznego doigrywania kolejki.
- `Settings.pm` — strona ustawień w interfejsie LMS.
- `ytmusic_bridge.py` — serwer FastAPI: wyszukiwanie, metadane, streaming (remux `-acodec copy`, bez transkodowania), pomiar gainu (loudnorm, trzy poziomy jakości: szybki/połowa/cały utwór).

Gain ma jedno źródło prawdy — cache po stronie bridge'a (`ytmusic_gain_cache.json`), z jakością rosnącą monotonicznie (nigdy degradowaną). Lokalny cache metadanych w Perlu persystuje tylko pola opisowe (tytuł/artysta/długość/okładka) między restartami LMS — pole gainu jest zawsze odświeżane od bridge'a po restarcie.
