package Plugins::YTMusic::ProtocolHandler;
use strict;
use base qw(Slim::Player::Protocols::HTTP);

use JSON::XS::VersionOneAndTwo;
use List::Util qw(min);
use LWP::Simple qw($ua get);
use Slim::Player::Client;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::OSDetect;
use File::Spec::Functions qw(catdir catfile);
use File::Path qw(make_path);

# Krotki, jawny timeout - bez tego domyslny LWP::Simple moze wisiec
# zbyt dlugo przy chwilowym obciazeniu bridge'a, co posrednio prowadzi
# do nieustawienia duration (patrz nizej) i bledow w UI/wznawianiu.
$ua->timeout(5);

my $log = logger('plugin.ytmusic');

# ---------------------------------------------------------------------
# JEDYNE miejsce definiujace port/URL bridge'a w calej wtyczce.
# Plugin.pm (startBridge, prefetch) i DontStopTheMusic.pm importuja
# te wartosci przez bridgeUrl()/bridgePort() zamiast trzymac wlasna,
# osobna kopie stalej "http://127.0.0.1:8008" - to bylo zrodlem
# potencjalnego rozjazdu, jesli port zmienilby sie w jednym miejscu,
# a nie w drugim.
# ---------------------------------------------------------------------
my $BRIDGE_PORT = 8008;
my $BRIDGE = "http://127.0.0.1:$BRIDGE_PORT";

sub bridgePort { return $BRIDGE_PORT; }
sub bridgeUrl { return $BRIDGE; }

# ---------------------------------------------------------------------
# Rankingi jakosci pomiaru gainu - MUSZA byc zgodne 1:1 z QUALITY_RANK
# w ytmusic_bridge.py. 'quick' < 'half' < 'full'. Uzywane WSZEDZIE,
# gdzie porownujemy "czy juz mamy wystarczajaco dobry gain" (lokalnie
# w Perlu) - patrz onStream, Plugin.pm::_onNewSong/_deepAnalysisFire/
# _prefetchGain. Bez tego lokalny cache w Perlu nie wie, kiedy dany
# utwor JUZ ma satysfakcjonujacy gain, i planuje/wysyla kolejne,
# calkowicie zbedne zapytania o gleboka analize przy KAZDYM odtworzeniu
# tego samego utworu, nawet gdy bridge i tak odpowie natychmiast z
# wlasnego cache (bez realnej analizy) - stad wrazenie "chaosu" w logach.
# ---------------------------------------------------------------------
use constant QUALITY_RANK => { quick => 0, half => 1, full => 2 };

