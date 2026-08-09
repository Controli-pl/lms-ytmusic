package Plugins::YTMusic::Plugin;
use strict;
use base qw(Slim::Plugin::OPMLBased);

use Plugins::YTMusic::ProtocolHandler;
use Plugins::YTMusic::Settings;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Networking::SimpleAsyncHTTP;
use JSON::XS::VersionOneAndTwo;

use Slim::Menu::GlobalSearch;
use Slim::Menu::TrackInfo;
use Plugins::YTMusic::DontStopTheMusic;

use List::Util qw(min max);
use Scalar::Util qw(blessed);
use File::Spec::Functions qw(catdir catfile);
use File::Path qw(make_path);
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Prefs;
use Proc::Background;
use Time::HiRes;
use Slim::Utils::Timers;

my $log = Slim::Utils::Log->addLogCategory({
    'category' => 'plugin.ytmusic',
    'defaultLevel' => 'WARN',
    'description' => 'PLUGIN_YTMUSIC',
});

# Port/URL bridge'a maja TYLKO JEDNO miejsce definicji - w
# ProtocolHandler.pm (bridgePort()/bridgeUrl()). Wszystkie inne pliki
# (ten i DontStopTheMusic.pm) importuja te wartosci, zamiast trzymac
# wlasna, osobna kopie tej samej stalej.
my $BRIDGE_PORT = Plugins::YTMusic::ProtocolHandler::bridgePort();
my $BRIDGE = Plugins::YTMusic::ProtocolHandler::bridgeUrl();

# ---------------------------------------------------------------------
# Zarzadzanie procesem bridge'a (Bin/<arch>/ytmusic_bridge - PyInstaller
# onefile). Wczesniej bridge byl odpalany na zewnatrz pluginu (nohup w
# konfiguracji kontenera) - tutaj przenosimy to do initPlugin/shutdownPlugin,
# zeby plugin dzialal samodzielnie po zainstalowaniu z repozytorium, bez
# recznego bootstrapu.
# ---------------------------------------------------------------------
my $bridgeProc;

use constant BRIDGE_HEALTH_TIMEOUT => 15; # sekund na wystartowanie
use constant BRIDGE_HEALTH_INTERVAL => 0.5; # co ile pollowac /health

sub _startBridge {
    my $bin = Slim::Utils::Misc::findbin('ytmusic_bridge');
    unless ($bin) {
        $log->error("Nie znaleziono binarki ytmusic_bridge dla tej platformy "
            . "(sprawdz czy Bin/<arch>/ytmusic_bridge istnieje dla Twojej architektury)");
        return;
    }

    my $ffmpeg = Slim::Utils::Misc::findbin('ffmpeg') || 'ffmpeg';
    my $cacheDir = catdir(Slim::Utils::OSDetect::dirsFor('cache'), 'YTMusic');
    make_path($cacheDir) unless -d $cacheDir;

    # PyInstaller --onefile rozpakowuje siebie do katalogu tymczasowego przy
    # kazdym starcie i stamtad mapuje wspoldzielone biblioteki (libpython,
    # libz, itd.). Domyslny /tmp bywa zamontowany jako noexec (obserwowane
    # w kontenerze add-onu LMS na Home Assistant OS) - wtedy mapowanie
    # konczy sie bledem "failed to map segment from shared object", mimo
    # ze sam plik binarny ma prawo wykonania. Wymuszamy wiec katalog
    # tymczasowy pod cache pluginu, ktory na pewno jest wykonywalny (bo
    # LMS tam sam trzyma dane).
    my $bridgeTmpDir = catdir($cacheDir, 'tmp');
    make_path($bridgeTmpDir) unless -d $bridgeTmpDir;
    local $ENV{TMPDIR} = $bridgeTmpDir; # zostawiamy jako dodatkowe zabezpieczenie

    my $envBin = Slim::Utils::Misc::findbin('env') || '/usr/bin/env';

    $log->info("Startuje YTMusic bridge: $bin --port $BRIDGE_PORT --ffmpeg-bin $ffmpeg --cache-dir $cacheDir (TMPDIR=$bridgeTmpDir)");

    $bridgeProc = eval {
        Proc::Background->new(
            # TMPDIR wymuszony wprost w komendzie przez 'env', a nie tylko
            # przez local $ENV{...} - w tym srodowisku samo poleganie na
            # dziedziczeniu %ENV przez Proc::Background nie wystarczylo
            # (binarka i tak ladowala sie do domyslnego /tmp, ktory jest
            # zamontowany jako noexec w kontenerze add-onu).
            $envBin, "TMPDIR=$bridgeTmpDir",
            $bin,
            '--port', $BRIDGE_PORT,
            '--ffmpeg-bin', $ffmpeg,
            '--cache-dir', $cacheDir,
        );
    };

    if ($@ || !$bridgeProc) {
        $log->error("Nie udalo sie odpalic bridge'a: " . ($@ || 'nieznany blad'));
        return;
    }

    _waitForBridgeHealthy();
}

# Polluje /health zamiast zakladac na sztywno ile bridge potrzebuje czasu
# na start (import ytmusicapi/fastapi/uvicorn w binarce PyInstallera to
# kilkaset ms do paru sekund, zalezne od sprzetu - Raspberry Pi vs. NUC).
sub _waitForBridgeHealthy {
    my $deadline = Time::HiRes::time() + BRIDGE_HEALTH_TIMEOUT;

    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time(), sub {
        unless ($bridgeProc && $bridgeProc->alive) {
            $log->error("YTMusic bridge padl zanim zdazyl wystartowac");
            return;
        }

        Slim::Networking::SimpleAsyncHTTP->new(
            sub { $log->info("YTMusic bridge gotowy"); },
            sub {
                if (Time::HiRes::time() < $deadline) {
                    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + BRIDGE_HEALTH_INTERVAL, \&_waitForBridgeHealthyRetry, $deadline);
                } else {
                    $log->error("YTMusic bridge nie odpowiedzial na /health w ciagu " . BRIDGE_HEALTH_TIMEOUT . "s");
                }
            },
        )->get("$BRIDGE/health");
    }, $deadline);
}

sub _waitForBridgeHealthyRetry {
    my (undef, $deadline) = @_;
    _waitForBridgeHealthy();
}

sub _stopBridge {
    return unless $bridgeProc;
    $log->info("Zatrzymuje YTMusic bridge");
    $bridgeProc->die;
    $bridgeProc = undef;
}

sub shutdownPlugin {
    _stopBridge();
    Slim::Utils::Timers::killTimers(undef, \&_deepAnalysisFireTimer);
    Plugins::YTMusic::ProtocolHandler->flushMetaCache();
}

# ---------------------------------------------------------------------
# Ochrona przed race condition przy komendach ktore CZYSCIA kolejke na
# podstawie asynchronicznej odpowiedzi z bridge'a (playradio/trackradio/
# playplaylist/playhomesection). Kilka szybkich klikniec w rozne utwory
# odpala kilka rownoleglych zapytan HTTP - bez tej ochrony kolejke
# nadpisuje ta odpowiedz ktora wroci NAJPOZNIEJ, a nie ta odpowiadajaca
# najpozniejszemu kliknieciu, co dawalo objaw "dodaje X, a w kolejce
# ląduje zupelnie inny utwor Y".
#
# Kazde nowe wywolanie takiej komendy dla danego klienta podbija licznik;
# gdy odpowiedz HTTP wraca, sprawdzamy czy licznik klienta nadal wskazuje
# na NASZ token - jesli w miedzyczasie odpalono kolejne, nowsze wywolanie,
# ta (przestarzala) odpowiedz jest po cichu ignorowana.
# ---------------------------------------------------------------------
my %_queueRequestToken;

sub _nextQueueToken {
    my ($client) = @_;
    my $id = $client->id;
    return ++$_queueRequestToken{$id};
}

