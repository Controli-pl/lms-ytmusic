package Plugins::YTMusic::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use HTTP::Tiny;
use JSON::XS::VersionOneAndTwo;

use Plugins::YTMusic::ProtocolHandler;

my $prefs = preferences('plugin.ytmusic');
my $log = logger('plugin.ytmusic');

# ---------------------------------------------------------------------
# Settings > Advanced > YTMusic w UI LMS.
#
# WAZNE: pola formularza w basic.html MUSZA nazywac sie "pref_"
# (konwencja Slim::Web::Settings) - inaczej LMS loguje warning
# "Preference names must be prefixed by pref_" przy kazdym zapisie
# strony ustawien. Odczyt w handler() nizej respektuje ten sam prefiks.
#
# Pola:
# - replaygain_enabled: glowny wylacznik replay gain (patrz
#   ProtocolHandler::replayGainMasterEnabled). Nadrzedny wobec WSZYSTKICH
#   pol nizej - gdy wylaczony, ani prefetch, ani onStream, ani gleboka
#   analiza nigdy nie wywoluja bridge'a.
# - replaygain_min_volume: prog glosnosci, ponizej ktorego NOWY gain nie
#   jest liczony (0 = zawsze liczony) - patrz replayGainVolumeOk. Dotyczy
#   TYLKO blokujacego fallbacku w onStream - gleboka analiza (nizej) go
#   ignoruje.
# - gain_deep_analysis_percent: KIEDY zamowic gleboka analize - po ilu %
#   odsluchanej dlugosci utworu (nie sekund!). Domyslnie 85.
# - gain_deep_analysis_mode: JAK GLEBOKO analizowac po przekroczeniu
#   progu - 'quick' (=25s, brak poglebienia - efektywnie wylacza caly
#   mechanizm), 'half' (pierwsza polowa utworu) albo 'full' (caly
#   utwor). Domyslnie 'full'. Prefetch "N do przodu" i blokujacy
#   fallback w onStream ZAWSZE uzywaja 'quick', niezaleznie od tego
#   ustawienia - patrz komentarze w ProtocolHandler.pm i Plugin.pm.
#
# - ytmusic_auth_headers: pole NIE jest zwyklym prefem (celowo brak go w
#   prefs() nizej) - to jednorazowa akcja, nie trwaly stan. Uzytkownik
#   wkleja tu surowe naglowki zadania skopiowane z DevTools przegladarki
#   (Network -> dowolne POST do youtubei/v1/browse -> Copy request
#   headers), zeby zalogowac YTMusic bez terminala/dockera. Po Save
#   wysylamy to do bridge'a (POST /setup_auth), ktory sam zapisuje
#   ytmusic_auth.json i reinicjuje sesje - patrz ytmusic_bridge.py.
#   Pole NIGDY nie jest odczytywane z powrotem do formularza (zawiera
#   dane sesyjne konta Google) i NIGDY nie trafia do $prefs ani do logu.
#
# WAZNE (poprawka po zgloszeniu): status logowania i etykiety trybu
# glebokiej analizy MUSZA byc tlumaczone przez string() WYWOLYWANE
# TUTAJ, W PERLU - NIGDY przez [% string('KEY') %] wewnatrz basic.html.
# Wywolanie string() w samej treści szablonu (poza atrybutami
# title/desc makra WRAPPER, ktore obsluguje to wewnetrznie) NIE
# renderuje sie poprawnie - w praktyce daje PUSTE etykiety w <option>
# (zaobserwowane realnie - dropdown "Deep analysis scope" pokazywal
# sie bez zadnego tekstu przy opcjach). Dlatego ZAWSZE przygotowujemy
# juz przetlumaczony tekst tutaj i wstawiamy go do $params jako zwykla,
# gotowa wartosc do wypisania - basic.html tylko ja wyswietla.
#
# Wczesniejsza wersja tego pliku popadala w odwrotny blad: status
# logowania byl wpisany NA TWARDO po polsku ('Zalogowano'/'Nie
# zalogowano') wprost w kodzie Perl, bez zadnego odwolania do
# strings.txt - w efekcie tekst byl zawsze po polsku, NIEZALEZNIE od
# jezyka ustawionego w interfejsie LMS. Teraz uzywamy string() z
# Slim::Utils::Strings, ktore respektuje aktualny jezyk serwera.
# ---------------------------------------------------------------------

sub name {
	return 'PLUGIN_YTMUSIC';
}

sub page {
	return 'plugins/YTMusic/settings/basic.html';
}

