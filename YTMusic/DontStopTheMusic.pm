package Plugins::YTMusic::DontStopTheMusic;

use strict;
use Slim::Plugin::DontStopTheMusic::Plugin;
use Slim::Utils::Log;
use Slim::Networking::SimpleAsyncHTTP;
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);

use Plugins::YTMusic::ProtocolHandler;

my $log = logger('plugin.ytmusic');

# Jedyne miejsce definicji portu/URL bridge'a to ProtocolHandler.pm -
# tutaj tylko importujemy, zamiast trzymac wlasna, osobna kopie tej
# samej stalej (patrz komentarz w Plugin.pm).
my $BRIDGE = Plugins::YTMusic::ProtocolHandler::bridgeUrl();

use constant MAX_SEEDS => 3;

# ---------------------------------------------------------------------
# Filtr "nie powtarzaj tego samego utworu przez X godzin".
# Prosta pamiec w procesie: videoId -> epoch ostatniego dodania przez DSTM.
# Nie jest to trwale miedzy restartami LMS - i tak nie musi byc, chodzi
# tylko o unikanie powtorek w obrebie kilku kolejnych "doigrywan" radia.
# ---------------------------------------------------------------------
use constant DEDUP_WINDOW_SECONDS => 2 * 60 * 60; # 2 godziny
use constant DEDUP_MAX_ENTRIES => 500; # kiedy czyscic stare wpisy

my %recentlyUsed;

sub _isRecentlyUsed {
    my ($videoId) = @_;
    my $ts = $recentlyUsed{$videoId} or return 0;
    return (time() - $ts) < DEDUP_WINDOW_SECONDS;
}

sub _markUsed {
    my (@videoIds) = @_;
    my $now = time();
    $recentlyUsed{$_} = $now for grep { defined } @videoIds;

    if (scalar(keys %recentlyUsed) > DEDUP_MAX_ENTRIES) {
        _pruneRecentlyUsed();
    }
}

sub _pruneRecentlyUsed {
    my $now = time();
    for my $vid (keys %recentlyUsed) {
        delete $recentlyUsed{$vid} if ($now - $recentlyUsed{$vid}) >= DEDUP_WINDOW_SECONDS;
    }
}

sub init {
    $log->warn("=== YTMusic DontStopTheMusic init ===");
    Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_YTMUSIC_DSTM_RADIO', \&dontStopTheMusicRadio);
    Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_YTMUSIC_DSTM_MIX', \&dontStopTheMusicMix);
}