sub _isCurrentQueueToken {
    my ($client, $token) = @_;
    my $id = $client->id;
    return ($_queueRequestToken{$id} // 0) == $token;
}

my $GAIN_PREFETCH_AHEAD = 3;

sub _prefetchGain {
    my (@videoIds) = @_;

    # Respektuj ta sama logike co onStream() w ProtocolHandler.pm (wlacznik +
    # opcjonalny prog glosnosci) - bez tego prefetch bije w bridge (pelna
    # ekstrakcja yt-dlp + do 20s loudnorm w ffmpeg per utwor) nawet gdy gain
    # jest wylaczony lub nikt aktualnie nie sluchka na tyle glosno, zeby mial
    # to jakiekolwiek sluchowe znaczenie - co przy liscie/radiu idacym bez
    # dotykania potrafi utrzymywac bridge (python3) w ciaglym obciazeniu CPU
    # bez zadnego realnego pozytku.
    return unless Plugins::YTMusic::ProtocolHandler->replayGainShouldRun();

    # ZAWSZE mode=quick - to zapytanie jest SPEKULACYJNE (wysylane zanim
    # wiadomo czy user faktycznie posluchka danego utworu), wiec drozsze
    # tryby (half/full) tutaj bylyby marnotrawstwem CPU na utwory czesto
    # przeskakiwane w radiu/playliscie. Poprawiona wartosc przyjdzie
    # pozniej, asynchronicznie, przez _deepAnalysisFire - ale TYLKO dla
    # utworu ktory user realnie posluchal wystarczajaco dlugo (patrz nizej).
    for my $vid (@videoIds) {
        next unless $vid;
        Slim::Networking::SimpleAsyncHTTP->new(
            sub { $log->debug("Gain prefetch OK dla $vid"); },
            sub { $log->debug("Gain prefetch failed dla $vid (nieszkodliwe, policzy sie on-demand)"); },
        )->get("$BRIDGE/gain?video_id=$vid&mode=quick");
    }
}

# ---------------------------------------------------------------------
# GLEBOKA ANALIZA GAINU - wywolywana leniwie, po przekroczeniu progu %
# odsluchania danego utworu (gain_deep_analysis_percent w Settings,
# domyslnie 85%), w trybie skonfigurowanym w gain_deep_analysis_mode
# ('half'/'full' - 'quick' oznacza wylaczony mechanizm, patrz
# ProtocolHandler::deepAnalysisEnabled).
#
# WAZNE: prog jest liczony wzgledem REALNEGO czasu odtwarzania danego
# utworu ($client->songElapsedSeconds - uwzglednia pauzy/bufering), NIE
# zegara sciennego od momentu 'newsong'. Timer jest planowany "z gruba"
# na bazie zalozenia ciaglego odtwarzania (duration * percent/100
# sekund od teraz), a w momencie odpalenia _deepAnalysisFire weryfikuje
# realny elapsed - jesli jest za maly (user pauzowal), timer jest
# doplanowywany na brakujacy czas, zamiast od razu odpalac analize.
#
# Cel: naprawic przypadki cichy-wstep + mocne-wejscie, gdzie szybka
# analiza pierwszych 25s (mode=quick, uzywana przez prefetch/onStream
# fallback) dawala zawyzony gain - ale NIE placic kosztem drozszej
# analizy za utwory, ktore user przeskoczyl przed dosluchaniem do progu.
#
# Mechanizm: kazde 'newsong' planuje jednorazowy timer dla AKTUALNIE
# granego utworu. Jesli w miedzyczasie user przeskoczy do innego utworu,
# nowe 'newsong' najpierw kasuje (killTimers) ewentualny "wisiacy" timer
# z poprzedniego wywolania - wiec nigdy nie nazbiera sie ich wiecej niz
# jeden na raz.
# ---------------------------------------------------------------------

sub _currentEntryUrlFor {
    my ($client, $videoId) = @_;
    my $playlist = Slim::Player::Playlist::playList($client->master) or return 0;
    my $currentIndex = Slim::Player::Source::streamingSongIndex($client);
    return 0 unless defined $currentIndex;
    my $entry = $playlist->[$currentIndex];
    my $url = blessed($entry) ? ($entry->url // '') : ($entry // '');
    return $url eq "ytmusic://$videoId";
}

sub _deepAnalysisFire {
    my ($client, $videoId, $requiredSeconds) = @_;
    return unless $client;

    unless (_currentEntryUrlFor($client, $videoId)) {
        $log->debug("YTMusic: deep gain analysis - $videoId nie jest juz aktualnie grany, pomijam");
        return;
    }

    # Realny czas odtwarzania TEGO utworu - uwzglednia pauzy, w
    # przeciwienstwie do zegara sciennego od 'newsong'. Jesli akcesor
    # nie jest dostepny w tej wersji LMS, failsafe: traktujemy jako
    # "warunek spelniony" (lepiej przeanalizowac troche wczesniej niz
    # wcale nie analizowac z powodu braku API).
    my $elapsed = eval { $client->songElapsedSeconds() };
    $elapsed = $requiredSeconds unless defined $elapsed;

    if ($elapsed < $requiredSeconds) {
        my $remaining = $requiredSeconds - $elapsed;
        $log->debug("YTMusic: deep gain analysis - $videoId odtworzony tylko ${elapsed}s z wymaganych ${requiredSeconds}s "
            . "(pauza/bufering?), doplanowuje timer na kolejne ${remaining}s");
        Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $remaining, \&_deepAnalysisFireTimer, $videoId, $requiredSeconds);
        return;
    }

    my $mode = Plugins::YTMusic::ProtocolHandler->deepAnalysisMode();
    unless ($mode ne 'quick') {
        return; # wylaczone w Settings w miedzyczasie
    }

    # PONOWNE sprawdzenie jakosci TUZ PRZED wyslaniem zapytania - w
    # miedzyczasie (od zaplanowania timera w _onNewSong do jego
    # odpalenia, czyli przez caly czas trwania progu %) inny mechanizm
    # (np. prefetch dla tego samego utworu granego rownolegle na innym
    # graczu) mogl juz podniesc jakosc do co najmniej tego poziomu -
    # bez tego sprawdzenia wyslalibysmy zbedne zapytanie, na ktore
    # bridge i tak odpowiedzialby natychmiast z wlasnego cache (patrz
    # QUALITY_RANK check w ytmusic_bridge.py), ale niepotrzebnie.
    my $meta = Plugins::YTMusic::ProtocolHandler->getCachedMeta($videoId);
    my $knownQuality = $meta ? $meta->{replaygain_quality} : undef;
    if (defined $knownQuality
        && Plugins::YTMusic::ProtocolHandler->qualityRank($knownQuality) >= Plugins::YTMusic::ProtocolHandler->qualityRank($mode))
    {
        $log->debug("YTMusic: deep gain analysis - $videoId juz ma jakosc '$knownQuality' >= '$mode', pomijam zapytanie");
        return;
    }

    $log->debug("YTMusic: deep gain analysis (mode=$mode) dla $videoId po ${elapsed}s realnego odtwarzania");

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content) };
            if (!$@ && $data && defined $data->{replaygain_track_gain}) {
                my $newGain = $data->{replaygain_track_gain} + 0;
                my $newQuality = $data->{quality} || $mode;
                # KLUCZOWE (x2): (1) nadpisujemy lokalny cache w Perlu
                # (%metaCache), nie tylko cache na bridge'u - inaczej ta
                # poprawiona wartosc NIGDY nie zostanie zastosowana przy
                # nastepnym odtworzeniu (onStream krotko wychodzi, jesli
                # lokalny cache juz ma JAKAKOLWIEK wartosc gainu). (2)
                # zapisujemy TEZ 'quality' - bez tego kazde nastepne
                # 'newsong' dla tego samego utworu planowaloby kolejny,
                # zupelnie zbedny timer/zapytanie w nieskonczonosc.
                my $m = Plugins::YTMusic::ProtocolHandler->getCachedMeta($videoId) || {};
                $m->{replaygain_track_gain} = $newGain;
                $m->{replaygain_quality} = $newQuality;
                Plugins::YTMusic::ProtocolHandler->setCachedMeta($videoId, $m);
                $log->debug("YTMusic: deep gain analysis OK dla $videoId (mode=$mode) - zaktualizowano lokalny cache: gain=$newGain quality=$newQuality");
            } else {
                $log->debug("YTMusic: deep gain analysis OK dla $videoId (mode=$mode), ale nie udalo sie sparsowac odpowiedzi");
            }
        },
        sub { $log->debug("YTMusic: deep gain analysis failed dla $videoId (nieszkodliwe)"); },
        { Timeout => 100 },
    )->get("$BRIDGE/gain?video_id=$videoId&mode=$mode");
}

# Proste opakowanie zeby Slim::Utils::Timers mialo stabilna referencje do
# funkcji dla killTimers/setTimer (musi byc TA SAMA referencja w obu
# wywolaniach, zeby killTimers rozpoznal odpowiedni, wisiacy timer).
sub _deepAnalysisFireTimer {
    my ($client, $videoId, $requiredSeconds) = @_;
    _deepAnalysisFire($client, $videoId, $requiredSeconds);
}

my %_lastPrefetchTime; # client id -> epoch ostatniego prefetcha

use constant PREFETCH_THROTTLE_SECONDS => 3;

# ---------------------------------------------------------------------
# Wywolywane przy mutacjach kolejki. WAZNE: subskrybujemy sie TYLKO na
# konkretne subkomendy playlist, ktore realnie moga zmienic ZAWARTOSC
# kolejki (dodanie/wstawienie utworu) - NIE na cala rodzine 'playlist',
# ktora w LMS okazuje sie duzo bardziej "gadatliwa" niz oczekiwano
# (leci przy przesunieciach pozycji, aktualizacjach statusu itp.),
# co dawalo powtarzajacy sie, zbedny prefetch tych samych utworow
# wielokrotnie w ciagu tej samej sekundy.
#
# Dodatkowo throttlujemy prefetch per-klient (PREFETCH_THROTTLE_SECONDS)
# jako druga linia obrony - nawet gdy kilka subkomend odpali sie w
# krotkim odstepie, realnie wysylamy zapytania do bridge'a nie czesciej
# niz raz na ten okres.
# ---------------------------------------------------------------------
sub _onPlaylistChange {
    my $request = shift;
    my $client = $request->client() or return;

    my $isNewSong = $request->isCommand([['playlist'], ['newsong']]);

    my $clientId = $client->id;
    my $now = Time::HiRes::time();
    my $lastTime = $_lastPrefetchTime{$clientId} || 0;

    if ($isNewSong || ($now - $lastTime) >= PREFETCH_THROTTLE_SECONDS) {
        $_lastPrefetchTime{$clientId} = $now;
        _prefetchUpcoming($client);
    }

    return unless $isNewSong;

    _planDeepAnalysis($client);
}