sub prefs {
	return ($prefs, qw(
		replaygain_enabled
		replaygain_min_volume
		gain_deep_analysis_percent
		gain_deep_analysis_mode
	));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ($params->{saveSettings}) {
		# Uwierzytelnianie YTMusic - obslugiwane PRZED zwyklymi prefami,
		# zeby $params->{ytmusic_auth_warning} bylo gotowe do wyswietlenia
		# niezaleznie od reszty zapisu. To NIE jest zapisywane jako pref -
		# patrz komentarz na gorze pliku.
		my $rawHeaders = delete $params->{pref_ytmusic_auth_headers};
		if (defined $rawHeaders && $rawHeaders =~ /\S/) {
			my $ua = HTTP::Tiny->new(timeout => 15);
			my $resp = $ua->post(
				Plugins::YTMusic::ProtocolHandler::bridgeUrl() . '/setup_auth',
				{
					content => to_json({ headers_raw => $rawHeaders }),
					headers => { 'Content-Type' => 'application/json' },
				}
			);

			if ($resp->{success}) {
				$log->info("YTMusic Settings: zapisano nowe uwierzytelnienie YTMusic przez /setup_auth");
				$params->{ytmusic_auth_warning} = string('PLUGIN_YTMUSIC_AUTH_SAVED_OK');
			}
			else {
				my $detail = eval { from_json($resp->{content})->{detail} } || $resp->{content} || $resp->{status};
				$log->warn("YTMusic Settings: blad zapisu uwierzytelnienia YTMusic: $detail");
				$params->{ytmusic_auth_warning} = string('PLUGIN_YTMUSIC_AUTH_SAVED_FAIL') . " $detail";
			}
			# $rawHeaders nigdy nie trafia do zadnej zmiennej poza tym blokiem
			# ani do logu (patrz komentarz na gorze pliku) - koniec zycia tutaj.
		}

		$prefs->set('replaygain_enabled', $params->{pref_replaygain_enabled} ? 1 : 0);

		my $minVolume = $params->{pref_replaygain_min_volume};
		if (defined $minVolume && $minVolume =~ /^\d+$/) {
			$prefs->set('replaygain_min_volume', $minVolume + 0 > 100 ? 100 : $minVolume + 0);
		}

		my $percent = $params->{pref_gain_deep_analysis_percent};
		if (defined $percent && $percent =~ /^\d+$/) {
			my $p = $percent + 0;
			$p = 1 if $p < 1;
			$p = 100 if $p > 100;
			$prefs->set('gain_deep_analysis_percent', $p);
		}

		my $mode = $params->{pref_gain_deep_analysis_mode} || '';
		if ($mode eq 'quick' || $mode eq 'half') {
			$prefs->set('gain_deep_analysis_mode', $mode);
		}
		else {
			$prefs->set('gain_deep_analysis_mode', 'full');
		}

		$log->info("YTMusic Settings zapisane: replaygain_enabled="
			. $prefs->get('replaygain_enabled')
			. " replaygain_min_volume=" . $prefs->get('replaygain_min_volume')
			. " gain_deep_analysis_percent=" . $prefs->get('gain_deep_analysis_percent')
			. " gain_deep_analysis_mode=" . $prefs->get('gain_deep_analysis_mode'));
	}

	# Etykiety trybu glebokiej analizy - tlumaczone TUTAJ (patrz duzy
	# komentarz na gorze pliku). basic.html odwoluje sie do tych trzech
	# gotowych parametrow, a NIE do string() wewnatrz szablonu.
	$params->{ytmusic_mode_quick_label} = string('PLUGIN_YTMUSIC_GAIN_DEEP_ANALYSIS_MODE_QUICK');
	$params->{ytmusic_mode_half_label}  = string('PLUGIN_YTMUSIC_GAIN_DEEP_ANALYSIS_MODE_HALF');
	$params->{ytmusic_mode_full_label}  = string('PLUGIN_YTMUSIC_GAIN_DEEP_ANALYSIS_MODE_FULL');

	# Status logowania YTMusic - odpytywany przy KAZDYM wejsciu na strone
	# (nie tylko przy save). Tlumaczone przez string() w Perlu (patrz
	# duzy komentarz na gorze pliku) - respektuje aktualny jezyk
	# interfejsu LMS, w odroznieniu od wczesniejszej wersji z tekstem
	# na trwale wpisanym po polsku wprost w kodzie.
	$params->{ytmusic_authenticated} = 0;
	$params->{ytmusic_auth_status_text} = string('PLUGIN_YTMUSIC_AUTH_LOGGED_OUT');
	eval {
		my $ua = HTTP::Tiny->new(timeout => 3);
		my $resp = $ua->get(Plugins::YTMusic::ProtocolHandler::bridgeUrl() . '/auth_status');
		if ($resp->{success}) {
			my $status = from_json($resp->{content});
			if ($status->{authenticated}) {
				$params->{ytmusic_authenticated} = 1;
				$params->{ytmusic_auth_status_text} = string('PLUGIN_YTMUSIC_AUTH_LOGGED_IN');
			}
		}
	};

	return $class->SUPER::handler($client, $params, $callback, @args);
}

1;
