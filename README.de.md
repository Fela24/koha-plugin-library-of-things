# Library of Things (Koha-Plugin)

English version: [README.md](README.md) · Wartung: [docs/WARTUNG.md](docs/WARTUNG.md)

Pflegt eine OPAC-Seite mit einem Kachel-Raster aller „Dinge" (Werkzeuge,
Geräte usw.): eine Kachel pro Titel des konfigurierten Medientyps, mit
Cover, Titel-Label und Verfügbarkeits-Badge. Dazu kommen eine
aufklappbare Infobox (Ausleihkonditionen, Öffnungszeiten, Kontakt), ein
„Neu"-Band für frisch inventarisierte Dinge (Zeitraum einstellbar,
Standard 30 Tage, 0 schaltet es ab), eine Suche sowie Filter-Buttons nach
Kategorie. Die Kategorien kommen aus den Sammlungen (CCODE) der
Exemplare; ohne Sammlungscodes gibt es einfach keine Filter-Buttons.

Die Seite ist bewusst statisch: Ohne JavaScript funktioniert alles außer
Suche und Filter (die bleiben dann ausgeblendet, niemand sieht tote
Bedienelemente). Das kleine Skript `js/library-of-things.js` ergänzt
Suche, Filter, die Keine-Treffer-Kachel und das Ausblenden von Kacheln
mit kaputtem Cover.

## Wie es funktioniert