# ---------------------------------------------------------------------
# Dynamiczny prefetch gain (mode=quick) dla nastepnych GAIN_PREFETCH_AHEAD
# utworow ytmusic:// w kolejce, liczac od AKTUALNEJ pozycji odtwarzania -
# wyodrebnione z bylego _onNewSong, teraz wolane z _onPlaylistChange przy
# kazdej mutacji kolejki (patrz komentarz wyzej).
# ---------------------------------------------------------------------
sub _prefetchUpcoming {
    my ($client) = @_;

    my $playlist = Slim::Player::Playlist::playList($client->master) or return;
    my $currentIndex = Slim::Player::Source::streamingSongIndex($client);
    return unless defined $currentIndex;

    my @upcoming;
    for my $i ($currentIndex .. min($currentIndex + $GAIN_PREFETCH_AHEAD - 1, $#$playlist)) {
        my $entry = $playlist->[$i];
        my $url = blessed($entry) ? ($entry->url // '') : ($entry // '');
        push @upcoming, $1 if $url =~ m{^ytmusic://(.+)$};
    }
    _prefetchGain(@upcoming) if @upcoming;
}

# ---------------------------------------------------------------------
# Planowanie jednorazowego timera glebokiej analizy dla AKTUALNIE
# granego utworu - wolane WYLACZNIE przy realnej zmianie utworu
# (newsong), patrz _onPlaylistChange. Logika identyczna jak w bylym
# _onNewSong, bez zmian.
# ---------------------------------------------------------------------
sub _planDeepAnalysis {
    my ($client) = @_;

    my $playlist = Slim::Player::Playlist::playList($client->master) or return;
    my $currentIndex = Slim::Player::Source::streamingSongIndex($client);
    return unless defined $currentIndex;

    # Zawsze najpierw kasujemy ewentualny wisiacy timer z POPRZEDNIEGO
    # utworu - zapobiega to nazbieraniu wielu rownoleglych timerow przy
    # szybkim przeskakiwaniu miedzy utworami.
    Slim::Utils::Timers::killTimers($client, \&_deepAnalysisFireTimer);

    return unless Plugins::YTMusic::ProtocolHandler->deepAnalysisEnabled();

    my $entry = $playlist->[$currentIndex];
    my $url = blessed($entry) ? ($entry->url // '') : ($entry // '');
    return unless $url =~ m{^ytmusic://(.+)$};
    my $videoId = $1;

    my $meta = Plugins::YTMusic::ProtocolHandler->getCachedMeta($videoId);
    my $duration = $meta ? $meta->{duration} : undef;
    unless ($duration && $duration > 0) {
        $log->debug("YTMusic: deep analysis - brak znanej dlugosci dla $videoId, pomijam planowanie timera");
        return;
    }

    my $configuredMode = Plugins::YTMusic::ProtocolHandler->deepAnalysisMode();
    my $knownQuality = $meta->{replaygain_quality};
    if (defined $knownQuality
        && Plugins::YTMusic::ProtocolHandler->qualityRank($knownQuality) >= Plugins::YTMusic::ProtocolHandler->qualityRank($configuredMode))
    {
        $log->debug("YTMusic: deep analysis - $videoId juz ma lokalnie jakosc '$knownQuality' >= '$configuredMode', nie planuje timera");
        return;
    }

    my $percent = Plugins::YTMusic::ProtocolHandler->deepAnalysisPercent();
    my $requiredSeconds = max(1, int($duration * $percent / 100));

    $log->debug("YTMusic: planuje deep gain analysis dla $videoId za ${requiredSeconds}s "
        . "(${percent}% z ${duration}s, aktualna znana jakosc: " . ($knownQuality // 'brak') . ")");

    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $requiredSeconds, \&_deepAnalysisFireTimer, $videoId, $requiredSeconds);
}

# Ile trzymac odpowiedz bridge'a w cache'u pluginu, liczone jako sliding
# window - kazdy odczyt z cache'a odswieza jego "wiek" (patrz
# _fetchBridgeJsonCached ponizej), wiec dopoki user aktywnie przeglada dany
# node (playliste/sekcje), cache nie wygasa. Wygasa dopiero po tylu minutach
# calkowitej BEZCZYNNOSCI wobec danego node'a. Krotsze niz cache po stronie
# bridge'a dla /home (20 min) - tu chodzi tylko o to, zeby w obrebie jednej
# sesji przegladania ("wejdz do playlisty -> zobacz liste -> kliknij
# play/add albo pojedynczy utwor") wszystkie zapytania widzialy DOKLADNIE
# ten sam zrzut danych, niezaleznie ile razy i z ktorego skina (Material vs
# domyslny) przyjdzie zapytanie o ten sam node.
use constant BRIDGE_JSON_CACHE_TTL => 5 * 60;

my %_bridgeJsonCache; # cacheKey => { ts => epoch, data => $data }
my %_bridgeJsonPending; # cacheKey => [ $done, $done, ... ] (w trakcie pobierania)

sub _fetchBridgeJsonCached {
    my ($cacheKey, $url, $done) = @_;

    if (my $entry = $_bridgeJsonCache{$cacheKey}) {
        if (time() - $entry->{ts} < BRIDGE_JSON_CACHE_TTL) {
            $entry->{ts} = time(); # sliding window - odswiez przy kazdym uzyciu
            return $done->($entry->{data});
        }
    }

    # Jesli zapytanie dla tego samego klucza juz leci (np. Material odpalil
    # rownolegle kilka zapytan o ten sam node), dolaczamy sie do niego
    # zamiast odpalac kolejne rownolegle zapytanie HTTP - to tez moglo byc
    # zrodlem rozjazdu przy rownoleglych/pokrywajacych sie zapytaniach.
    if (my $pending = $_bridgeJsonPending{$cacheKey}) {
        push @$pending, $done;
        return;
    }

    $_bridgeJsonPending{$cacheKey} = [$done];

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content) };

            if ($@ || !$data) {
                $log->warn("_fetchBridgeJsonCached: parse failed dla $cacheKey: $@");
                $data = undef;
            }
            else {
                $_bridgeJsonCache{$cacheKey} = { ts => time(), data => $data };
            }

            my $waiters = delete $_bridgeJsonPending{$cacheKey} || [];
            $_->($data) for @$waiters;
        },
        sub {
            $log->warn("_fetchBridgeJsonCached: HTTP request failed dla $cacheKey");
            my $waiters = delete $_bridgeJsonPending{$cacheKey} || [];
            $_->(undef) for @$waiters;
        },
    )->get($url);
}

sub _fetchHomeData {
    my ($done) = @_;
    _fetchBridgeJsonCached('home', "$BRIDGE/home", $done);
}

sub _fetchPlaylistData {
    my ($playlistId, $done) = @_;
    _fetchBridgeJsonCached("playlist:$playlistId", "$BRIDGE/playlist/$playlistId", $done);
}

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(
        feed => \&handleFeed,
        tag => 'ytmusic',
        menu => 'radios',
        is_app => 1,
        weight => 95,
        icon => 'plugins/YTMusic/html/images/ytmusic.png',
    );

    eval {
        # Odpalamy bridge jako pierwsze - reszta initPlugin (protocol handler,
        # menu, CLI) nie czeka na niego synchronicznie (health-check leci
        # asynchronicznie przez Slim::Utils::Timers), ale im wczesniej
        # wystartuje proces, tym mniejsza szansa ze pierwsze zapytanie usera
        # przyjdzie zanim bridge zdazy sie podniesc.
        _startBridge();

        Slim::Player::ProtocolHandlers->registerHandler(
            ytmusic => 'Plugins::YTMusic::ProtocolHandler'
        );

        Slim::Menu::GlobalSearch->registerInfoProvider( ytmusic => (
            after => 'middle',
            name => 'PLUGIN_YTMUSIC',
            func => \&searchInfoMenu,
        ) );

        Slim::Menu::TrackInfo->registerInfoProvider( ytmusic_radio => (
            after => 'middle',
            func => \&trackInfoRadioMenu,
        ) );

        Slim::Menu::TrackInfo->registerInfoProvider( ytmusic_actions => (
            after => 'middle',
            func => \&trackInfoActionsMenu,
        ) );

        Slim::Menu::TrackInfo->registerInfoProvider( ytmusic_crosssearch => (
            after => 'middle',
            func => \&trackInfoCrossSearchMenu,
        ) );

        # CLI/JSON-RPC komendy do wolania z zewnatrz (np. Home Assistant przez
        # uslugi "squeezebox.call_query" (zapytania, wynik w atrybucie query_result)
        # i "squeezebox.call_method" (akcje, bez zwrotki) integracji Squeezebox.
        Slim::Control::Request::addDispatch(['ytmusic', 'search'], [0, 1, 1, \&cliSearch]);
        Slim::Control::Request::addDispatch(['ytmusic', 'trackradio'], [1, 0, 0, \&cliTrackRadio]);
        Slim::Control::Request::addDispatch(['ytmusic', 'playradio'], [1, 0, 1, \&cliPlayRadio]);
        Slim::Control::Request::addDispatch(['ytmusic', 'like'], [1, 0, 0, \&cliLike]);
        Slim::Control::Request::addDispatch(['ytmusic', 'save'], [1, 0, 0, \&cliSave]);
        Slim::Control::Request::addDispatch(['ytmusic', 'playlists'], [0, 1, 0, \&cliPlaylists]);
        Slim::Control::Request::addDispatch(['ytmusic', 'homeplaylists'], [0, 1, 0, \&cliHomePlaylists]);
        Slim::Control::Request::addDispatch(['ytmusic', 'playlisttracks'], [0, 1, 1, \&cliPlaylistTracks]);
        Slim::Control::Request::addDispatch(['ytmusic', 'playplaylist'], [1, 0, 1, \&cliPlayPlaylist]);
        Slim::Control::Request::addDispatch(['ytmusic', 'addplaylist'], [1, 0, 1, \&cliAddPlaylist]);
        Slim::Control::Request::addDispatch(['ytmusic', 'playhomesection'], [1, 0, 1, \&cliPlayHomeSection]);
        Slim::Control::Request::addDispatch(['ytmusic', 'addhomesection'], [1, 0, 1, \&cliAddHomeSection]);

        # Tymczasowe (do restartu) sterowanie glownym wlacznikiem gainu,
        # np. z automatyzacji Home Assistant - patrz cliReplayGain nizej.
        Slim::Control::Request::addDispatch(['ytmusic', 'replaygain'], [0, 1, 1, \&cliReplayGain]);
        Slim::Control::Request::addDispatch(['ytmusic', 'replaygainvolume'], [0, 1, 1, \&cliReplayGainVolume]);

        Plugins::YTMusic::DontStopTheMusic::init();

        # Strona ustawien pluginu (Settings > Advanced > YTMusic w UI LMS) -
        # wygodny przelacznik gainu, progu glosnosci i glebokiej analizy
        # zamiast reczek przez 'nc'/CLI. Patrz Settings.pm.
        Plugins::YTMusic::Settings->new;

        # Dynamiczny prefetch gain + planowanie glebokiej analizy: przy
        # KAZDEJ zmianie utworu doliczamy gain dla nastepnych
        # $GAIN_PREFETCH_AHEAD utworow ytmusic:// w kolejce, licząc od
        # AKTUALNEJ pozycji, i planujemy jednorazowy timer glebokiej
        # analizy dla aktualnie granego utworu (patrz _onNewSong).
        Slim::Control::Request::subscribe(\&_onPlaylistChange, [['playlist'], ['newsong', 'addtracks', 'insert', 'load_tracks', 'add', 'loadtracks']]);

        $log->warn("YTMusic: initPlugin OK (protocol handler + global search + track info + CLI registered)");
    };
    if ($@) {
        $log->error("YTMusic initPlugin registration failed: $@");
    }
}

sub getDisplayName { 'PLUGIN_YTMUSIC' }

# ---------------------------------------------------------------------
# Glowne menu pluginu
# ---------------------------------------------------------------------
sub handleFeed {
    my ($client, $cb, $args) = @_;

    $cb->({
        items => [
            {
                name => string('PLUGIN_YTMUSIC_SEARCH') || 'Szukaj',
                type => 'search',
                url => \&handleSearch,
            },
            {
                name => string('PLUGIN_YTMUSIC_RADIO') || 'Radio (na bazie ostatnio granych)',
                type => 'link',
                url => \&handleRadioSeed,
            },
            {
                name => string('PLUGIN_YTMUSIC_PLAYLISTS') || 'Moje playlisty',
                type => 'link',
                url => \&handlePlaylists,
            },
            {
                name => string('PLUGIN_YTMUSIC_LIBRARY_SONGS') || 'Polubione utwory',
                type => 'link',
                url => \&handleLibrarySongs,
            },
            {
                name => string('PLUGIN_YTMUSIC_HOME') || 'Polecane',
                type => 'link',
                url => \&handleHome,
            },
        ],
    });
}

# ---------------------------------------------------------------------
# Polecane / strona glowna YTMusic (sekcje rekomendacji)
# ---------------------------------------------------------------------
sub handleHome {
    my ($client, $cb, $args) = @_;

    my %SKIP_SECTIONS = map { $_ => 1 } (
        'From your library',
        'Z Twojej biblioteki',
    );

    _fetchHomeData(sub {
        my ($data) = @_;

        if (!$data || !$data->{sections}) {
            $log->debug("Home: brak danych");
            return $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ERR_FETCH_RECOMMENDATIONS') || 'Blad pobierania rekomendacji', type => 'text' }] });
        }

        my @items;
        for my $section (@{ $data->{sections} }) {
            my $title = $section->{title} || '';
            my $contents = $section->{contents} || [];

            next if $SKIP_SECTIONS{$title};
            next unless @$contents;

            my $item = {
                name => $title || string('PLUGIN_YTMUSIC_SECTION_FALLBACK') || 'Sekcja',
                type => 'link',
                url => \&handleHomeSection,
                passthrough => [{ sectionTitle => $title }],
            };

            # Sekcje typu "Your daily discover" zawieraja BEZPOSREDNIO pojedyncze
            # utwory (nie playlisty), wiec nie maja swojego playlistId do podpiecia
            # pod istniejacy mechanizm play/add. Dajemy im wlasne play/add ktore
            # buduje liste "w locie" z zawartosci tej sekcji (patrz
            # cliPlayHomeSection/cliAddHomeSection nizej) - dzieki temu dziala tak
            # samo jak dla sekcji zlozonych z calych playlist (np. "Mixed for you").
            if (grep { $_->{videoId} } @$contents) {
                $item->{itemActions} = {
                    play => {
                        command => ['ytmusic', 'playhomesection'],
                        fixedParams => { section => $title },
                    },
                    add => {
                        command => ['ytmusic', 'addhomesection'],
                        fixedParams => { section => $title },
                    },
                };
            }

            push @items, $item;
        }

        unless (@items) {
            return $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_NO_RECOMMENDATIONS') || 'Brak rekomendacji w tej chwili', type => 'text' }] });
        }

        $cb->({ items => \@items });
    });
}

# Zawartosc jednej konkretnej sekcji z Polecane. Korzysta z tego samego
# cache'owanego zrzutu /home co handleHome - dzieki temu wpis sekcji,
# lista w niej i pozniejszy play/add tej sekcji zawsze widza identyczne dane.
sub handleHomeSection {
    my ($client, $cb, $args, $passthrough) = @_;
    my $sectionTitle = $passthrough->{sectionTitle};

    my $MAX_ITEMS = 25;

    _fetchHomeData(sub {
        my ($data) = @_;

        if (!$data || !$data->{sections}) {
            $log->debug("Home section: brak danych");
            return $cb->({ items => [] });
        }

        my ($section) = grep { ($_->{title} || '') eq $sectionTitle } @{ $data->{sections} };
        unless ($section) {
            return $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_SECTION_UNAVAILABLE') || 'Sekcja juz niedostepna (odswiez Polecane)', type => 'text' }] });
        }

        my @items;
        my %seen;
        for my $c (@{ $section->{contents} || [] }) {
            last if scalar(@items) >= $MAX_ITEMS;

            # WAZNE: sprawdzamy videoId PRZED playlistId - pojedyncze utwory
            # w get_home() czesto MAJA tez playlistId (auto-radio dla tego
            # utworu, np. "RDAMVMxxxx"), ktory NIE jest tym samym co samo
            # odtworzenie utworu.
            if ($c->{videoId}) {
                next if $seen{"v:" . $c->{videoId}}++;
                push @items, _trackToSearchItem($c);
            }
            elsif ($c->{playlistId}) {
                next if $seen{"p:" . $c->{playlistId}}++;
                push @items, {
                    name => $c->{title} || string('PLUGIN_YTMUSIC_PLAYLIST_FALLBACK') || 'Playlist',
                    type => 'link',
                    url => \&handlePlaylistTracks,
                    passthrough => [{ playlistId => $c->{playlistId} }],
                    image => _extractImage($c),
                    itemActions => {
                        play => {
                            command => ['ytmusic', 'playplaylist'],
                            fixedParams => { playlist_id => $c->{playlistId} },
                        },
                        add => {
                            command => ['ytmusic', 'addplaylist'],
                            fixedParams => { playlist_id => $c->{playlistId} },
                        },
                    },
                };
            }
            # albumy/artysci (tylko browseId) pomijani na razie
        }

        unless (@items) {
            return $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_NO_SECTION_ITEMS') || 'Brak pozycji w tej sekcji', type => 'text' }] });
        }

        $cb->({ items => \@items });
    });
}

# ---------------------------------------------------------------------
# Moje playlisty (wymaga headers_auth.json po stronie bridge'a)
# ---------------------------------------------------------------------
sub handlePlaylists {
    my ($client, $cb, $args) = @_;

    my $url = "$BRIDGE/playlists";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content) };

            if ($@ || !$data || !$data->{playlists}) {
                $log->warn("Playlists parse failed: $@");
                return $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ERR_FETCH_PLAYLISTS') || 'Blad pobierania playlist (auth?)', type => 'text' }] });
            }

            my @items = map {
                my $pl = $_;
                {
                    name => $pl->{title} || string('PLUGIN_YTMUSIC_PLAYLIST_FALLBACK') || 'Playlist',
                    type => 'link',
                    url => \&handlePlaylistTracks,
                    passthrough => [{ playlistId => $pl->{playlistId} }],
                    image => _extractImage($pl),
                    itemActions => {
                        play => {
                            command => ['ytmusic', 'playplaylist'],
                            fixedParams => { playlist_id => $pl->{playlistId} },
                        },
                        add => {
                            command => ['ytmusic', 'addplaylist'],
                            fixedParams => { playlist_id => $pl->{playlistId} },
                        },
                    },
                }
            } grep { $_->{playlistId} } @{ $data->{playlists} };

            $cb->({ items => \@items });
        },
        sub {
            $log->warn("Playlists HTTP request failed");
            $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ERR_BRIDGE_CONNECTION') || 'Blad polaczenia z bridge', type => 'text' }] });
        },
    )->get($url);
}

