# Wartung des Plugins

Kurzreferenz für die laufende Pflege. Grundlagen und Konzept stehen in der
[README.de.md](../README.de.md).

## Wo liegt was

| Datei | Inhalt |
|---|---|
| `Koha/Plugin/.../LibraryOfThings.pm` | Logik, Hooks, Standardtexte, Konfiguration |
| `.../LibraryOfThings/opac-page.tt` | Markup der OPAC-Seite |
| `.../LibraryOfThings/css/library-of-things.css` | Styling, alle Variablen |
| `.../LibraryOfThings/js/library-of-things.js` | Suche, Filter, Keine-Treffer, kaputte Bilder |
| `.../LibraryOfThings/configure.tt` | Konfigurationsformular (Dienstoberfläche) |
| `t/opac-page-ssr.t` | Tests (brauchen eine Koha-Umgebung) |
| `.github/workflows/ci.yml` | CI: Tests und kpz-Build auf GitHub |

## Texte ändern

Nicht im Code: Alle Texte der Seite stehen auf der Konfigurationsseite des
Plugins; leere Felder fallen auf die Standardtexte zurück. Die
Standardtexte selbst stehen im Modul in `$DEFAULT_TEXTS`. Auch der
Zeitraum für das „Neu"-Band ist dort einstellbar (leer = 30 Tage,
0 schaltet es ab).

## Farben und Maße ändern

Pro Installation ohne Code-Änderung: CSS-Variable in der Systempräferenz
`OPACUserCSS` überschreiben, z. B.

```css
#library-of-things { --lot-tile-height: 220px; }
```

Dauerhaft für alle: Standardwert im `:root`-Block von
`css/library-of-things.css` ändern.

## Markup ändern

In `opac-page.tt`. Zwei Regeln:

1. Jede Variable mit `| html` ausgeben (in URLs `| uri`). Einzige
   Ausnahmen: `texts.info_content` und `texts.no_results`, die bewusst
   HTML enthalten.
2. Die Seite im OPAC zeigt gespeichertes HTML; Template-Änderungen
   erscheinen erst nach einem Neu-Rendern (siehe unten).

Neue Daten ins Template bringen: in `_things()` (oder einem neuen Helper)
berechnen, in `_render_page()` unter `$vars` registrieren, im Template
ausgeben.

## Neu-Rendern anstoßen

Die Seite rendert automatisch neu bei relevanten Titel-, Exemplar- und
Ausleihänderungen (Exemplare des konfigurierten Medientyps oder Titel,
die auf der Seite stehen) sowie beim Speichern der Konfiguration. Nach
Code-Deployments von Hand:

```sh
koha-shell <instanz> -c "perl -I/var/lib/koha/<instanz>/plugins \
  -MKoha::Plugin::De::StadtbuechereiTuebingen::LibraryOfThings -E '
  Koha::Plugin::De::StadtbuechereiTuebingen::LibraryOfThings
    ->new({ enable_plugins => 1 })
    ->after_item_action({ action => q{modify} })'"
```

Vorher Plack neu starten (`koha-plack --restart <instanz>`): Das Template
wird pro Prozess gecacht, alte Worker rendern sonst mit altem Stand.

## Release

1. `$VERSION` im Modul erhöhen (`build.sh` liest sie aus) und
   `date_updated` in `$METADATA` aktualisieren; committen.
2. Prüfen: `perltidy`, `perlcritic` (muss „source OK" melden),
   `podchecker`. Die Tests laufen bei jedem Push automatisch in der CI
   (lokal geht es mit `prove`, Kommando in der README).
3. Tag pushen: `git tag v<version> && git push --tags`. Die CI testet,
   baut das kpz und hängt es an das GitHub-Release; von dort
   herunterladen und in der Dienstoberfläche hochladen. Das `upgrade()`
   des Plugins rendert die Seite neu, und die neue Version im
   `?v=`-Parameter holt frisches CSS/JS an allen Browser-Caches vorbei.

Ohne Release: Die CI baut das kpz bei jedem Push; es hängt als Artefakt
am Lauf im Actions-Tab. Lokal geht weiterhin `./build.sh`.

Komplett ohne Terminal: Version im GitHub-Web-Editor erhöhen und
committen, dann unter *Releases → Draft a new release* einen neuen Tag
`v<version>` eintippen und veröffentlichen. GitHub legt den Tag an, die
CI testet, baut und hängt das kpz an genau dieses Release an.

## Stolperfallen

- Die OPAC-Seite nie in der Dienstoberfläche editieren: Sie gehört dem
  Plugin und wird beim nächsten Rendern überschrieben.
- Beim Entwickeln ohne Versionswechsel cached der Browser CSS/JS
  (gleicher `?v=`-Wert): Hard-Reload verwenden.
- Suche und Filter sind absichtlich `hidden` und werden erst per
  JavaScript eingeblendet; ohne JS ist das kein Fehler, sondern das
  gewollte statische Verhalten.
- Statische Assets laufen über die Plugin-API; neue Dateien brauchen
  einen Eintrag in `static_routes()` (Query-Parameter wie `?v=` müssen
  dort deklariert sein, sonst antwortet die API mit 400).
- Auf Koha ≥ 23.11 pflegt das Plugin nur die Standard-Sprachversion der
  Seite; keine zusätzlichen Sprachversionen anlegen, die blieben für
  immer veraltet.
- Alle Kacheln grau? Die Cover kommen aus Kohas lokalen Coverbildern;
  die Systempräferenzen `LocalCoverImages` und `OPACLocalCoverImages`
  müssen aktiviert sein.
