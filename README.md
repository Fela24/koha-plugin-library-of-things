# Library of Things (Koha plugin)

Deutsche Version: [README.de.md](README.de.md) · Maintenance guide (German): [docs/WARTUNG.md](docs/WARTUNG.md)

Maintains an OPAC page with a tile grid of all "things" (tools, gadgets
and so on): one tile per title of the configured item type, with cover
image, title label and availability badge. On top of that: a collapsible
info box (lending conditions, opening hours, contact), a "Neu" ribbon
for recently accessioned things (configurable, default 30 days, 0 turns
it off), a client-side search and category filter buttons. Categories
come from the items' collections (CCODE authorised values); without
collection codes there are simply no filter buttons.

The page is deliberately static: without JavaScript everything works
except search and filters (those stay hidden, nobody sees dead controls).
The small script `js/library-of-things.js` adds the search, the filters,
the no-results tile and the hiding of tiles with broken cover images.

## How it works

Koha outputs additional contents raw; template directives in the content
are never evaluated. The plugin therefore renders the page itself: the
template lives at `opac-page.tt` in the plugin directory, and the
finished HTML is stored as the page content ("materialized").

The page re-renders instantly whenever the underlying data may have
changed:

- `after_biblio_action` / `after_item_action`: titles or items created,
  modified or deleted
- `after_circ_action`: checkout, return, renewal (availability badges)
- saving the configuration, plus `install`/`upgrade`

Each hook first checks cheaply whether the change can affect the page at
all (an item of the configured type, or a biblio shown on the page), so
batch jobs over the rest of the catalogue do not pay for a render per
record. Anything potentially relevant is recomputed completely and
written only when it differs from the stored state. If rendering fails,
the last good state stays in place; a plugin error never breaks the
cataloguing or circulation action that triggered it.

**Important:** the page belongs to the plugin. Manual edits to the page
content in the staff interface are overwritten on the next render; markup
changes belong in the template `opac-page.tt`.

The stylesheet lives at `css/library-of-things.css` in the plugin
directory and is served through the plugin's static route
(`/api/v1/contrib/libraryofthings/static/css/library-of-things.css`),
same for the JavaScript. The plugin version is appended as a query
parameter so browsers do not serve stale assets from cache after an
update.

Colors and dimensions are defined as CSS variables and can be overridden
per installation without touching the plugin, simply via the
`OPACUserCSS` system preference:

```css
#library-of-things {
  --lot-tile-height: 220px;
  --lot-badge-available-bg: #006400;
}
```

All variables and their defaults are listed at the top of
`css/library-of-things.css`.

## Configuration

Under *Administration → Manage plugins → Library of Things →
Configuration*, choose the item type that marks the things. Without
configuration the page shows an empty state. The timeframe for the "Neu"
ribbon and all texts of the page can be edited there as well; empty
fields fall back to the defaults (30 days, German texts), so no
translation toolchain is needed.

The tile images are Koha's local cover images, so the system preferences
`LocalCoverImages` and `OPACLocalCoverImages` must be enabled; things
without a cover show a plain tile with the title label.

**Note:** the fields "Infobox, Inhalt" and "Keine Treffer" are raw HTML
and are output unchanged in the OPAC. Whoever may configure the plugin
can author OPAC content; assign the permission accordingly. Saving is
CSRF-protected by the plugin's own Koha::Token check, independent of
whether the Koha version enforces CSRF centrally.

## Build & install

```sh
./build.sh
```

Upload the generated `.kpz` file in the staff interface under
*Administration → Manage plugins*. Requires `enable_plugins = 1` in
`koha-conf.xml` and the `UseKohaPlugins` system preference. Minimum
version: Koha 22.11.

No local build needed: the CI builds the `.kpz` on every push (download
it from the run in the Actions tab), and a tag like `v1.0.0` creates a
GitHub release with the `.kpz` attached.

## Tests

Need a Koha environment (kshell/ktd or a dev box); all changes run inside
a transaction and are rolled back, and the test resets the plugin state
at the start, so it also passes on installed and configured instances.

On a dev box:

```sh
cd /path/to/koha
PERL5LIB=.:/path/to/library-of-things prove -v /path/to/library-of-things/t/opac-page-ssr.t
```

In a kohadevbox-style container with the plugins directory mounted:

```sh
docker exec <container> bash -c 'koha-shell <instance> -c \
  "cd /kohadevbox/koha && PERL5LIB=/kohadevbox/koha:/kohadevbox/plugins/library-of-things \
  prove /kohadevbox/plugins/library-of-things/t/opac-page-ssr.t"'
```

## Possible extensions

- `api_routes()`: own REST endpoints, for example if availability should
  ever be fetched asynchronously (the tiles already carry
  `data-biblionumber` for that)
- `opac_js()`: JS injection in the OPAC, for example a homepage widget

## License

GPL-3.0-or-later, see [LICENSE](LICENSE).