sub handlePlaylistTracks {
    my ($client, $cb, $args, $passthrough) = @_;
    my $playlistId = $passthrough->{playlistId};

    _fetchPlaylistData($playlistId, sub {
        my ($data) = @_;

        if (!$data || !$data->{tracks}) {
            $log->debug("Playlist tracks: brak danych dla $playlistId");
            return $cb->({ items => [] });
        }

        # Kolejnosc dokladnie taka jak zwraca get_playlist() - bez zadnego
        # odwracania (patrz komentarz w _fetchPlaylistUrls nizej).
        my @items = map { _trackToSearchItem($_) }
            grep { $_->{videoId} } @{ $data->{tracks} };

        $cb->({ items => \@items });
    });
}

# ---------------------------------------------------------------------
# Polubione utwory (biblioteka, wymaga headers_auth.json)
# ---------------------------------------------------------------------
sub handleLibrarySongs {
    my ($client, $cb, $args) = @_;

    my $url = "$BRIDGE/library_songs";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content) };

            if ($@ || !$data || !$data->{tracks}) {
                $log->warn("Library songs parse failed: $@");
                return $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ERR_FETCH_LIBRARY') || 'Blad pobierania biblioteki (auth?)', type => 'text' }] });
            }

            my @items = map { _trackToSearchItem($_) }
                grep { $_->{videoId} } @{ $data->{tracks} };

            $cb->({ items => \@items });
        },
        sub {
            $log->warn("Library songs HTTP request failed");
            $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ERR_BRIDGE_CONNECTION') || 'Blad polaczenia z bridge', type => 'text' }] });
        },
    )->get($url);
}

# ---------------------------------------------------------------------
# Wyszukiwanie tekstowe (menu glowne + global search)
# ---------------------------------------------------------------------
sub handleSearch {
    my ($client, $cb, $args, $params) = @_;
    my $query = ($params && $params->{search}) || $args->{search};

    return $cb->({ items => [] }) unless $query;

    my $url = "$BRIDGE/search?q=" . Slim::Utils::Misc::escape($query) . "&limit=25";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content) };

            if ($@ || !$data || !$data->{results}) {
                $log->warn("Search parse failed: $@");
                return $cb->({ items => [] });
            }

            my @items = map { _trackToSearchItem($_) } grep { $_->{videoId} } @{ $data->{results} };

            $cb->({ items => \@items });
        },
        sub {
            $log->warn("Search HTTP request failed");
            $cb->({ items => [] });
        },
    )->get($url);
}

sub searchInfoMenu {
    my ($client, $tags) = @_;
    my $query = $tags->{search} or return;

    return {
        name => 'YTMusic',
        items => [{
            name => sprintf(string('PLUGIN_YTMUSIC_SEARCH_QUERY') || "Szukaj \"%s\" w YouTube Music", $query),
            type => 'link',
            url => \&handleSearch,
            passthrough => [{ search => $query }],
        }],
    };
}

