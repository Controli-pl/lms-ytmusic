# YTMusic — wtyczka YouTube Music dla dodatku Lyrion Music Server (LMS) w Home Assistant OS.

Wtyczka integrująca YouTube Music z Lyrion Music Server (dawniej Logitech/Squeezebox Server). 
Umożliwia przeglądanie, wyszukiwanie i odtwarzanie muzyki z YouTube Music na wszystkich odtwarzaczach Squeezebox/LMS, z pełną obsługą ReplayGain, obsługą DSTM i integracją z Home Assistant przez komendy CLI.
Może pracować w dwóch wariantach - z lub bez autoryzacji (patrz niżej).
Po autoryzacji zyskujesz: 
- przeglądanie playlist YT
- przeglądanie rekomendacji
- możliwość "Lajkowania".

| | | | | | |
|---|---|---|---|---|---|
| <img src="PL/INFO/1.jpg" width="250"> | <img src="PL/INFO/2.jpg" width="250"> | <img src="PL/INFO/3.jpg" width="250"> | <img src="PL/INFO/4.jpg" width="250"> | <img src="PL/INFO/5.jpg" width="250"> | <img src="PL/INFO/6.jpg" width="250"> |

## Zastrzeżenie

Wtyczka to prywatny, niezależny projekt. Działa w oparciu o biblioteki Phyton i może przestać działać w dowolnym momencie, jeśli Google zmieni interfejs API.
Korzystaj z niej na własne ryzyko i zgodnie z Warunkami korzystania z usługi YouTube. Obecna wersja dostosowana jest do dodatku LMS dla Home Assistant zainstalowanych na sprzęcie x86-64.

## Wymagania
- Lyrion Music Server 9.1 (obsługa Gain) lub nowszy
- Serwer, na którym stoi LMS wraz z Home Assistant: Linux, x86-64 (amd64). Inne platformy (Raspberry Pi/ARM, macOS, Windows natywnie) nie są obecnie wspierane — patrz sekcja Ograniczenia.

## Jak to działa
Projekt się z dwóch części:

- **Plugin LMS (Perl)** — integruje się z menu, kolejką odtwarzania, DSTM, ReplayGain i CLI/JSON-RPC LMS.
- **Bridge (Python, `ytmusic_bridge`)** — lokalny serwer HTTP (`127.0.0.1:8008`), który komunikuje się z YouTube Music (przez `ytmusicapi`) i pobiera/remuksuje strumienie audio (przez `yt-dlp` + `ffmpeg`).

Bridge jest uruchamiany i zarządzany automatycznie przez plugin.

## Funkcje

### Przeglądanie i odtwarzanie
- **Wyszukiwanie** utworów.
- **Polecane** — rekomendacje z YouTube Music (sekcje typu "Mixed for you", "My Mix 1-6" itd.), z podglądem zawartości sekcji i możliwością odtworzenia/dodania całej sekcji na raz.
- **Moje playlisty** — playlisty z Twojej biblioteki YouTube Music.
- **Polubione utwory** — biblioteka polubionych utworów.
- **Radio** — na bazie ostatnio odtwarzanego utworu, budowane z menu głównego lub z menu kontekstowego utworu (dokleja radio do kolejki).
- **Menu kontekstowe utworu** — Polub, Szybki zapis (do auto-tworzonej playlisty "Zapisane z LMS"), Dodaj do konkretnej playlisty, Szukaj w YTMusic (dla utworów z innych źródeł, np. biblioteki lokalnej).
- **Integracja z Don't Stop The Music** — dwa tryby: Radio (na bazie ostatniego utworu) i Mix (na bazie kilku ostatnich utworów w kolejce, wyniki miksowane naprzemiennie między seedami).
- **Przewijanie** — pełne wsparcie seek w trakcie odtwarzania.

### ReplayGain
Utwory serwowane przez Youtube mają często bardzo różny poziom głośności, co skutecznie psuło doświadczenia przy odsłuchu dłuższej playlisty bez stałego nadzoru,  dlatego wtyczka liczy i stosuje ReplayGain automatycznie, bez potrzeby wcześniejszej analizy całej biblioteki:

- **Szybki pomiar** (pierwsze ~25s utworu) — stosowany od razu przy pierwszym odtworzeniu i przy prefetchu utworów w kolejce, żeby nie blokować startu odtwarzania.
- **Głęboka analiza** — po przekroczeniu skonfigurowanego procentu realnie odsłuchanej długości utworu, wtyczka w tle zamawia dokładniejszy pomiar (połowa utworu albo cały utwór) i zapamiętuje go na przyszłość. Naprawia to przypadki utworów z cichym wstępem i mocnym wejściem w dalszej części, gdzie krótka analiza dawała zawyżony gain. Utwory szybko przeskoczone nie są analizowane ponownie — zero zbędnego obciążenia CPU.
- **Cache trwały** — policzone wartości gainu są trwale zapisywane przez bridge (przetrwają restart LMS), z rosnącą jakością (szybki → połowa → cały utwór), nigdy degradowaną w dół.
- **Prefetch** — gain dla najbliższych utworów w kolejce jest liczony z wyprzedzeniem, w tle, także dla utworów wstawionych przez "Zagraj jako następny".

Ustawienia (Ustawienia → Zawansowane → YTMusic w interfejsie LMS):

| Ustawienie | Opis |
|---|---|
| Włącz Replay Gain | Główny wyłącznik — wyłączony, gain nie jest liczony ani stosowany dla żadnego utworu |
| Minimalna głośność dla liczenia gainu | Nowy gain jest liczony tylko gdy przynajmniej jeden podłączony gracz ma głośność powyżej tej wartości (0 = liczony zawsze, niezależnie od głośności) |
| Próg odsłuchania dla głębokiej analizy | Po ilu % realnego odsłuchania utworu zamawiana jest dokładniejsza analiza |
| Zakres głębokiej analizy | 25 sekund (brak pogłębiania — wyłącza mechanizm), połowa utworu, albo cały utwór (najdokładniejsze) |

## Komendy CLI / JSON-RPC (do użycia z Home Assistant)

Wszystkie komendy wołane są przez usługi integracji Squeezebox: `squeezebox.call_query` (zapytania, wynik w `query_result`) lub `squeezebox.call_method` (akcje, bez zwrotki).

### Wyszukiwanie i odtwarzanie

**Wyszukiwanie** (nie wymaga odtwarzacza):
```yaml
service: squeezebox.call_query
data:
  entity_id: media_player.twoj_odtwarzacz
  command: ytmusic
  parameters:
    - search
    - "search:nazwa utworu"
```
Zwraca `count` i listę `item_loop` z `title`/`artist`/`url`/`image`.

**Radio na bazie aktualnie granego utworu** (wymaga odtwarzacza, zastępuje resztę kolejki radiem):
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_odtwarzacz
  command: ytmusic
  parameters:
    - trackradio
```

**Radio na bazie dowolnego utworu** (np. z wyników wyszukiwania — czyści kolejkę i zaczyna od razu od podanego `video_id`):
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_odtwarzacz
  command: ytmusic
  parameters:
    - playradio
    - "video_id:BSTsnWoslP4"
```

**Polub aktualnie grany utwór:**
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_odtwarzacz
  command: ytmusic
  parameters:
    - like
```

**Szybki zapis aktualnie granego utworu** (do playlisty "Zapisane z LMS"):
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_odtwarzacz
  command: ytmusic
  parameters:
    - save
```

### Playlisty

**Lista playlist z biblioteki:**
```yaml
service: squeezebox.call_query
data:
  entity_id: media_player.twoj_odtwarzacz
  command: ytmusic
  parameters:
    - playlists
```
Zwraca `count` i `item_loop` z `title`/`playlist_id`/`image`.

**Lista rekomendowanych playlist z sekcji "Polecane"** (np. "My Mix 1", "My Supermix" itd.):
```yaml
service: squeezebox.call_query
data:
  entity_id: media_player.twoj_odtwarzacz
  command: ytmusic
  parameters:
    - homeplaylists
```
Zwraca `count` i `item_loop` z `title`/`playlist_id`/`section`/`image`.

**Zawartość konkretnej playlisty** (podglad utworów, nie odtwarza):
```yaml
service: squeezebox.call_query
data:
  entity_id: media_player.twoj_odtwarzacz
  command: ytmusic
  parameters:
    - playlisttracks
    - "playlist_id:TWOJE_ID"
```