Koha gibt den Inhalt von Zusatzinhalten (additional contents) unverändert
aus, Template-Direktiven darin werden nicht ausgewertet. Das Plugin
rendert deshalb selbst: Das Template liegt unter `opac-page.tt` im
Plugin-Verzeichnis, das fertige HTML wird als Seiteninhalt gespeichert
(„materialisiert").

Neu gerendert wird sofort, sobald sich die zugrunde liegenden Daten
geändert haben können:

- `after_biblio_action` / `after_item_action`: Titel oder Exemplare
  angelegt, geändert, gelöscht
- `after_circ_action`: Ausleihe, Rückgabe, Verlängerung
  (Verfügbarkeits-Badges)
- Speichern der Konfiguration sowie `install`/`upgrade`

Jeder Hook prüft zuerst billig, ob die Änderung die Seite überhaupt
betreffen kann (Exemplar des konfigurierten Medientyps oder Titel auf der
Seite); Massenjobs über den restlichen Katalog kosten so keinen Render
pro Datensatz. Alles potenziell Relevante wird komplett neu berechnet und
nur bei Abweichung geschrieben. Schlägt das Rendern fehl, bleibt der
letzte gute Stand stehen; ein Fehler im Plugin bricht niemals die
auslösende Katalogisierungs- oder Ausleihaktion ab.

**Wichtig:** Die Seite gehört dem Plugin. Manuelle Änderungen am
Seiteninhalt in der Dienstoberfläche werden beim nächsten Rendern
überschrieben; Anpassungen gehören ins Template `opac-page.tt`.

Das Stylesheet liegt unter `css/library-of-things.css` im
Plugin-Verzeichnis und wird über die Static-Route des Plugins
ausgeliefert
(`/api/v1/contrib/libraryofthings/static/css/library-of-things.css`),
das JavaScript ebenso. Die Plugin-Version hängt als Query-Parameter dran,
damit Browser nach einem Update kein veraltetes CSS oder JS aus dem Cache
verwenden.

Farben und Maße sind als CSS-Variablen definiert und lassen sich ohne
Plugin-Änderung pro Installation überschreiben, einfach in der
Systempräferenz `OPACUserCSS`:

```css
#library-of-things {
  --lot-tile-height: 220px;
  --lot-badge-available-bg: #006400;
}
```

Alle Variablen samt Standardwerten stehen am Anfang von
`css/library-of-things.css`.

## Konfiguration

Unter *Administration → Plugins verwalten → Library of Things →
Konfiguration* den Medientyp wählen, der die Dinge markiert. Ohne
Konfiguration zeigt die Seite einen Leer-Zustand. Dort lassen sich auch
der Zeitraum für das „Neu"-Band und alle Texte der Seite anpassen; leere
Felder fallen auf die Standardwerte zurück (30 Tage, deutsche Texte),
eine Übersetzungs-Infrastruktur ist nicht nötig.

Die Kachelbilder sind Kohas lokale Coverbilder; die Systempräferenzen
`LocalCoverImages` und `OPACLocalCoverImages` müssen aktiviert sein.
Dinge ohne Cover zeigen eine schlichte Kachel mit dem Titel-Label.

**Hinweis:** Die Felder „Infobox, Inhalt" und „Keine Treffer" sind rohes
HTML und werden unverändert im OPAC ausgegeben. Wer das Plugin
konfigurieren darf, kann also OPAC-Inhalte gestalten; die Berechtigung
entsprechend vergeben. Das Speichern ist über einen eigenen
Koha::Token-CSRF-Check abgesichert, unabhängig davon, ob die
Koha-Version CSRF zentral erzwingt.

### Auf die Seite verlinken

Die Seite ist eine Koha-Zusatzinhaltsseite und wird unter
`/cgi-bin/koha/opac-page.pl?page_id=<id>` aufgerufen (die id steht unter
*Werkzeuge → Zusatzinhalte*). Diese URL für OPAC-Navigation oder
Menü-Links verwenden. Die id bleibt über Plugin-Upgrades und
Inhalts-Aktualisierungen hinweg **stabil** — das Plugin aktualisiert die
bestehende Seite, statt sie neu anzulegen. Sie ändert sich nur, wenn das
Plugin deinstalliert und neu installiert wird (die Deinstallation entfernt
die Seite, eine Neuinstallation legt eine neue an); nach einer
Neuinstallation daher fest hinterlegte Links prüfen.

## Bauen & installieren

```sh
./build.sh
```

Die erzeugte `.kpz`-Datei in der Dienstoberfläche unter
*Administration → Plugins verwalten* hochladen. Voraussetzung:
`enable_plugins = 1` in der `koha-conf.xml` und Systempräferenz
`UseKohaPlugins`. Mindestversion: Koha 22.11.

Ein lokaler Build ist nicht nötig: Die CI baut das `.kpz` bei jedem Push
(im Actions-Tab am Lauf herunterladbar), und ein Tag wie `v1.0.0` erzeugt
ein GitHub-Release mit angehängtem `.kpz`.

## Tests

Benötigen eine Koha-Umgebung (kshell/ktd oder Dev-Box); alle Änderungen
laufen in einer Transaktion und werden zurückgerollt. Der Test setzt den
Plugin-Zustand am Anfang zurück und läuft daher auch auf installierten,
konfigurierten Instanzen.

Auf einer Dev-Box:

```sh
cd /pfad/zum/koha-clone
PERL5LIB=.:/pfad/zu/library-of-things prove -v /pfad/zu/library-of-things/t/opac-page-ssr.t
```

In einem kohadevbox-Container mit eingehängtem Plugins-Verzeichnis:

```sh
docker exec <container> bash -c 'koha-shell <instanz> -c \
  "cd /kohadevbox/koha && PERL5LIB=/kohadevbox/koha:/kohadevbox/plugins/library-of-things \
  prove /kohadevbox/plugins/library-of-things/t/opac-page-ssr.t"'
```

## Mögliche Erweiterungen

- `api_routes()`: eigene REST-Endpunkte, z. B. falls Verfügbarkeit später
  asynchron nachgeladen werden soll (die Kacheln tragen dafür bereits
  `data-biblionumber`)
- `opac_js()`: JS-Injection im OPAC, z. B. für ein Startseiten-Widget

## Lizenz

GPL-3.0-or-later, siehe [LICENSE](LICENSE).