# ---------------------------------------------------------------------
# Radio: przegladanie z glownego menu (bazuje na ostatnio granym)
# ---------------------------------------------------------------------
sub handleRadioSeed {
    my ($client, $cb, $args) = @_;

    my $lastUrl = $client->playingSong ? $client->playingSong->track->url : undef;
    my $videoId;
    if ($lastUrl && $lastUrl =~ m{^ytmusic://(.+)$}) {
        $videoId = $1;
    }

    if (!$videoId) {
        return $cb->({
            items => [{
                name => string('PLUGIN_YTMUSIC_PLAY_FIRST_FOR_RADIO') || 'Najpierw odtworz jakis utwor YTMusic, zeby zbudowac radio',
                type => 'text',
            }],
        });
    }

    handleRadio($client, $cb, { videoId => $videoId });
}

sub handleRadio {
    my ($client, $cb, $args) = @_;
    my $videoId = $args->{videoId};

    my $url = "$BRIDGE/radio?video_id=$videoId&limit=25";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content) };

            if ($@ || !$data || !$data->{tracks}) {
                $log->warn("Radio parse failed: $@");
                return $cb->({ items => [] });
            }

            my @items = map { _trackToItem($_, addRadioLink => 1) }
                grep { $_->{videoId} } @{ $data->{tracks} };

            $cb->({ items => \@items });
        },
        sub {
            $log->warn("Radio HTTP request failed");
            $cb->({ items => [] });
        },
    )->get($url);
}

# ---------------------------------------------------------------------
# Radio z menu kontekstowego utworu -> dokleja od razu do playlisty
# ---------------------------------------------------------------------
sub trackInfoRadioMenu {
    my ($client, $url, $track, $remoteMeta) = @_;

    return undef unless $url && $url =~ m{^ytmusic://(.+)$};
    my $videoId = $1;

    return {
        name => string('PLUGIN_YTMUSIC_START_RADIO_FROM_TRACK') || 'Rozpocznij radio YTMusic od tego utworu',
        type => 'link',
        url => \&handleRadioAddToPlaylist,
        passthrough => [{ videoId => $videoId }],
    };
}

sub _trackToSearchItem {
    my ($r) = @_;
    my $videoId = $r->{videoId};
    my $artist = ref($r->{artists}) eq 'ARRAY' ? $r->{artists}[0]{name} : $r->{artist};
    my $name = ($r->{title} || 'Unknown') . ($artist ? " - $artist" : '');
    my $image = _extractImage($r);

    return {
        name => $name,
        type => 'audio',
        url => "ytmusic://$videoId",
        image => $image,
        on_select => 'play',
        itemActions => {
            items => {
                command => ['ytmusic', 'playradio'],
                fixedParams => { video_id => $videoId },
            },
        },
    };
}

sub _extractImage {
    my ($r) = @_;
    for my $key (qw(thumbnails thumbnail)) {
        my $thumbs = $r->{$key};
        if (ref($thumbs) eq 'ARRAY' && @$thumbs) { return $thumbs->[-1]{url}; }
        elsif (ref($thumbs) eq 'HASH' && $thumbs->{url}) { return $thumbs->{url}; }
        elsif (!ref($thumbs) && $thumbs) { return $thumbs; }
    }
    return undef;
}

sub handleRadioAddToPlaylist {
    my ($client, $cb, $args, $passthrough) = @_;
    my $videoId = $passthrough->{videoId};
    my $includeSeed = $passthrough->{includeSeed};

    my $url = "$BRIDGE/radio?video_id=$videoId&limit=25";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content) };

            if ($@ || !$data || !$data->{tracks}) {
                $log->warn("Radio (add) parse failed: $@");
                return $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ERR_FETCH_RADIO') || 'Blad pobierania radia', type => 'text' }] });
            }

            my @tracks = grep { $_->{videoId} } @{ $data->{tracks} };

            # get_watch_playlist zwraca sam utwor-seed jako pierwszy element z listy tracks -
            # zawsze go pomijamy stad, a dodajemy jawnie ponizej tylko jesli includeSeed=1.
            if (@tracks && $tracks[0]->{videoId} eq $videoId) {
                shift @tracks;
            }

            unless (@tracks || $includeSeed) {
                return $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_NO_RADIO_RESULTS') || 'Brak wynikow radia', type => 'text' }] });
            }

            my @urls;
            push @urls, "ytmusic://$videoId" if $includeSeed;

            for my $t (@tracks) {
                my $vid = $t->{videoId};
                push @urls, "ytmusic://$vid";

                # Wypelniamy cache metadanych z gotowych danych z /radio,
                # zeby getMetadataFor nie musial wolac bridge'a/yt-dlp
                # osobno dla kazdego z tych utworow (to bylo zrodlem
                # powolnego dodawania radia do kolejki).
                my $artist = ref($t->{artists}) eq 'ARRAY' ? $t->{artists}[0]{name} : $t->{artist};
                my $thumb;
                my $thumbs = $t->{thumbnails} || $t->{thumbnail};
                if (ref($thumbs) eq 'ARRAY' && @$thumbs) {
                    $thumb = $thumbs->[-1]{url};
                } elsif (ref($thumbs) eq 'HASH') {
                    $thumb = $thumbs->{url};
                } elsif (!ref($thumbs) && $thumbs) {
                    $thumb = $thumbs;
                }

                Plugins::YTMusic::ProtocolHandler->setCachedMeta($vid, {
                    title => $t->{title},
                    artist => $artist,
                    duration => _parseLength($t->{length}) || $t->{duration} || $t->{length_seconds},
                    cover => $thumb || '',
                    icon => $thumb || '',
                    type => 'YouTube Music',
                });
            }

            $client->execute(['playlist', 'addtracks', 'listref', \@urls]);

            $cb->({
                items => [{
                    name => sprintf(string('PLUGIN_YTMUSIC_ADDED_N_TRACKS') || "Dodano %d utworow do kolejki", scalar(@urls)),
                    type => 'text',
                }],
            });
        },
        sub {
            $log->warn("Radio (add) HTTP request failed");
            $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ERR_BRIDGE_CONNECTION') || 'Blad polaczenia z bridge', type => 'text' }] });
        },
    )->get($url);
}

sub _parseLength {
    my $length = shift;
    return undef unless $length;
    if ($length =~ /^(\d+):(\d+)$/) {
        return $1 * 60 + $2;
    }
    return undef;
}

# ---------------------------------------------------------------------
# Wspolny mapper: track (z /search lub /radio) -> item menu OPML
# ---------------------------------------------------------------------
sub _trackToItem {
    my ($r, %opts) = @_;

    my $artist = ref($r->{artists}) eq 'ARRAY' ? $r->{artists}[0]{name} : $r->{artist};

    my $image;
    for my $key (qw(thumbnails thumbnail)) {
        my $thumbs = $r->{$key};
        if (ref($thumbs) eq 'ARRAY' && @$thumbs) {
            $image = $thumbs->[-1]{url};
            last;
        }
        elsif (ref($thumbs) eq 'HASH' && $thumbs->{url}) {
            $image = $thumbs->{url};
            last;
        }
        elsif (ref($thumbs) eq '' && $thumbs) {
            $image = $thumbs;
            last;
        }
    }

    my $item = {
        name => ($r->{title} || 'Unknown') . ($artist ? " - $artist" : ''),
        type => 'audio',
        url => 'ytmusic://' . $r->{videoId},
        image => $image || undef,
        on_select => 'play',
    };

    if ($opts{addRadioLink}) {
        $item->{itemActions} = {
            items => {
                command => ['ytmusic', 'playradio'],
                fixedParams => { video_id => $r->{videoId} },
            },
        };
    }

    return $item;
}