sub qualityRank {
    my ($class, $quality) = @_;
    return QUALITY_RANK->{ $quality // '' } // 0;
}

# Wylacznik funkcji replay gain - ustaw na 0 zeby wylaczyc bez zmiany kodu
# i bez restartu serwera (preferencja czytana na zywo przy kazdym onStream).
# Domyslnie wlaczone. NADRZEDNY wobec WSZYSTKICH mechanizmow nizej -
# gdy wylaczony, ani prefetch, ani onStream, ani gleboka analiza nigdy
# nie wywoluja bridge'a.

# replaygain_min_volume: dodatkowy auto-wylacznik wg glosnosci. 0 = wylaczony
# (gain liczony zawsze, jak dawniej). >0 = gain liczony TYLKO gdy przynajmniej
# jeden podlaczony gracz ma glosnosc powyzej tej wartosci - przy cichym
# sluchaniu w tle precyzyjny replay gain i tak nie ma duzego znaczenia
# sluchowo. Dotyczy TYLKO blokujacego fallbacku w onStream - gleboka
# analiza (nizej) go ignoruje.

# ---------------------------------------------------------------------
# GLEBOKA ANALIZA GAINU - dwie NIEZALEZNE osie konfiguracji (patrz
# Plugin.pm::_onNewSong/_deepAnalysisFire i docstring w ytmusic_bridge.py):
#
# - gain_deep_analysis_percent: KIEDY odpalic - po ilu % odsluchanej
#   dlugosci utworu (nie sekund!) uznajemy, ze user "faktycznie sluchal"
#   i warto poprawic gain w cache na przyszlosc. Domyslnie 85.
#
# - gain_deep_analysis_mode: JAK GLEBOKO analizowac, gdy powyzszy prog
#   zostanie przekroczony:
#     'quick' - NIE poglebiaj analizy (efektywnie wylacza mechanizm -
#               utwor zostaje z gainem policzonym z pierwszych 25s,
#               tak jak przy prefetchu/onStream fallback)
#     'half'  - analiza pierwszej polowy utworu
#     'full'  - analiza calego utworu (najdokladniejsze)
#   Domyslnie 'full'.
#
# Prefetch "N do przodu" (Plugin.pm::_prefetchGain) i blokujacy fallback
# w onStream() przy cache miss ZAWSZE uzywaja mode='quick' (pierwsze 25s),
# NIEZALEZNIE od gain_deep_analysis_mode - to sa zapytania spekulacyjne/
# czasowo-krytyczne (patrz komentarze w Plugin.pm i onStream nizej), gdzie
# drozszy tryb bylby marnotrawstwem CPU albo zauwazalnym zawieszeniem
# startu odtwarzania.
# ---------------------------------------------------------------------
my $prefs = preferences('plugin.ytmusic');
$prefs->init({
    replaygain_enabled => 1,
    replaygain_min_volume => 0,
    gain_deep_analysis_percent => 85,
    gain_deep_analysis_mode => 'full',
});

our %metaCache;

# ---------------------------------------------------------------------
# PERSYSTENCJA %metaCache NA DYSK - TYLKO tytul/artysta/duration/okladka
# (pola "opisowe", ktore NIGDY sie nie zmieniaja dla danego video_id).
#
# Bez tego, po KAZDYM restarcie LMS, przywrocenie zapisanej kolejki
# odtwarzania (dla kazdego podlaczonego gracza) wymusza getMetadataFor()
# -> pelne zapytanie HTTP do bridge'a dla KAZDEGO utworu w tej kolejce,
# SEKWENCYJNIE i BLOKUJACO (LWP::Simple), zanim bridge nawet zdazy
# wystartowac.
#
# WAZNE: pola replaygain_track_gain/replaygain_quality NIE SA
# persystowane na dysk (patrz _loadMetaCacheFromDisk - usuwamy je z
# kazdego wczytanego wpisu). Gain ma JEDNO zrodlo prawdy:
# ytmusic_gain_cache.json po stronie bridge'a. Jesli zamrozilibysmy
# lokalnie ostatnia znana wartosc/jakosc gainu miedzy sesjami LMS,
# a bridge miedzy tymi sesjami zdazyl podniesc jakosc (np. gleboka
# analiza tuz przed restartem), to zamrozona, PRZESTARZALA wartosc
# przykrylaby na trwale lepsza, juz obliczona przez bridge - onStream()
# nigdy by juz nie sprawdzil bridge'a, bo lokalny cache "juz ma jakas
# wartosc" (patrz "unless (defined $gain)" w onStream nizej). Usuwajac
# te dwa pola przy kazdym starcie, wymuszamy jedno, tanie zapytanie
# cache_only=1 do bridge'a przy pierwszym onStream po restarcie -
# ktore i tak zawsze zwroci najnowsza, poprawna wartosc.
#
# BEZ autosave - to jest tylko cache wydajnosciowy (nie trwaly magazyn
# danych), wiec zapis na dysk odbywa sie WYLACZNIE explicit, przy
# normalnym zamknieciu LMS (patrz flushMetaCache, wolane z
# Plugin.pm::shutdownPlugin).
# ---------------------------------------------------------------------
my $METACACHE_DIR = catdir(Slim::Utils::OSDetect::dirsFor('cache'), 'YTMusic');
my $METACACHE_FILE = catfile($METACACHE_DIR, 'metacache.json');
use constant METACACHE_MAX_ENTRIES => 2000; # ochrona przed nieograniczonym rozrostem

sub _loadMetaCacheFromDisk {
    return unless -f $METACACHE_FILE;

    my $json;
    eval {
        open(my $fh, '<:encoding(UTF-8)', $METACACHE_FILE) or die $!;
        local $/;
        $json = <$fh>;
        close $fh;
    };
    if ($@ || !$json) {
        $log->warn("YTMusic: nie udalo sie wczytac metaCache z dysku: " . ($@ || 'brak danych'));
        return;
    }

    my $data = eval { from_json($json) };
    if ($@ || ref($data) ne 'HASH') {
        $log->warn("YTMusic: plik metaCache na dysku uszkodzony/niepoprawny, ignoruje");
        return;
    }

    %metaCache = %$data;

    # Patrz duzy komentarz wyzej - gain/quality maja jedno zrodlo prawdy
    # (bridge), nigdy nie persystujemy ich lokalnie na dysk.
    for my $meta (values %metaCache) {
        delete $meta->{replaygain_track_gain};
        delete $meta->{replaygain_quality};
    }

    $log->info("YTMusic: wczytano " . scalar(keys %metaCache) . " wpisow metaCache z dysku ($METACACHE_FILE) - gain wymuszony do ponownego sprawdzenia");
}

# Publiczne API dla Plugin.pm (shutdownPlugin) - jedyny moment, w ktorym
# metaCache jest zapisywany na dysk.
sub flushMetaCache {
    my ($class) = @_;

    # Ochrona przed nieograniczonym rozrostem pliku - jesli cache
    # przekroczyl limit, obcinamy go. Prosta heurystyka (kolejnosc
    # hashu nie jest gwarantowana wg czasu dodania), ale wystarczajaca
    # - to tylko cache wydajnosciowy, nie trwaly magazyn danych.
    if (scalar(keys %metaCache) > METACACHE_MAX_ENTRIES) {
        my @keys = keys %metaCache;
        my $toRemove = scalar(@keys) - METACACHE_MAX_ENTRIES;
        delete $metaCache{$_} for @keys[0 .. $toRemove - 1];
        $log->debug("YTMusic: metaCache przekroczyl " . METACACHE_MAX_ENTRIES . " wpisow, obcieto $toRemove najstarszych");
    }

    eval {
        make_path($METACACHE_DIR) unless -d $METACACHE_DIR;
        open(my $fh, '>:encoding(UTF-8)', $METACACHE_FILE) or die $!;
        print $fh to_json(\%metaCache);
        close $fh;
    };
    if ($@) {
        $log->warn("YTMusic: nie udalo sie zapisac metaCache na dysk: $@");
        return;
    }

    $log->debug("YTMusic: zapisano " . scalar(keys %metaCache) . " wpisow metaCache na dysk");
}

# Wczytujemy cache z dysku OD RAZU przy zaladowaniu tego modulu - czyli
# zanim Plugin.pm zdazy nawet odpalic _startBridge().
_loadMetaCacheFromDisk();

# Tymczasowe (do restartu LMS) nadpisanie glownego wlacznika gainu -
# ustawiane WYLACZNIE przez CLI 'ytmusic replaygain' (patrz cliReplayGain
# w Plugin.pm), np. z automatyzacji Home Assistant. Celowo NIE jest
# zapisywane do prefs - po restarcie LMS wraca do wartosci ustawionej
# na stale w Settings > YTMusic. undef = brak override, uzywana jest
# normalnie wartosc z prefs (jak dotychczas).
my $runtimeGainOverride;

sub setReplayGainRuntimeOverride {
    my ($class, $value) = @_;

    if (!defined $value || $value eq '') {
        $runtimeGainOverride = undef;
        $log->warn("YTMusic: usunieto tymczasowy override gainu, wracam do ustawien z prefs");
    }
    else {
        $runtimeGainOverride = $value ? 1 : 0;
        $log->warn("YTMusic: tymczasowy override gainu = $runtimeGainOverride (obowiazuje do restartu LMS)");
    }
    return $runtimeGainOverride;
}

sub replayGainRuntimeOverride {
    return $runtimeGainOverride;
}

sub replayGainPersistedEnabled {
    return $prefs->get('replaygain_enabled') ? 1 : 0;
}

# Analogiczny mechanizm dla progu glosnosci (replaygain_min_volume) - patrz
# komentarz przy $runtimeGainOverride wyzej. Pozwala np. tymczasowo wymusic
# "licz gain zawsze, niezaleznie od glosnosci" (0) na noc, bez zmiany
# ustawienia na stale w Settings > YTMusic.
my $runtimeMinVolumeOverride;

sub setReplayGainMinVolumeOverride {
    my ($class, $value) = @_;

    if (!defined $value || $value eq '') {
        $runtimeMinVolumeOverride = undef;
        $log->warn("YTMusic: usunieto tymczasowy override progu glosnosci, wracam do ustawien z prefs");
    }
    elsif ($value !~ /^\d+$/) {
        $log->warn("YTMusic: nieprawidlowa wartosc override progu glosnosci '$value' - ignoruje");
    }
    else {
        $runtimeMinVolumeOverride = min($value + 0, 100);
        $log->warn("YTMusic: tymczasowy override progu glosnosci = $runtimeMinVolumeOverride (obowiazuje do restartu LMS)");
    }
    return $runtimeMinVolumeOverride;
}

sub replayGainMinVolumeOverride {
    return $runtimeMinVolumeOverride;
}

sub replayGainPersistedMinVolume {
    return $prefs->get('replaygain_min_volume') || 0;
}

# Pozwala innym modulom (np. Plugin.pm przy dodawaniu radia do playlisty)
# od razu wypelnic cache metadanych, zeby getMetadataFor nie musial
# odpytywac bridge'a/yt-dlp osobno dla kazdego utworu.
sub setCachedMeta {
    my ($class, $videoId, $meta) = @_;
    return unless $videoId && $meta;
    $metaCache{$videoId} = $meta;
}

# Publiczny odczyt cache metadanych (np. Plugin.pm potrzebuje znac
# dlugosc utworu, zeby przeliczyc prog % na sekundy dla timera glebokiej
# analizy, oraz znana jakosc gainu, zeby zdecydowac czy WARTO w ogole
# planowac gleboka analize - patrz Plugin.pm::_onNewSong).
sub getCachedMeta {
    my ($class, $videoId) = @_;
    return $metaCache{$videoId};
}

# Publiczny, wspolny warunek "czy w ogole warto teraz liczyc/prefetchowac
# gain" - uzywany zarowno tutaj (onStream), jak i przez Plugin.pm (prefetch
# przy zmianie utworu / playradio / playplaylist), zeby wszystkie miejsca
# respektowaly TE SAMA logike, bez duplikowania jej w dwoch plikach.

# Publiczny warunek "czy glowny wylacznik gainu jest wlaczony" (override z CLI
# lub, w jego braku, preferencja z Settings) - BEZ progu glosnosci. To jest
# twardy wylacznik: gdy wylaczony, gain jest pomijany calkowicie, nawet jesli
# wartosc jest juz tanio dostepna w cache (patrz onStream nizej).
sub replayGainMasterEnabled {
    my ($class) = @_;
    return defined($runtimeGainOverride) ? $runtimeGainOverride : $prefs->get('replaygain_enabled');
}

# Publiczny warunek progu glosnosci - zaklada, ze replayGainMasterEnabled()
# jest juz sprawdzone osobno. Odpowiada tylko na pytanie "czy WARTO liczyc
# NOWA wartosc gainu teraz" (ciezka operacja: pelna ekstrakcja yt-dlp + do
# 20s loudnorm w ffmpeg) - nie dotyczy zastosowania juz znanej wartosci,
# co jest tanie i powinno dzialac niezaleznie od progu (patrz onStream).

# $client jest opcjonalny - jesli podany, sprawdzany jest w pierwszej
# kolejnosci (np. przy realnym onStream wiadomo ktory gracz faktycznie
# gra), ale "dowolny inny gracz gra glosno" tez wystarcza (patrz komentarz
# przy replaygain_min_volume) - stad dodatkowe przejscie po wszystkich
# podlaczonych graczach.
sub replayGainVolumeOk {
    my ($class, $client) = @_;

    my $minVolume = defined($runtimeMinVolumeOverride) ? $runtimeMinVolumeOverride : ($prefs->get('replaygain_min_volume') || 0);
    return 1 unless $minVolume > 0; # auto-wylacznik wg glosnosci nieaktywny

    return 1 if $client && _clientLoudEnough($client, $minVolume);

    for my $c (Slim::Player::Client::clients()) {
        if (_clientLoudEnough($c, $minVolume)) {
            $log->debug("YTMusic: replayGainVolumeOk - " . $c->name . " glosnosc="
                . (eval { $c->volume() } // 'undef') . " > $minVolume, liczenie gainu ma sens");
            return 1;
        }
    }
    $log->debug("YTMusic: replayGainVolumeOk - zaden gracz nie przekracza progu $minVolume, liczenie gainu pominiete");
    return 0;
}

# Zachowane dla wstecznej zgodnosci / uzycia w Plugin.pm (prefetch) - tam
# nie ma sensu rozdzielac na "tanio/drogo", bo prefetch z zalozenia ZAWSZE
# liczy nowa wartosc (to jego jedyny cel), wiec oba warunki musza byc
# spelnione razem.
sub replayGainShouldRun {
    my ($class, $client) = @_;
    return 0 unless $class->replayGainMasterEnabled();
    return $class->replayGainVolumeOk($client);
}

# ---------------------------------------------------------------------
# Publiczne akcesory dla glebokiej analizy gainu - patrz Plugin.pm
# (_onNewSong/_deepAnalysisFire) i docstring przy $prefs->init wyzej.
# ---------------------------------------------------------------------

# 'quick' (=25s, brak pogłębiania - mechanizm efektywnie wylaczony),
# 'half' (pierwsza polowa utworu) albo 'full' (caly utwor). Domyslnie
# 'full'.
sub deepAnalysisMode {
    my ($class) = @_;
    my $mode = $prefs->get('gain_deep_analysis_mode') || 'full';
    return $mode if $mode eq 'quick' || $mode eq 'half';
    return 'full';
}

# Wygodny, wyprowadzony warunek: gleboka analiza ma jakikolwiek sens
# TYLKO gdy mode != 'quick' (bo 'quick' to ten sam wynik co juz mamy z
# prefetcha/onStream) ORAZ gdy glowny wylacznik gainu jest wlaczony
# (replayGainMasterEnabled) - bez sensu planowac/wykonywac pogłębianie
# gainu, ktory i tak nigdy nie zostanie zastosowany.
sub deepAnalysisEnabled {
    my ($class) = @_;
    return 0 unless $class->replayGainMasterEnabled();
    return $class->deepAnalysisMode() ne 'quick' ? 1 : 0;
}

# Prog odsluchania w % dlugosci utworu (1-100), po przekroczeniu ktorego
# Plugin.pm zamawia gleboka analize. Liczone wzgledem REALNEGO czasu
# odtwarzania (nie zegara sciennego od 'newsong') - patrz
# Plugin.pm::_deepAnalysisFire, ktory doplanowuje timer jesli w
# miedzyczasie user zapauzowal odtwarzanie.
sub deepAnalysisPercent {
    my ($class) = @_;
    my $pct = $prefs->get('gain_deep_analysis_percent');
    $pct = 85 unless defined $pct && $pct =~ /^\d+$/;
    $pct = 1 if $pct < 1;
    $pct = 100 if $pct > 100;
    return $pct;
}

sub _clientLoudEnough {
    my ($client, $minVolume) = @_;
    return 0 unless $client;

    # Wylaczony/uspiony gracz nie powinien "liczyc sie" do progu, nawet jesli
    # zglasza wysoka glosnosc (np. sprzet z Fixed Volume albo po prostu
    # zapamietana ostatnia wartosc sprzed wylaczenia) - liczy sie tylko
    # realnie wlaczony gracz.
    my $powered = eval { $client->power() };
    return 0 unless defined($powered) && $powered;

    my $vol = eval { $client->volume() };
    return defined($vol) && $vol > $minVolume;
}

sub _videoId {
    my $url = shift;
    $url =~ m{^ytmusic://(.+)$};
    return $1;
}

# ---------------------------------------------------------------------
# LEKKI fetch - TYLKO /metadata (szybkie, ytmusicapi, bez yt-dlp/ffmpeg).
# Uzywany w new(), bo new() jest wolane przez LMS przy prebufferingu/
# skanowaniu CALEJ playlisty (nie tylko przy realnym starcie odtwarzania
# danego utworu) - musi byc szybki, inaczej dla dlugiej playlisty po
# restarcie LMS blokuje sie na serii ciezkich wywolan zamiast jednego
# lekkiego zapytania per utwor. Wynik ladowany jest do %metaCache, ktora
# jest persystowana na dysk WYLACZNIE przy shutdownPlugin (bez pol
# gain/quality - patrz duzy komentarz przy _loadMetaCacheFromDisk).
# ---------------------------------------------------------------------
sub _fetchLightMeta {
    my ($videoId) = @_;

    my $json = LWP::Simple::get("$BRIDGE/metadata?video_id=$videoId");
    return undef unless $json;

    my $data = eval { from_json($json) };
    if ($@ || !$data) {
        $log->warn("YTMusic: nie udalo sie sparsowac metadanych dla $videoId");
        return undef;
    }

    return {
        title => $data->{title},
        artist => $data->{artist},
        duration => $data->{duration},
        cover => $data->{thumbnail} || '',
        icon => $data->{thumbnail} || '',
        type => 'YouTube Music',
    };
}

# ---------------------------------------------------------------------
# CIEZKI fetch gainu - /gain moze wywolac pelna ekstrakcje yt-dlp +
# analize loudnorm przez ffmpeg przy cache miss (patrz bridge). Wolamy to
# WYLACZNIE z onStream() (tuz przed realnym odtworzeniem KONKRETNEGO
# utworu, ZAWSZE z mode='quick' - patrz docstring przy $prefs->init wyzej)
# i z getMetadataFor() (leniwie, na potrzeby UI) - NIGDY z new(), ktore
# jest wolane dla calej kolejki na starcie/prebufferze.
#
# Zwraca hashref { gain => float, quality => 'quick'|'half'|'full' } albo
# undef przy porazce. Jawne przenoszenie 'quality' z odpowiedzi bridge'a
# jest kluczowe - bez tego lokalny cache w Perlu nie wiedzialby, jaka
# jakosc gainu juz ma dany utwor, i planowalby/wysylal kolejne, zbedne
# zapytania o gleboka analize przy kazdym odtworzeniu (patrz komentarz
# przy QUALITY_RANK wyzej).
# ---------------------------------------------------------------------
sub _fetchGain {
    my ($videoId, $mode) = @_;
    $mode ||= 'quick';

    my $gain_json = LWP::Simple::get("$BRIDGE/gain?video_id=$videoId&mode=$mode");
    return undef unless $gain_json;

    my $gain_data = eval { from_json($gain_json) };
    if ($@ || !defined $gain_data->{replaygain_track_gain}) {
        return undef;
    }
    return {
        gain => $gain_data->{replaygain_track_gain} + 0,
        quality => $gain_data->{quality} || $mode,
    };
}

# ---------------------------------------------------------------------
# TANI fetch gainu - /gain?...&cache_only=1 - TYLKO odczyt juz policzonej
# wartosci z pamieci/dysku bridge'a, zero kosztu przy cache miss (bridge
# w ogole nie odpala yt-dlp/ffmpeg, patrz cache_only w bridge'u). Wolamy to
# ZAWSZE gdy nie mamy gainu w lokalnym %metaCache, niezaleznie od progu
# glosnosci - zastosowanie juz znanej wartosci nic nie kosztuje.
#
# Zwraca hashref { gain, quality } albo undef - patrz komentarz przy
# _fetchGain wyzej.
# ---------------------------------------------------------------------
sub _fetchGainCacheOnly {
    my ($videoId) = @_;

    my $gain_json = LWP::Simple::get("$BRIDGE/gain?video_id=$videoId&cache_only=1");
    return undef unless $gain_json;

    my $gain_data = eval { from_json($gain_json) };
    if ($@ || !defined $gain_data->{replaygain_track_gain}) {
        return undef;
    }
    return {
        gain => $gain_data->{replaygain_track_gain} + 0,
        quality => $gain_data->{quality} || 'quick',
    };
}

# Pomijamy generyczne sondowanie HTTP - znamy format z gory (WAV z bridge'a)
sub scanUrl {
    my ($class, $url, $args) = @_;
    $log->debug("YTMusic scanUrl wywolane, url=$url - pomijam sondowanie");
    $args->{cb}->($args->{song}->currentTrack());
}

sub new {
    my $class = shift;
    my $args = shift;

    $log->debug("YTMusic ProtocolHandler::new wywolane, url=" . ($args->{url} // 'undef'));

    my $videoId = _videoId($args->{url});
    my $realUrl = "$BRIDGE/audio/$videoId.aac";

    my $song = $args->{song};

    # LMS potrzebuje znac duration BEZPOSREDNIO na obiekcie $song, zeby w ogole
    # rozwazyc realny seek (przy duration=0 po prostu restartuje od zera zamiast
    # wywolac getSeekData/reopen z timeOffset). Samo zwracanie 'duration' z
    # getMetadataFor NIE wystarcza - trzeba ustawic to tutaj jawnie.

    # WAZNE: uzywamy TYLKO _fetchLightMeta (bez gainu) - new() jest wolane
    # przez LMS dla KAZDEGO utworu w kolejce przy prebufferingu, wiec musi
    # byc szybkie. Gain jest doliczany pozniej, wylacznie w onStream().
    # Cache moze byc juz wypelniony z dysku (patrz _loadMetaCacheFromDisk
    # przy zaladowaniu modulu) - w takim wypadku ZERO zapytan HTTP.
    my $meta = $metaCache{$videoId};
    unless ($meta) {
        $meta = _fetchLightMeta($videoId);
        $metaCache{$videoId} = $meta if $meta;
    }

    if ($song) {
        if ($meta && $meta->{duration}) {
            eval { $song->duration($meta->{duration}); };
            $log->debug("YTMusic: ustawiam duration=" . $meta->{duration} . " na song dla $videoId");
        }
        else {
            # Nie udalo sie ustalic prawdziwej dlugosci (np. timeout do bridge'a).
            # Zostawienie duration nieustawionego jest gorsze niz zawyzona wartosc:
            # LMS potrafi wtedy zgadnac (z rozmiaru pliku + zalozonego bitrate)
            # cos DUZO za krotkiego, przez co pasek postepu "wypelnia sie" po
            # kilku sekundach mimo ze audio dalej gra - a to z kolei gubi LMS
            # przy wznawianiu po komunikatach (announce) z Home Assistant.
            eval { $song->duration(600); };
            $log->warn("YTMusic: brak znanej dlugosci dla $videoId (timeout/blad bridge'a?) - "
                . "ustawiam bezpieczny placeholder 600s zamiast zostawiac LMS zgadywanie");
        }

        # Jesli to reopen po zadaniu przewiniecia, LMS zapisuje docelowa
        # pozycje (w sekundach) w $song->seekdata->{timeOffset} - doklejamy
        # ja jako ?start=X, a bridge/ffmpeg zaczyna remux od tej sekundy.
        my $seekdata = $song ? $song->seekdata() : undef;
        if ($seekdata && defined $seekdata->{timeOffset}) {
            my $start = $seekdata->{timeOffset};
            $realUrl .= "?start=$start";
            $log->debug("YTMusic: seek do ${start}s, url=$realUrl");

            # To mowi LMS "ten nowy strumien zaczyna sie od sekundy $start
            # oryginalnego utworu" - bez tego pozycja w UI liczona jest od 0,
            # mimo ze audio faktycznie gra od poprawnego miejsca.
            eval { $song->startOffset($start); };
        }
    }

    $log->debug("YTMusic: podmieniam na $realUrl");

    $args->{url} = $realUrl;

    # UWAGA: gain NIE jest juz ustawiany tutaj (patrz komentarz przy
    # _fetchGain) - ustawia go wylacznie onStream() nizej, tuz przed
    # realnym odtworzeniem tego konkretnego utworu.

    return $class->SUPER::new($args);
}

sub isRemote { 1 }

sub contentType { 'aac' }

sub getFormatForURL { 'aac' }

sub canDirectStream { 0 }

# Pozwalamy na przewijanie - reopen streamu z nowym ?start=X (patrz new() powyzej)
sub canSeek { 1 }

sub getSeekData {
    my ($class, $client, $song, $newtime) = @_;
    return { timeOffset => $newtime };
}

sub getMetadataFor {
    my ($class, $client, $url) = @_;
    my $videoId = _videoId($url);

    if (my $cached = $metaCache{$videoId}) {
        return $cached;
    }

    # UI/leniwe wywolanie - tu mozemy sobie pozwolic na _fetchLightMeta,
    # bez gainu. Gain dolaczany jest tylko gdy juz jest w cache (ustawiony
    # przez onStream) - inaczej UI (np. sam wpis w liscie playlisty)
    # wywolywalby ciezki fetch gainu dla kazdego utworu w widoku.
    my $meta = _fetchLightMeta($videoId);
    unless ($meta) {
        $log->warn("Nie udalo sie pobrac metadanych dla $videoId");
        return {};
    }

    $metaCache{$videoId} = $meta;
    return $meta;
}

# ---------------------------------------------------------------------
# Oficjalny hook LMS/Lyrion 9.1+ (PR #1489, public/9.1): wywolywany przez
# Slim::Player::Source TUZ PRZED odczytem replay gain z obiektu Song do
# strumienia - czyli dokladnie w momencie realnego startu odtwarzania
# KONKRETNEGO utworu, nie przy prebufferingu calej kolejki. To jedyne
# miejsce, gdzie wolamy _fetchGain w trybie 'quick' jako blokujacy
# fallback (ciezkie, moze trwac sekundy przy cache miss w bridge'u -
# analiza loudnorm pierwszych 25 sekund).
#
# Ewentualna, POPRAWIONA wartosc z glebszej analizy (half/full, wg
# gain_deep_analysis_mode) przychodzi pozniej, asynchronicznie, z
# Plugin.pm::_deepAnalysisFire, po przekroczeniu progu % odsluchania -
# dotyczy NASTEPNYCH odtworzen tego samego utworu (LMS nie ma mechanizmu
# zmiany gainu w trakcie juz trwajacego strumienia). _deepAnalysisFire
# aktualizuje TEN SAM lokalny %metaCache (przez setCachedMeta), wiec
# nastepne onStream() dla tego samego utworu widzi juz poprawiona
# wartosc od razu, z pamieci, bez zadnego zapytania.
# ---------------------------------------------------------------------
sub onStream {
    my ($class, $client, $song) = @_;

    my $videoId = _videoId($song->currentTrack->url);

    # Glowny wylacznik (prefs lub CLI override) - gdy wylaczony, gain jest
    # pomijany calkowicie, bez wyjatkow.
    unless ($class->replayGainMasterEnabled()) {
        $log->debug("YTMusic: onStream - gain wylaczony (glowny wylacznik) dla $videoId, pomijam");
        return;
    }

    my $meta = $metaCache{$videoId};

    my $gain = $meta && defined $meta->{replaygain_track_gain}
        ? $meta->{replaygain_track_gain}
        : undef;

    # Mamy juz gain w lokalnej pamieci (np. z prefetcha wczesniej w tej
    # sesji, ewentualnie juz podniesiony przez wczesniejsza gleboka
    # analize) - nic tanszego nie ma, uzywamy od razu, prog glosnosci nie
    # ma tu nic do powiedzenia (zastosowanie znanej wartosci jest darmowe).
    unless (defined $gain) {
        # Brak w lokalnej pamieci - sprawdzmy tani cache bridge'a (np.
        # wartosc policzona w POPRZEDNIEJ sesji LMS i zapisana na dysku,
        # albo policzona teraz przez inny gracz/prefetch/gleboka analize).
        # To zapytanie NIC NIE KOSZTUJE obliczeniowo (bridge tylko
        # zaglada do slownika, nie odpala yt-dlp/ffmpeg przy cache miss)
        # - stad wolamy je ZAWSZE, niezaleznie od progu glosnosci.
        my $cached = _fetchGainCacheOnly($videoId);
        if ($cached) {
            $gain = $cached->{gain};
            $meta ||= {};
            $meta->{replaygain_track_gain} = $gain;
            $meta->{replaygain_quality} = $cached->{quality};
            $metaCache{$videoId} = $meta;
            $log->debug("YTMusic: onStream - gain=$gain (quality=" . $cached->{quality} . ") dla $videoId znaleziony w cache bridge'a (tani odczyt)");
        }
    }

    # Nadal nic nie mamy - dopiero TERAZ prog glosnosci decyduje, czy WARTO
    # uruchomic ciezkie liczenie. ZAWSZE mode='quick' - to jedyne miejsce
    # gdzie zapytanie BLOKUJE start odtwarzania, wiec niezaleznie od
    # skonfigurowanego trybu glebokiej analizy, tu musi byc szybko.
    # Poprawiona wartosc (half/full) przyjdzie pozniej, asynchronicznie,
    # jesli user posluchaj wystarczajaco dlugo (patrz Plugin.pm).
    unless (defined $gain) {
        unless ($class->replayGainVolumeOk($client)) {
            $log->debug("YTMusic: onStream - brak gainu w cache i za cicho zeby liczyc dla $videoId, pomijam");
            return;
        }
        my $fetched = _fetchGain($videoId, 'quick');
        if ($fetched) {
            $gain = $fetched->{gain};
            $meta ||= _fetchLightMeta($videoId) || {};
            $meta->{replaygain_track_gain} = $gain;
            $meta->{replaygain_quality} = $fetched->{quality};
            $metaCache{$videoId} = $meta;
        }
    }

    if (defined $gain) {
        eval { $song->replayGain($gain); };
        if ($@) {
            $log->error("YTMusic: onStream BLAD ustawiania replayGain dla $videoId: $@");
        }
        else {
            # Read-back - nie polegamy na tym, ze LMS cos zaloguje dalej w
            # swoim potoku. Jesli TU widzimy poprawna wartosc, to znaczy ze
            # akcesor istnieje i przyjal wartosc.
            my $readback = eval { $song->replayGain() };
            $log->debug("YTMusic: onStream ustawiam replay_gain=$gain dB dla $videoId (read-back: "
                . (defined $readback ? $readback : 'UNDEF - accessor nie dziala!') . ")");
        }
    }
    else {
        $log->debug("YTMusic: onStream brak gainu dla $videoId");
    }
}

1;