**Zagraj całą playlistę od razu** (czyści kolejkę, dodaje wszystkie utwory, odtwarza):
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_odtwarzacz
  command: ytmusic
  parameters:
    - playplaylist
    - "playlist_id:TWOJE_ID"
```

**Dopisz całą playlistę na koniec kolejki** (bez czyszczenia/odtwarzania):
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_odtwarzacz
  command: ytmusic
  parameters:
    - addplaylist
    - "playlist_id:TWOJE_ID"
```

**Zagraj/dopisz utwory z "płaskiej" sekcji Polecane** (np. sekcje typu "Your daily discover", które zawierają pojedyncze utwory, nie playlisty):
```yaml
service: squeezebox.call_method
data:
  entity_id: media_player.twoj_odtwarzacz
  command: ytmusic
  parameters:
    - playhomesection
    - "section:Your daily discover"
```
(analogicznie `addhomesection` dla dopisania bez czyszczenia kolejki)

### Zarządzanie ReplayGain z automatyzacji

Pozwala tymczasowo (do restartu LMS) nadpisać ustawienia z panelu Settings, bez zapisywania niczego na dysk — przydatne np. do automatyzacji "włącz precyzyjny gain w nocy" albo "wymuś liczenie gainu niezależnie od głośności po 22:00".

**Włącz/wyłącz główny wyłącznik gainu:**
```yaml
service: squeezebox.call_query
data:
  entity_id: media_player.twoj_odtwarzacz
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
  entity_id: media_player.twoj_odtwarzacz
  command: ytmusic
  parameters:
    - replaygainvolume
    - "30"   # albo "0" (licz gain zawsze), albo "clear", albo "status"
```
Zwraca `min_volume` i `override`.

## Wymagania i instalacja

1. **Instalacja przez repozytorium** — w LMS: Settings → Plugins → Additional Repositories, wklej adres repo:
   
   https://raw.githubusercontent.com/Controli-pl/lms-ytmusic/refs/heads/main/YTMusic/repo.xml
   
   zapisz i odśwież listę wtyczek. Zainstaluj "YTMusic" z listy.
   
2. **Uwierzytelnienie YouTube Music** (wymagane do: playlist, polubionych utworów, polubienia, szybkiego zapisu, dodawania do playlist — wyszukiwanie i odtwarzanie działają bez tego).

### Generowanie pliku uwierzytelniania

1. Otwórz `music.youtube.com` w przeglądarce (najlepiej w trybie incognito), zaloguj się na swoje konto.
2. Otwórz Narzędzia deweloperskie (F12) → zakładka **Network**.
3. W polu filtra wpisz `browse`.
4. Kliknij na jakąś playlistę/bibliotekę, żeby wygenerować żądanie `POST .../browse?...`.
5. Kliknij na to żądanie → **Headers** → **Request Headers** → skopiuj wartość klucza cookie ( patrz obrazek ).

![Copying the cookie value from the request headers](https://raw.githubusercontent.com/Controli-pl/lms-ytmusic/main/PL/INFO/cookie.png)

6. Wklej skopiowaną wartość, zatwierdź. (zapisany plik przechowywany jest wyłącznie lokalnie na Twoim sprzęcie!)
7. Wartość pola statusu powinna zmienić się na Zalogowano.

**Uwaga:** token uwierzytelniający wygasa po pewnym czasie. Jeśli funkcje wymagające logowania zaczną zwracać błąd "auth?" w logach, powtórz powyższe kroki.

## Wsparcie i opinie

Nie jestem zawodowym programistą — to projekt hobbystyczny, który stworzyłem na własny użytek. Jeśli masz rozsądne sugestie, prośby o nowe funkcje lub natkniesz się na błędy, śmiało zgłoś problem, a postaram się pomóc. Mimo to, mój wolny czas jest ograniczony (i szczerze mówiąc, prawdopodobnie powinienem skupić się bardziej na... życiu i zarabianiu na życie 😅), więc proszę o cierpliwość — odpowiedzi mogą chwilę potrwać. 

Jeśli chcesz wesprzeć projekt:

- ☕ [Postaw mi kawę](https://buymeacoffee.com/controli)
- 💬 Podziękuj w [wątku Dyskusji](https://github.com/Controli-pl/lms-ytmusic/discussions/1)
- ⭐ Albo po prostu zostaw gwiazdkę — to nic nie kosztuje, a świetnie motywuje!