# ---------------------------------------------------------------------
# CLI: tymczasowe (do restartu LMS) sterowanie glownym wlacznikiem replay
# gain - do wolania z zewnatrz, np. z automatyzacji Home Assistant.
# ---------------------------------------------------------------------
sub cliReplayGain {
    my $request = shift;

    if ($request->isNotQuery([['ytmusic'], ['replaygain']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $arg = $request->getParam('_p2');

    if (defined $arg && $arg ne '' && lc($arg) ne 'status') {
        if (lc($arg) eq 'clear') {
            Plugins::YTMusic::ProtocolHandler->setReplayGainRuntimeOverride(undef);
        }
        else {
            Plugins::YTMusic::ProtocolHandler->setReplayGainRuntimeOverride($arg ? 1 : 0);
        }
    }

    my $override = Plugins::YTMusic::ProtocolHandler->replayGainRuntimeOverride();

    $request->addResult('enabled', defined($override) ? $override : Plugins::YTMusic::ProtocolHandler->replayGainPersistedEnabled());
    $request->addResult('override', defined($override) ? $override : 'none');
    $request->setStatusDone();
}

# ---------------------------------------------------------------------
# CLI: tymczasowe (do restartu LMS) sterowanie progiem glosnosci dla gainu
# ---------------------------------------------------------------------
sub cliReplayGainVolume {
    my $request = shift;

    if ($request->isNotQuery([['ytmusic'], ['replaygainvolume']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $arg = $request->getParam('_p2');

    if (defined $arg && $arg ne '' && lc($arg) ne 'status') {
        if (lc($arg) eq 'clear') {
            Plugins::YTMusic::ProtocolHandler->setReplayGainMinVolumeOverride(undef);
        }
        else {
            Plugins::YTMusic::ProtocolHandler->setReplayGainMinVolumeOverride($arg);
        }
    }

    my $override = Plugins::YTMusic::ProtocolHandler->replayGainMinVolumeOverride();

    $request->addResult('min_volume', defined($override) ? $override : Plugins::YTMusic::ProtocolHandler->replayGainPersistedMinVolume());
    $request->addResult('override', defined($override) ? $override : 'none');
    $request->setStatusDone();
}

# ---------------------------------------------------------------------
# CLI: wyszukiwanie (query) - do wolania z zewnatrz, np. Home Assistant.
# Zwraca item_loop z title/artist/url/image, count = liczba wynikow.
# ---------------------------------------------------------------------
sub cliSearch {
    my $request = shift;

    if ($request->isNotQuery([['ytmusic'], ['search']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $query = $request->getParam('search') || $request->getParam('_search');
    unless ($query) {
        $request->setStatusBadParams();
        return;
    }

    $request->setStatusProcessing();

    my $url = "$BRIDGE/search?q=" . Slim::Utils::Misc::escape($query) . "&limit=25";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content) };

            if ($@ || !$data || !$data->{results}) {
                $log->warn("cliSearch: parse failed: $@");
                $request->addResult('count', 0);
                $request->setStatusDone();
                return;
            }

            my $i = 0;
            for my $r (grep { $_->{videoId} } @{ $data->{results} }) {
                my $artist = ref($r->{artists}) eq 'ARRAY' ? $r->{artists}[0]{name} : $r->{artist};
                my $image = _extractImage($r);

                $request->addResultLoop('item_loop', $i, 'title', $r->{title} || 'Unknown');
                $request->addResultLoop('item_loop', $i, 'artist', $artist || '');
                $request->addResultLoop('item_loop', $i, 'url', 'ytmusic://' . $r->{videoId});
                $request->addResultLoop('item_loop', $i, 'image', $image || '');
                $i++;
            }

            $request->addResult('count', $i);
            $request->setStatusDone();
        },
        sub {
            $log->warn("cliSearch: HTTP request failed");
            $request->addResult('count', 0);
            $request->setStatusDone();
        },
    )->get($url);
}

# ---------------------------------------------------------------------
# CLI: radio na bazie aktualnie granego utworu
# ---------------------------------------------------------------------
sub cliTrackRadio {
    my $request = shift;
    my $client = $request->client();

    unless ($client) {
        $request->setStatusBadDispatch();
        return;
    }

    my $url = Slim::Player::Playlist::url($client);
    unless ($url && $url =~ m{^ytmusic://(.+)$}) {
        $log->debug("cliTrackRadio: obecnie nie gra utwor ytmusic://");
        $request->setStatusDone();
        return;
    }
    my $videoId = $1;

    $request->setStatusProcessing();

    my $token = _nextQueueToken($client);

    my $radioUrl = "$BRIDGE/radio?video_id=$videoId&limit=25";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;

            unless (_isCurrentQueueToken($client, $token)) {
                $log->debug("cliTrackRadio: ignoruje przestarzala odpowiedz dla $videoId");
                $request->setStatusDone();
                return;
            }

            my $data = eval { from_json($http->content) };

            if ($@ || !$data || !$data->{tracks}) {
                $log->warn("cliTrackRadio: parse failed: $@");
                $request->setStatusDone();
                return;
            }

            my @tracks = grep { $_->{videoId} } @{ $data->{tracks} };
            if (@tracks && $tracks[0]->{videoId} eq $videoId) {
                shift @tracks; # get_watch_playlist zwraca seed jako pierwszy element
            }

            unless (@tracks) {
                $log->debug("cliTrackRadio: brak wynikow radia");
                $request->setStatusDone();
                return;
            }

            my @urls;
            for my $t (@tracks) {
                my $vid = $t->{videoId};
                push @urls, "ytmusic://$vid";

                my $artist = ref($t->{artists}) eq 'ARRAY' ? $t->{artists}[0]{name} : $t->{artist};
                my $thumb = _extractImage($t);

                Plugins::YTMusic::ProtocolHandler->setCachedMeta($vid, {
                    title => $t->{title},
                    artist => $artist,
                    duration => _parseLength($t->{length}) || $t->{duration} || $t->{length_seconds},
                    cover => $thumb || '',
                    icon => $thumb || '',
                    type => 'YouTube Music',
                });
            }

            # Biezacy utwor zostaje na poczatku, reszta kolejki zastapiona radiem
            Slim::Control::Request::executeRequest($client, ['playlist', 'clear']);
            Slim::Control::Request::executeRequest($client, ['playlist', 'add', $url]);
            $client->execute(['playlist', 'addtracks', 'listref', \@urls]);
            Slim::Control::Request::executeRequest($client, ['play']);

            $log->debug("cliTrackRadio: dodano " . scalar(@urls) . " utworow radia dla $videoId");
            $request->setStatusDone();
        },
        sub {
            $log->warn("cliTrackRadio: HTTP request failed");
            $request->setStatusDone();
        },
    )->get($radioUrl);
}

# ---------------------------------------------------------------------
# CLI: radio na bazie DOWOLNEGO video_id (np. z wynikow cliSearch)
# ---------------------------------------------------------------------
sub cliPlayRadio {
    my $request = shift;
    my $client = $request->client();

    unless ($client) {
        $request->setStatusBadDispatch();
        return;
    }

    my $videoId = $request->getParam('video_id') || $request->getParam('_video_id');

    unless ($videoId) {
        $videoId = $request->getRequest(2);
        if ($videoId && $videoId =~ m{^ytmusic://(.+)$}) {
            $videoId = $1;
        }
    }

    unless ($videoId) {
        $request->setStatusBadParams();
        return;
    }

    $request->setStatusProcessing();

    my $token = _nextQueueToken($client);

    my $seedUrl = "ytmusic://$videoId";
    my $radioUrl = "$BRIDGE/radio?video_id=$videoId&limit=25";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;

            unless (_isCurrentQueueToken($client, $token)) {
                $log->debug("cliPlayRadio: ignoruje przestarzala odpowiedz dla $videoId");
                $request->setStatusDone();
                return;
            }

            my $data = eval { from_json($http->content) };

            if ($@ || !$data || !$data->{tracks}) {
                $log->warn("cliPlayRadio: parse failed: $@");
                $request->setStatusDone();
                return;
            }

            my @tracks = grep { $_->{videoId} } @{ $data->{tracks} };
            if (@tracks && $tracks[0]->{videoId} eq $videoId) {
                shift @tracks;
            }

            my @urls = ($seedUrl);
            for my $t (@tracks) {
                my $vid = $t->{videoId};
                push @urls, "ytmusic://$vid";

                my $artist = ref($t->{artists}) eq 'ARRAY' ? $t->{artists}[0]{name} : $t->{artist};
                my $thumb = _extractImage($t);

                Plugins::YTMusic::ProtocolHandler->setCachedMeta($vid, {
                    title => $t->{title},
                    artist => $artist,
                    duration => _parseLength($t->{length}) || $t->{duration} || $t->{length_seconds},
                    cover => $thumb || '',
                    icon => $thumb || '',
                    type => 'YouTube Music',
                });
            }

            Slim::Control::Request::executeRequest($client, ['playlist', 'clear']);
            $client->execute(['playlist', 'addtracks', 'listref', \@urls]);
            Slim::Control::Request::executeRequest($client, ['play']);

            $log->debug("cliPlayRadio: odpalono radio dla $videoId, " . scalar(@urls) . " utworow");
            $request->setStatusDone();
        },
        sub {
            $log->warn("cliPlayRadio: HTTP request failed");
            $request->setStatusDone();
        },
    )->get($radioUrl);
}

# ---------------------------------------------------------------------
# Menu kontekstowe DOWOLNEGO utworu (biblioteka lokalna, Deezer, itd.) -
# link "Szukaj w YTMusic", analogicznie do "On Deezer"/"On YouTube" u innych.
# Celowo NIE pokazujemy tego dla wlasnych utworow ytmusic:// (tam juz sa
# akcje z trackInfoActionsMenu/trackInfoRadioMenu, w tym wlasne linki
# "Szukaj artystow/utworow" oparte na cache metadanych - patrz nizej).
# ---------------------------------------------------------------------
sub trackInfoCrossSearchMenu {
    my ($client, $url, $track, $remoteMeta) = @_;

    return undef if $url && $url =~ m{^ytmusic://};

    my $title = $remoteMeta->{title} || '';
    my $artist = $remoteMeta->{artist} || '';

    if (!$title && $track) {
        eval { $title = $track->title || ''; };
    }
    if (!$artist && $track) {
        eval {
            my $a = $track->artist;
            $artist = (ref($a) ? $a->name : $a) || '';
        };
    }

    return undef unless $title;

    my $query = $artist ? "$title $artist" : $title;

    return {
        name => sprintf(string('PLUGIN_YTMUSIC_SEARCH_QUERY') || "Szukaj \"%s\" w YTMusic", $query),
        type => 'link',
        url => \&handleSearch,
        passthrough => [{ search => $query }],
    };
}

# ---------------------------------------------------------------------
# Czyszczenie tytulu utworu do celow WYSZUKIWANIA (link "Szukaj utworow
# '...'" w trackInfoActionsMenu). Usuwa typowe dopiski YouTube w
# nawiasach/klamrach, ktore psuja wyniki wyszukiwania (np. tytul
# "Wojenka (official single)" w YTMusic zwraca gorsze/zerowe wyniki niz
# samo "Wojenka"). NIE dotyka to samego wyswietlanego tytulu utworu
# nigdzie indziej (np. "Teraz odtwarzane") - tylko lokalna kopia uzyta
# do budowania zapytania.
# ---------------------------------------------------------------------
sub _cleanSearchTitle {
    my ($title) = @_;
    return '' unless defined $title;

    my $clean = $title;
    $clean =~ s/\s*[\(\[][^\)\]]*\b(official|lyric|lyrics|audio|video|visualizer|remaster|remastered|hd|hq|4k|live)\b[^\)\]]*[\)\]]\s*/ /gi;
    $clean =~ s/^\s+|\s+$//g;
    $clean =~ s/\s{2,}/ /g;

    return $clean ne '' ? $clean : $title;
}