sub _extractVideoId {
    my ($entry) = @_;
    my $url = blessed($entry) ? ($entry->url // '') : ($entry // '');
    return undef unless $url =~ m{^ytmusic://(.+)$};
    return $1;
}

sub _parseLength {
    my $length = shift;
    return undef unless $length;
    if ($length =~ /^(\d+):(\d+)$/) {
        return $1 * 60 + $2;
    }
    return undef;
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

sub _videoIdFromUrl {
    my ($url) = @_;
    return undef unless $url && $url =~ m{^ytmusic://(.+)$};
    return $1;
}

# ---------------------------------------------------------------------
# RADIO: na bazie ostatniego (najbardziej aktualnego) utworu YTMusic w kolejce
# ---------------------------------------------------------------------
sub dontStopTheMusicRadio {
    my ($client, $cb) = @_;
    $log->debug("YTMusic DSTM RADIO wywolane");

    my $playlist = Slim::Player::Playlist::playList($client->master);
    unless ($playlist && @$playlist) {
        $log->debug("YTMusic DSTM RADIO: pusta kolejka");
        return $cb->($client, []);
    }

    my $videoId;
    for my $entry (reverse @$playlist) {
        $videoId = _extractVideoId($entry);
        last if $videoId;
    }

    unless ($videoId) {
        $log->debug("YTMusic DSTM RADIO: brak utworu ytmusic:// w kolejce");
        return $cb->($client, []);
    }

    _fetchRadioUrls($videoId, sub {
        my ($urls) = @_;
        _markUsed(map { _videoIdFromUrl($_) } @$urls);
        $log->debug("YTMusic DSTM RADIO: zwracam " . scalar(@$urls) . " URL-i");
        $cb->($client, $urls);
    });
}

# ---------------------------------------------------------------------
# MIX: na bazie kilku ostatnich seedow z kolejki (LMS getMixableProperties),
# radio dla kazdego z osobna, wyniki zmiksowane naprzemiennie (round-robin:
# 1+1+1, 2+2+2, 3+3+3...) zamiast doklejania calych blokow 25+25+25 -
# dzieki temu po dodaniu do kolejki od razu jest roznorodnosc miedzy seedami,
# a nie tylko material z ostatniego seeda az sie skonczy.
# ---------------------------------------------------------------------
sub dontStopTheMusicMix {
    my ($client, $cb) = @_;
    $log->debug("YTMusic DSTM MIX wywolane");

    my $pl = Slim::Player::Playlist::playList($client->master);
    if (!$pl || scalar(@$pl) <= 1) {
        $log->debug("YTMusic DSTM MIX: tylko 1 utwor w kolejce - przelaczam na RADIO");
        return dontStopTheMusicRadio($client, $cb);
    }

    my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, MAX_SEEDS);
    unless ($seedTracks && @$seedTracks) {
        $log->debug("YTMusic DSTM MIX: brak seedow");
        return $cb->($client, []);
    }

    my @videoIds;
    my %seen;
    for my $track (@$seedTracks) {
        my $url = $track->{url} || $track->{extid} || '';
        if ($url =~ m{^ytmusic://(.+)$}) {
            my $vid = $1;
            push @videoIds, $vid unless $seen{$vid}++;
        }
    }

    unless (@videoIds) {
        $log->debug("YTMusic DSTM MIX: brak seedow ytmusic:// (mieszana kolejka z innych pluginow?)");
        return $cb->($client, []);
    }

    $log->debug("YTMusic DSTM MIX: seedy=" . join(' ', @videoIds));

    _fetchRadioUrlsMulti(\@videoIds, sub {
        my ($urls) = @_;
        _markUsed(map { _videoIdFromUrl($_) } @$urls);
        $log->debug("YTMusic DSTM MIX: zwracam " . scalar(@$urls) . " URL-i (round-robin)");
        $cb->($client, $urls);
    });
}

# ---------------------------------------------------------------------
# Pobiera radio dla jednego video_id, zwraca listref URL-i ytmusic://
# i przy okazji wypelnia cache metadanych (jak w handleRadioAddToPlaylist),
# zeby wyswietlanie w kolejce nie wywolywalo osobno yt-dlp dla kazdego utworu.
#
# Utwory, ktore DSTM juz dodal w ciagu ostatnich DEDUP_WINDOW_SECONDS,
# sa tu odfiltrowywane - to samo "radio" moglo je juz zaproponowac
# przy poprzednim wywolaniu, a nie chcemy zapetlenia sie na tych samych
# kilkunastu utworach.
# ---------------------------------------------------------------------
sub _fetchRadioUrls {
    my ($videoId, $done) = @_;

    my $url = "$BRIDGE/radio?video_id=$videoId&limit=25";

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $data = eval { from_json($http->content) };

            if ($@ || !$data || !$data->{tracks}) {
                $log->warn("YTMusic DSTM: radio parse failed dla $videoId: $@");
                return $done->([]);
            }

            my @tracks = grep { $_->{videoId} } @{ $data->{tracks} };
            if (@tracks && $tracks[0]->{videoId} eq $videoId) {
                shift @tracks; # get_watch_playlist zwraca seed jako pierwszy element
            }

            my @urls;
            my $skippedDedup = 0;
            for my $t (@tracks) {
                my $vid = $t->{videoId};

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

                if (_isRecentlyUsed($vid)) {
                    $skippedDedup++;
                    next;
                }

                push @urls, "ytmusic://$vid";
            }

            if ($skippedDedup) {
                $log->debug("YTMusic DSTM: pominieto $skippedDedup utworow dla $videoId (dedup < " . DEDUP_WINDOW_SECONDS . "s)");
            }

            $done->(\@urls);
        },
        sub {
            $log->warn("YTMusic DSTM: HTTP request failed dla $videoId");
            $done->([]);
        },
    )->get($url);
}

# ---------------------------------------------------------------------
# Pobiera radio dla kilku video_id rownolegle, a nastepnie miksuje wyniki
# naprzemiennie (round-robin) zamiast laczyc je w kolejnych blokach.
# Czeka az wszystkie zapytania wroca (sukces lub porazka), zanim wywola $done.
# ---------------------------------------------------------------------
sub _fetchRadioUrlsMulti {
    my ($videoIds, $done) = @_;

    unless (@$videoIds) {
        return $done->([]);
    }

    my %resultsByVid;
    my $remaining = scalar(@$videoIds);
    my $finished = 0;

    for my $vid (@$videoIds) {
        _fetchRadioUrls($vid, sub {
            my ($urls) = @_;
            $resultsByVid{$vid} = $urls;

            $remaining--;
            if ($remaining <= 0 && !$finished) {
                $finished = 1;
                my $merged = _roundRobinMerge($videoIds, \%resultsByVid);
                $done->($merged);
            }
        });
    }
}

# ---------------------------------------------------------------------
# Miesza listy utworow z kilku seedow naprzemiennie: po jednym z kazdego
# seeda w kolejnosci $order, potem po drugim z kazdego, itd. (1+1+1+2+2+2+...)
# Deduplikuje miedzy seedami (to samo radio moze wystapic dla kilku seedow).
# ---------------------------------------------------------------------
sub _roundRobinMerge {
    my ($order, $byVid) = @_;

    my %seenIds;
    my @merged;
    my $idx = 0;

    while (1) {
        my $addedThisRound = 0;

        for my $vid (@$order) {
            my $list = $byVid->{$vid} || [];
            next unless $idx < scalar(@$list);

            $addedThisRound = 1;

            my $url = $list->[$idx];
            my $uid = _videoIdFromUrl($url);
            next unless $uid;
            next if $seenIds{$uid}++;

            push @merged, $url;
        }

        last unless $addedThisRound;
        $idx++;
    }

    return \@merged;
}

1;