# ---------------------------------------------------------------------
# Menu kontekstowe utworu: Polub / Szybki zapis / Dodaj do playlisty... /
# Szukaj artystow.../Szukaj utworow... (analogicznie do "On Deezer" z
# pluginu Deezer, ale rozdzielone na dwa osobne linki - artysta i tytul -
# zamiast jednego zbiorczego zapytania).
#
# Tytul/artysta biezacego utworu bierzemy z WLASNEGO cache metadanych
# (ProtocolHandler::getCachedMeta), a nie z $remoteMeta - remoteMeta w
# LMS bywa czasem sformatowany inaczej niz surowe pola z bridge'a (np.
# zlaczony string "Tytul - Artysta"), a nasz cache zawiera dokladnie te
# same, rozdzielone pola co przy budowaniu radia/playlisty. remoteMeta
# jest tu tylko fallbackiem, gdyby z jakiegos powodu cache byl pusty.
#
# Tytul do samego LINKU wyszukiwania jest dodatkowo czyszczony przez
# _cleanSearchTitle z typowych dopiskow YouTube (official video itp.) -
# patrz komentarz przy tej funkcji. Nazwa utworu widoczna gdzie indziej
# (np. Teraz odtwarzane) NIE jest tym dotknieta.
# ---------------------------------------------------------------------
sub trackInfoActionsMenu {
    my ($client, $url, $track, $remoteMeta) = @_;

    return undef unless $url && $url =~ m{^ytmusic://(.+)$};
    my $videoId = $1;

    my $meta = Plugins::YTMusic::ProtocolHandler->getCachedMeta($videoId) || {};
    my $title = $meta->{title} || $remoteMeta->{title} || '';
    my $artist = $meta->{artist} || $remoteMeta->{artist} || '';

    # Fallback: remoteMeta->{artist} bywa sformatowany jako "Tytul - Artysta"
    # (np. gdy meta pochodzi z UI zamiast z wlasnego cache) - rozdzielamy.
    if ($artist && $title && $artist =~ /^\Q$title\E\s*-\s*(.+)$/) {
        $artist = $1;
    }

    my $searchTitle = _cleanSearchTitle($title);

    my @items = (
        {
            name => string('PLUGIN_YTMUSIC_LIKE_TRACK') || 'Polub ten utwor',
            type => 'link',
            url => \&handleLike,
            passthrough => [{ videoId => $videoId }],
        },
        {
            name => string('PLUGIN_YTMUSIC_QUICK_SAVE') || 'Szybki zapis (playlista "Zapisane z LMS")',
            type => 'link',
            url => \&handleQuickSave,
            passthrough => [{ videoId => $videoId }],
        },
        {
            name => string('PLUGIN_YTMUSIC_ADD_TO_PLAYLIST') || 'Dodaj do playlisty...',
            type => 'link',
            url => \&handleAddToPlaylistMenu,
            passthrough => [{ videoId => $videoId }],
        },
    );

    push @items, {
        name => sprintf(string('PLUGIN_YTMUSIC_SEARCH_ARTIST') || "Szukaj artystow '%s' w YTMusic", $artist),
        type => 'link',
        url => \&handleSearch,
        passthrough => [{ search => $artist }],
    } if $artist;

    push @items, {
        name => sprintf(string('PLUGIN_YTMUSIC_SEARCH_TRACK') || "Szukaj utworow '%s' w YTMusic", $searchTitle),
        type => 'link',
        url => \&handleSearch,
        passthrough => [{ search => $searchTitle }],
    } if $searchTitle;

    return {
        name => 'YTMusic',
        type => 'outline',
        items => \@items,
    };
}

sub handleLike {
    my ($client, $cb, $args, $passthrough) = @_;
    my $videoId = $passthrough->{videoId};

    my $url = "$BRIDGE/rate?video_id=$videoId&rating=LIKE";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_LIKED') || 'Polubiono!', type => 'text' }] });
        },
        sub {
            $log->warn("handleLike: HTTP request failed dla $videoId");
            $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ERR_AUTH_CHECK') || 'Blad - sprawdz czy jest skonfigurowany auth', type => 'text' }] });
        },
    )->get($url);
}

sub handleQuickSave {
    my ($client, $cb, $args, $passthrough) = @_;
    my $videoId = $passthrough->{videoId};

    my $url = "$BRIDGE/quick_save?video_id=$videoId";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_SAVED') || 'Zapisano!', type => 'text' }] });
        },
        sub {
            $log->warn("handleQuickSave: HTTP request failed dla $videoId");
            $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ERR_AUTH_CHECK') || 'Blad - sprawdz czy jest skonfigurowany auth', type => 'text' }] });
        },
    )->get($url);
}

sub handleAddToPlaylistMenu {
    my ($client, $cb, $args, $passthrough) = @_;
    my $videoId = $passthrough->{videoId};

    my $url = "$BRIDGE/playlists";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content) };

            if ($@ || !$data || !$data->{playlists}) {
                $log->warn("handleAddToPlaylistMenu: parse failed: $@");
                return $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ERR_FETCH_PLAYLISTS') || 'Blad pobierania playlist (auth?)', type => 'text' }] });
            }

            my @items = map {
                my $pl = $_;
                {
                    name => $pl->{title} || string('PLUGIN_YTMUSIC_PLAYLIST_FALLBACK') || 'Playlist',
                    type => 'link',
                    url => \&handleAddToPlaylistConfirm,
                    passthrough => [{ videoId => $videoId, playlistId => $pl->{playlistId} }],
                }
            } grep { $_->{playlistId} } @{ $data->{playlists} };

            unless (@items) {
                return $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_NO_PLAYLISTS') || 'Brak playlist w bibliotece', type => 'text' }] });
            }

            $cb->({ items => \@items });
        },
        sub {
            $log->warn("handleAddToPlaylistMenu: HTTP request failed");
            $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ERR_BRIDGE_CONNECTION') || 'Blad polaczenia z bridge', type => 'text' }] });
        },
    )->get($url);
}

sub handleAddToPlaylistConfirm {
    my ($client, $cb, $args, $passthrough) = @_;
    my $videoId = $passthrough->{videoId};
    my $playlistId = $passthrough->{playlistId};

    my $url = "$BRIDGE/playlist/$playlistId/add?video_id=$videoId";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ADDED_TO_PLAYLIST') || 'Dodano do playlisty!', type => 'text' }] });
        },
        sub {
            $log->warn("handleAddToPlaylistConfirm: HTTP request failed dla $videoId -> $playlistId");
            $cb->({ items => [{ name => string('PLUGIN_YTMUSIC_ERR_ADD_TO_PLAYLIST') || 'Blad dodawania do playlisty', type => 'text' }] });
        },
    )->get($url);
}

# ---------------------------------------------------------------------
# CLI: polub/zapisz aktualnie grany utwor
# ---------------------------------------------------------------------
sub cliLike {
    my $request = shift;
    my $client = $request->client();

    unless ($client) {
        $request->setStatusBadDispatch();
        return;
    }

    my $url = Slim::Player::Playlist::url($client);
    unless ($url && $url =~ m{^ytmusic://(.+)$}) {
        $log->debug("cliLike: obecnie nie gra utwor ytmusic://");
        $request->setStatusDone();
        return;
    }
    my $videoId = $1;

    $request->setStatusProcessing();

    my $rateUrl = "$BRIDGE/rate?video_id=$videoId&rating=LIKE";
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            $log->debug("cliLike: polubiono $videoId");
            $request->setStatusDone();
        },
        sub {
            $log->warn("cliLike: HTTP request failed dla $videoId");
            $request->setStatusDone();
        },
    )->get($rateUrl);
}

sub cliSave {
    my $request = shift;
    my $client = $request->client();

    unless ($client) {
        $request->setStatusBadDispatch();
        return;
    }

    my $url = Slim::Player::Playlist::url($client);
    unless ($url && $url =~ m{^ytmusic://(.+)$}) {
        $log->debug("cliSave: obecnie nie gra utwor ytmusic://");
        $request->setStatusDone();
        return;
    }
    my $videoId = $1;

    $request->setStatusProcessing();

    my $saveUrl = "$BRIDGE/quick_save?video_id=$videoId";
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            $log->debug("cliSave: zapisano $videoId");
            $request->setStatusDone();
        },
        sub {
            $log->warn("cliSave: HTTP request failed dla $videoId");
            $request->setStatusDone();
        },
    )->get($saveUrl);
}

# ---------------------------------------------------------------------
# CLI: lista playlist z biblioteki
# ---------------------------------------------------------------------
sub cliPlaylists {
    my $request = shift;

    if ($request->isNotQuery([['ytmusic'], ['playlists']])) {
        $request->setStatusBadDispatch();
        return;
    }

    $request->setStatusProcessing();

    my $url = "$BRIDGE/playlists";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content) };

            if ($@ || !$data || !$data->{playlists}) {
                $log->warn("cliPlaylists: parse failed: $@");
                $request->addResult('count', 0);
                $request->setStatusDone();
                return;
            }

            my $i = 0;
            for my $pl (grep { $_->{playlistId} } @{ $data->{playlists} }) {
                $request->addResultLoop('item_loop', $i, 'title', $pl->{title} || 'Playlist');
                $request->addResultLoop('item_loop', $i, 'playlist_id', $pl->{playlistId});
                $request->addResultLoop('item_loop', $i, 'image', _extractImage($pl) || '');
                $i++;
            }

            $request->addResult('count', $i);
            $request->setStatusDone();
        },
        sub {
            $log->warn("cliPlaylists: HTTP request failed");
            $request->addResult('count', 0);
            $request->setStatusDone();
        },
    )->get($url);
}

# ---------------------------------------------------------------------
# CLI: plaska lista WSZYSTKICH rekomendowanych playlist z "Polecane"
# ---------------------------------------------------------------------
sub cliHomePlaylists {
    my $request = shift;

    if ($request->isNotQuery([['ytmusic'], ['homeplaylists']])) {
        $request->setStatusBadDispatch();
        return;
    }

    $request->setStatusProcessing();

    my %SKIP_SECTIONS = map { $_ => 1 } ('From your library', 'Z Twojej biblioteki');

    _fetchHomeData(sub {
        my ($data) = @_;

        if (!$data || !$data->{sections}) {
            $log->debug("cliHomePlaylists: brak danych");
            $request->addResult('count', 0);
            $request->setStatusDone();
            return;
        }

        my $i = 0;
        my %seen;
        for my $section (@{ $data->{sections} }) {
            next if $SKIP_SECTIONS{$section->{title} || ''};
            for my $c (@{ $section->{contents} || [] }) {
                next unless $c->{playlistId};
                next if $c->{videoId}; # to auto-radio utworu, nie prawdziwa playlista
                next if $seen{$c->{playlistId}}++;

                $request->addResultLoop('item_loop', $i, 'title', $c->{title} || 'Playlist');
                $request->addResultLoop('item_loop', $i, 'playlist_id', $c->{playlistId});
                $request->addResultLoop('item_loop', $i, 'section', $section->{title} || '');
                $request->addResultLoop('item_loop', $i, 'image', _extractImage($c) || '');
                $i++;
            }
        }

        $request->addResult('count', $i);
        $request->setStatusDone();
    });
}

# ---------------------------------------------------------------------
# CLI: zawartosc konkretnej playlisty
# ---------------------------------------------------------------------
sub cliPlaylistTracks {
    my $request = shift;

    if ($request->isNotQuery([['ytmusic'], ['playlisttracks']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $playlistId = $request->getParam('playlist_id') || $request->getRequest(2);
    unless ($playlistId) {
        $request->setStatusBadParams();
        return;
    }

    $request->setStatusProcessing();

    _fetchPlaylistData($playlistId, sub {
        my ($data) = @_;

        if (!$data || !$data->{tracks}) {
            $log->debug("cliPlaylistTracks: brak danych dla $playlistId");
            $request->addResult('count', 0);
            $request->setStatusDone();
            return;
        }

        my $i = 0;
        for my $t (grep { $_->{videoId} } @{ $data->{tracks} }) {
            my $artist = ref($t->{artists}) eq 'ARRAY' ? $t->{artists}[0]{name} : $t->{artist};

            $request->addResultLoop('item_loop', $i, 'title', $t->{title} || 'Unknown');
            $request->addResultLoop('item_loop', $i, 'artist', $artist || '');
            $request->addResultLoop('item_loop', $i, 'url', 'ytmusic://' . $t->{videoId});
            $request->addResultLoop('item_loop', $i, 'image', _extractImage($t) || '');
            $i++;
        }

        $request->addResult('count', $i);
        $request->setStatusDone();
    });
}

# ---------------------------------------------------------------------
# Wspolny helper: pobiera tracklist playlisty z bridge'a, buduje liste
# URL-i ytmusic:// i wypelnia cache metadanych (jak przy radiu).
# ---------------------------------------------------------------------
sub _fetchPlaylistUrls {
    my ($playlistId, $done) = @_;

    _fetchPlaylistData($playlistId, sub {
        my ($data) = @_;

        if (!$data || !$data->{tracks}) {
            $log->debug("_fetchPlaylistUrls: brak danych dla $playlistId");
            return $done->([]);
        }

        my @urls;
        for my $t (grep { $_->{videoId} } @{ $data->{tracks} }) {
            my $vid = $t->{videoId};
            push @urls, "ytmusic://$vid";

            my $artist = ref($t->{artists}) eq 'ARRAY' ? $t->{artists}[0]{name} : $t->{artist};
            my $thumb = _extractImage($t);

            # WAZNE: /playlist (ytmusicapi get_playlist()) zwraca inny ksztalt
            # niz /radio (get_watch_playlist()) - tu dlugosc utworu jest w polach
            # "duration" (string "3:45") i "duration_seconds" (int), NIE w
            # "length"/"length_seconds" jak przy radiu.
            Plugins::YTMusic::ProtocolHandler->setCachedMeta($vid, {
                title => $t->{title},
                artist => $artist,
                duration => $t->{duration_seconds} || _parseLength($t->{duration}) || _parseLength($t->{length}) || $t->{length_seconds},
                cover => $thumb || '',
                icon => $thumb || '',
                type => 'YouTube Music',
            });
        }

        my @videoIdsInOrder = map { /^ytmusic:\/\/(.+)$/ ? $1 : () } @urls;
        _prefetchGain(@videoIdsInOrder[0 .. min($#videoIdsInOrder, $GAIN_PREFETCH_AHEAD - 1)]);

        $done->(\@urls);
    });
}

# ---------------------------------------------------------------------
# CLI: zagraj cala playliste od razu (czysci kolejke, dodaje wszystkie, play)
# ---------------------------------------------------------------------
sub cliPlayPlaylist {
    my $request = shift;
    my $client = $request->client();

    unless ($client) {
        $request->setStatusBadDispatch();
        return;
    }

    my $playlistId = $request->getParam('playlist_id') || $request->getRequest(2);
    unless ($playlistId) {
        $request->setStatusBadParams();
        return;
    }

    $request->setStatusProcessing();

    my $token = _nextQueueToken($client);

    _fetchPlaylistUrls($playlistId, sub {
        my ($urls) = @_;

        unless (_isCurrentQueueToken($client, $token)) {
            $log->debug("cliPlayPlaylist: ignoruje przestarzala odpowiedz dla $playlistId");
            $request->setStatusDone();
            return;
        }

        unless (@$urls) {
            $log->debug("cliPlayPlaylist: brak utworow dla $playlistId");
            $request->setStatusDone();
            return;
        }

        Slim::Control::Request::executeRequest($client, ['playlist', 'clear']);
        $client->execute(['playlist', 'addtracks', 'listref', $urls]);
        Slim::Control::Request::executeRequest($client, ['play']);

        $log->debug("cliPlayPlaylist: zagrano " . scalar(@$urls) . " utworow z $playlistId");
        $request->setStatusDone();
    });
}

# ---------------------------------------------------------------------
# CLI: dopisz cala playliste na koniec biezacej kolejki (bez czyszczenia/play)
# ---------------------------------------------------------------------
sub cliAddPlaylist {
    my $request = shift;
    my $client = $request->client();

    unless ($client) {
        $request->setStatusBadDispatch();
        return;
    }

    my $playlistId = $request->getParam('playlist_id') || $request->getRequest(2);
    unless ($playlistId) {
        $request->setStatusBadParams();
        return;
    }

    $request->setStatusProcessing();

    _fetchPlaylistUrls($playlistId, sub {
        my ($urls) = @_;
        unless (@$urls) {
            $log->debug("cliAddPlaylist: brak utworow dla $playlistId");
            $request->setStatusDone();
            return;
        }

        $client->execute(['playlist', 'addtracks', 'listref', $urls]);

        $log->debug("cliAddPlaylist: dopisano " . scalar(@$urls) . " utworow z $playlistId");
        $request->setStatusDone();
    });
}

# ---------------------------------------------------------------------
# Wspolny helper: buduje liste URL-i ytmusic:// z pojedynczych utworow
# BEZPOSREDNIO nalezacych do sekcji "Polecane" (np. "Your daily discover")
# ---------------------------------------------------------------------
sub _fetchHomeSectionTrackUrls {
    my ($sectionTitle, $done) = @_;

    _fetchHomeData(sub {
        my ($data) = @_;

        if (!$data || !$data->{sections}) {
            $log->debug("_fetchHomeSectionTrackUrls: brak danych dla '$sectionTitle'");
            return $done->([]);
        }

        my ($section) = grep { ($_->{title} || '') eq $sectionTitle } @{ $data->{sections} };
        unless ($section) {
            $log->debug("_fetchHomeSectionTrackUrls: sekcja '$sectionTitle' nie znaleziona (odswiez Polecane?)");
            return $done->([]);
        }

        my @urls;
        my %seen;
        for my $t (@{ $section->{contents} || [] }) {
            next unless $t->{videoId};
            next if $seen{$t->{videoId}}++;

            my $vid = $t->{videoId};
            push @urls, "ytmusic://$vid";

            my $artist = ref($t->{artists}) eq 'ARRAY' ? $t->{artists}[0]{name} : $t->{artist};
            my $thumb = _extractImage($t);

            Plugins::YTMusic::ProtocolHandler->setCachedMeta($vid, {
                title => $t->{title},
                artist => $artist,
                duration => $t->{duration_seconds} || _parseLength($t->{duration}) || _parseLength($t->{length}) || $t->{length_seconds},
                cover => $thumb || '',
                icon => $thumb || '',
                type => 'YouTube Music',
            });
        }

        my @videoIdsInOrder = map { /^ytmusic:\/\/(.+)$/ ? $1 : () } @urls;
        _prefetchGain(@videoIdsInOrder[0 .. min($#videoIdsInOrder, $GAIN_PREFETCH_AHEAD - 1)]);

        $done->(\@urls);
    });
}

# ---------------------------------------------------------------------
# CLI: zagraj od razu wszystkie pojedyncze utwory z "plaskiej" sekcji Polecane
# ---------------------------------------------------------------------
sub cliPlayHomeSection {
    my $request = shift;
    my $client = $request->client();

    unless ($client) {
        $request->setStatusBadDispatch();
        return;
    }

    my $sectionTitle = $request->getParam('section') || $request->getRequest(2);
    unless (defined $sectionTitle && length($sectionTitle)) {
        $request->setStatusBadParams();
        return;
    }

    $request->setStatusProcessing();

    my $token = _nextQueueToken($client);

    _fetchHomeSectionTrackUrls($sectionTitle, sub {
        my ($urls) = @_;

        unless (_isCurrentQueueToken($client, $token)) {
            $log->debug("cliPlayHomeSection: ignoruje przestarzala odpowiedz dla '$sectionTitle'");
            $request->setStatusDone();
            return;
        }

        unless (@$urls) {
            $log->debug("cliPlayHomeSection: brak utworow dla sekcji '$sectionTitle'");
            $request->setStatusDone();
            return;
        }

        Slim::Control::Request::executeRequest($client, ['playlist', 'clear']);
        $client->execute(['playlist', 'addtracks', 'listref', $urls]);
        Slim::Control::Request::executeRequest($client, ['play']);

        $log->debug("cliPlayHomeSection: zagrano " . scalar(@$urls) . " utworow z sekcji '$sectionTitle'");
        $request->setStatusDone();
    });
}

# ---------------------------------------------------------------------
# CLI: dopisz wszystkie pojedyncze utwory z "plaskiej" sekcji Polecane
# ---------------------------------------------------------------------
sub cliAddHomeSection {
    my $request = shift;
    my $client = $request->client();

    unless ($client) {
        $request->setStatusBadDispatch();
        return;
    }

    my $sectionTitle = $request->getParam('section') || $request->getRequest(2);
    unless (defined $sectionTitle && length($sectionTitle)) {
        $request->setStatusBadParams();
        return;
    }

    $request->setStatusProcessing();

    _fetchHomeSectionTrackUrls($sectionTitle, sub {
        my ($urls) = @_;

        unless (@$urls) {
            $log->debug("cliAddHomeSection: brak utworow dla sekcji '$sectionTitle'");
            $request->setStatusDone();
            return;
        }

        $client->execute(['playlist', 'addtracks', 'listref', $urls]);

        $log->debug("cliAddHomeSection: dopisano " . scalar(@$urls) . " utworow z sekcji '$sectionTitle'");
        $request->setStatusDone();
    });
}

1;
