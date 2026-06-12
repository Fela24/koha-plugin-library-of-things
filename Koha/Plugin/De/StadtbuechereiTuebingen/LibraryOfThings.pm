package Koha::Plugin::De::StadtbuechereiTuebingen::LibraryOfThings;

# Copyright Stadtbuecherei Tuebingen 2026
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

use Modern::Perl;
use utf8;
use base qw(Koha::Plugins::Base);

use Carp    qw( carp );
use English qw( -no_match_vars );
use Readonly;

use Koha::AdditionalContent;
use Koha::AdditionalContents;
use Koha::AuthorisedValues;
use Koha::Database;
use Koha::DateUtils qw( dt_from_string );
use Koha::Items;
use Koha::ItemTypes;
use Koha::Token;

# Default timeframe for the "Neu" ribbon: things with an item accessioned
# within this many days get it. Configurable on the configure page
# (plugin data "new_badge_days", see _new_badge_days; 0 turns it off).
Readonly my $NEW_BADGE_DAYS => 30;

# Default texts of the OPAC page. Every entry can be overridden on the
# configure page (stored as plugin data under "text_<key>"); an empty
# stored value falls back to the default. This way the page needs no
# translation toolchain: the librarian simply edits the texts.
Readonly my $DEFAULT_TEXTS => {
    intro        => 'Leihen Sie Werkzeuge, Geräte und mehr einfach aus.',
    info_label   => 'Ausleihkonditionen & Öffnungszeiten',
    info_content => <<'HTML',
<p><strong>Ausleihkonditionen:</strong></p>
<p>Werkzeuge und weitere Geräte - 14 Tage</p>
<p>Energiemessgeräte - 28 Tage</p>
<p>E-Book-Reader - 28 Tage</p>
<p>
  <strong>Öffnungszeiten Bibliothek der Dinge:</strong><br>
  Täglich geöffnet - 24 Stunden<br>
  Zugang außerhalb der Öffnungszeiten nur mit gültigem Büchereiausweis.
</p>
<p><strong>Kontakt:</strong> <a href="mailto:stadtbuecherei@tuebingen.de">stadtbuecherei@tuebingen.de</a></p>
HTML
    search_placeholder => 'Bibliothek der Dinge durchsuchen',
    filter_all         => 'Alle anzeigen',
    badge_available    => 'Verfügbar',
    badge_unavailable  => 'Ausgeliehen',
    ribbon_new         => 'Neu',
    no_results         => <<'HTML',
Ups! Hier gibt es aktuell nichts zu sehen.<br>
Probieren Sie einen anderen Begriff oder wählen Sie einen anderen Filter.<br>
Sie wünschen sich etwas?
<a href="/cgi-bin/koha/opac-suggestions.pl">Machen Sie uns doch einen Anschaffungsvorschlag!</a>
HTML
    empty_state => 'Aktuell sind keine Dinge verfügbar.',
};

=head1 NAME

Koha::Plugin::De::StadtbuechereiTuebingen::LibraryOfThings - OPAC tile page for a library of things

=head1 DESCRIPTION

Maintains an OPAC page (Koha "Additional contents", category 'pages') that
shows one tile per biblio of the configured item type, with cover image,
title label and an availability badge.

Koha outputs additional_contents raw ([% page.content | $raw %] in
opac-page.tt), so the page has to store finished HTML. The plugin owns the
markup: it renders its page template (opac-page.tt in the plugin
directory) and writes the result into the page
whenever the underlying data may have changed: instantly, via the
C<after_biblio_action>/C<after_item_action>/C<after_circ_action> hooks,
plus on install/upgrade and configure. Each hook first runs a cheap
relevance check (an item of the configured type involved, or a biblio
that is on the page), so batch jobs over the rest of the catalogue do not
pay for a render per record; anything possibly relevant recomputes the
output completely and writes only if it differs from what is stored. A
hook failure keeps the last good page; it must never break the
cataloguing/circulation action that triggered it.

=cut

our $VERSION  = '1.0.0';
our $METADATA = {
    name        => 'Library of Things',
    author      => 'Stadtbuecherei Tuebingen',
    description =>
        'Pflegt die OPAC-Seite „Bibliothek der Dinge": ein Kachel-Raster aller Dinge des konfigurierten Medientyps mit Cover, Verfügbarkeits-Badge, „Neu"-Band, Suche und Kategorie-Filtern; aktualisiert sich automatisch bei Katalog- und Ausleihänderungen.',
    date_authored   => '2026-06-11',
    date_updated    => '2026-06-12',
    minimum_version => '22.11.00',
    maximum_version => undef,
    version         => $VERSION,
};

=head2 new

    my $plugin = Koha::Plugin::De::StadtbuechereiTuebingen::LibraryOfThings->new($args);

Constructor, called by Koha's plugin system. Attaches the plugin metadata
and delegates to L<Koha::Plugins::Base>.

=cut

sub new {
    my ( $class, $args ) = @_;
    $args->{metadata} = $METADATA;
    $args->{metadata}->{class} = $class;
    return $class->SUPER::new($args);
}

my $PAGE_CODE = 'libraryofthings';

# Cache/override slot for the page template (opac-page.tt in the plugin
# directory); filled on first use by _page_template(). `our` so tests can
# inject a template.
our $PAGE_TEMPLATE;

=head2 install

    $plugin->install($args);

Plugin lifecycle hook. Creates the OPAC page with the initially rendered
content (the empty state, as long as no item type is configured yet).

=cut

sub install {
    my ( $self, $args ) = @_;

    _create_opac_page(
        {   code    => $PAGE_CODE,
            title   => 'Bibliothek der Dinge – Werkzeuge und mehr!',
            content => $self->_render_page() // q{},
        }
    );

    return 1;
}

=head2 upgrade

    $plugin->upgrade($args);

Plugin lifecycle hook. Re-renders the page so that template changes
shipped with a new plugin version reach existing installations.

=cut

sub upgrade {
    my ( $self, $args ) = @_;

    $self->_refresh_page_guarded();

    return 1;
}

=head2 uninstall

    $plugin->uninstall($args);

Plugin lifecycle hook. Removes the OPAC page.

=cut

sub uninstall {
    my ( $self, $args ) = @_;

    _delete_opac_page( { code => $PAGE_CODE } );

    return 1;
}

=head2 _has_split_schema

    if ( _has_split_schema() ) { ... }

Internal. Returns 1 on Koha >= 23.11, where title/content/lang of
additional contents live in additional_contents_localizations (Bug 31383),
and 0 on the legacy schema, where they sit directly on
additional_contents. Asks the ORM rather than the database server.

=cut

# Cached for the process lifetime; the schema cannot change at runtime.
my $has_split_schema;

sub _has_split_schema {
    if ( defined $has_split_schema ) {
        return $has_split_schema;
    }

    my $source = Koha::Database->new->schema->source('AdditionalContent');
    if ( $source->has_column('lang') ) {
        $has_split_schema = 0;
    }
    else {
        $has_split_schema = 1;
    }

    return $has_split_schema;
}

=head2 _find_page

    my $page = _find_page($code);

Internal. Returns the plugin's OPAC page (a L<Koha::AdditionalContent>)
for the given code, or undef if it does not exist.

=cut

sub _find_page {
    my ($code) = @_;

    return Koha::AdditionalContents->search(
        {   category => 'pages',
            code     => $code,
            location => 'opac_only',
        }
    )->next;
}

=head2 _create_opac_page

    _create_opac_page( { code => $code, title => $title, content => $html } );

Internal. Creates the OPAC page (category 'pages', location 'opac_only');
on the split schema the title/content go into a 'default' localization
record instead of the page itself. Does nothing if the page already exists.

=cut

sub _create_opac_page {
    my ($params) = @_;

    if ( _find_page( $params->{code} ) ) {
        return;
    }

    my $page_values = {
        category     => 'pages',
        code         => $params->{code},
        location     => 'opac_only',
        branchcode   => undef,
        published_on => dt_from_string()->ymd(),
        number       => 0,
    };

    if ( !_has_split_schema() ) {
        $page_values->{title}   = $params->{title};
        $page_values->{content} = $params->{content};
        $page_values->{lang}    = 'default';
    }

    # txn_do = database transaction: on the split schema page and
    # localization belong together, a partial create would leave a page
    # the plugin can never fill again.
    my $schema = Koha::Database->new->schema;
    $schema->txn_do(
        sub {
            my $page = Koha::AdditionalContent->new($page_values)->store;

            if ( _has_split_schema() ) {

                # The localization class only exists on Koha >= 23.11, hence require.
                require Koha::AdditionalContentsLocalization;
                Koha::AdditionalContentsLocalization->new(
                    {   additional_content_id => $page->id,
                        title                 => $params->{title},
                        content               => $params->{content},
                        lang                  => 'default',
                    }
                )->store;
            }
        }
    );

    return;
}

=head2 _delete_opac_page

    _delete_opac_page( { code => $code } );

Internal. Deletes the OPAC page including its localization records on the
split schema. Does nothing if the page does not exist.

=cut

sub _delete_opac_page {
    my ($params) = @_;

    my $page = _find_page( $params->{code} );
    if ( !$page ) {
        return;
    }

    # txn_do = database transaction, see _create_opac_page.
    my $schema = Koha::Database->new->schema;
    $schema->txn_do(
        sub {
            if ( _has_split_schema() ) {
                $page->translated_contents->delete;
            }
            $page->delete;
        }
    );

    return;
}

=head2 after_biblio_action

    $plugin->after_biblio_action($params);

Koha plugin hook, fires on create/modify/delete of bibliographic records.
Re-renders the page unless the biblio is clearly irrelevant, see
L</_biblio_is_relevant>.

=cut

sub after_biblio_action {
    my ( $self, $params ) = @_;

    $params //= {};
    my $payload = $params->{payload} // {};

    # Older Koha passes biblio_id at the top level, newer versions only
    # inside payload; unknown shapes fall through to a re-render.
    my $biblionumber = $params->{biblio_id} // $payload->{biblio_id};
    if ( $biblionumber && !$self->_biblio_is_relevant($biblionumber) ) {
        return;
    }

    $self->_refresh_page_guarded();

    return;
}

=head2 after_item_action

    $plugin->after_item_action($params);

Koha plugin hook, fires on create/modify/delete of items. Re-renders the
page unless the item is clearly irrelevant, see L</_item_is_relevant>.

=cut

sub after_item_action {
    my ( $self, $params ) = @_;

    $params //= {};
    my $payload = $params->{payload} // {};

    # Older Koha passes the item at the top level (deprecated there),
    # newer versions inside payload; unknown shapes fall through to a
    # re-render.
    my $item = $params->{item} // $payload->{item};
    if ( $item && !$self->_item_is_relevant($item) ) {
        return;
    }

    $self->_refresh_page_guarded();

    return;
}

=head2 after_circ_action

    $plugin->after_circ_action($params);

Koha plugin hook, fires on checkout, return and renewal. Keeps the
availability badges current (the item hook usually fires for these too,
but this one is explicit and guaranteed). Re-renders the page unless the
checked-out item is clearly irrelevant, see L</_item_is_relevant>.

=cut

sub after_circ_action {
    my ( $self, $params ) = @_;

    $params //= {};
    my $checkout = $params->{payload} ? $params->{payload}->{checkout} : undef;
    if ($checkout) {
        my $item = Koha::Items->find( $checkout->itemnumber );
        if ( $item && !$self->_item_is_relevant($item) ) {
            return;
        }
    }

    $self->_refresh_page_guarded();

    return;
}

=head2 _item_is_relevant

    if ( $self->_item_is_relevant($item) ) { ... }

Internal. An item change is relevant when an item type is configured and
the item either has that type or belongs to a biblio shown on the page
(the latter covers items that were just retyped away). The hook callers
err on the side of re-rendering when in doubt; a render too many is a
cheap no-op.

=cut

sub _item_is_relevant {
    my ( $self, $item ) = @_;

    my $item_type = $self->retrieve_data('item_type');
    if ( !$item_type ) {
        return 0;
    }

    my $itype = $item->itype // q{};
    if ( $itype eq $item_type ) {
        return 1;
    }

    return $self->_page_lists_biblionumber( $item->biblionumber );
}

=head2 _biblio_is_relevant

    if ( $self->_biblio_is_relevant($biblionumber) ) { ... }

Internal. A biblio change is relevant when an item type is configured and
the biblio is shown on the page or has items of the configured type.

=cut

sub _biblio_is_relevant {
    my ( $self, $biblionumber ) = @_;

    my $item_type = $self->retrieve_data('item_type');
    if ( !$item_type ) {
        return 0;
    }

    if ( $self->_page_lists_biblionumber($biblionumber) ) {
        return 1;
    }

    my $count = Koha::Items->search( { biblionumber => $biblionumber, itype => $item_type } )->count;
    return $count ? 1 : 0;
}

=head2 _page_lists_biblionumber

    if ( $self->_page_lists_biblionumber($biblionumber) ) { ... }

Internal. Checks the stored page content for a tile of the given biblio
(via its data-biblionumber attribute); much cheaper than a full render.

=cut

sub _page_lists_biblionumber {
    my ( $self, $biblionumber ) = @_;

    if ( !$biblionumber ) {

        # Unknown caller shape: treat as relevant, a render is cheap.
        return 1;
    }

    my $content_object = _content_object();
    if ( !$content_object ) {
        return 0;
    }

    my $content = $content_object->content // q{};
    return index( $content, qq{data-biblionumber="$biblionumber"} ) >= 0 ? 1 : 0;
}

=head2 _refresh_page_guarded

    $self->_refresh_page_guarded();

Internal. Runs L</_refresh_page> but never dies: a failed refresh logs a
warning instead of breaking the cataloguing/circulation action that
triggered it. All hook entry points go through here.

=cut

sub _refresh_page_guarded {
    my ($self) = @_;

    # eval is Perl's try/catch; $EVAL_ERROR is the caught error.
    my $ok = eval {
        $self->_refresh_page();
        1;
    };
    if ( !$ok ) {
        carp 'LibraryOfThings: page refresh failed: ' . ( $EVAL_ERROR // 'unknown error' );
    }

    return;
}

=head2 _refresh_page

    $self->_refresh_page();

Internal. Renders the page and stores the result, but only if it differs
from the stored content, so frequent triggers are cheap no-ops. Keeps the
last good content if rendering fails, and does nothing if the page does
not exist (not installed, or removed by a librarian).

=cut

sub _refresh_page {
    my ($self) = @_;

    my $content_object = _content_object();
    if ( !$content_object ) {
        return;
    }

    my $html = $self->_render_page();
    if ( !defined $html ) {

        # Render failed: keep the last good content.
        return;
    }

    if ( ( $content_object->content // q{} ) eq $html ) {
        return;
    }

    $content_object->content($html)->store;

    return;
}

=head2 _page_template

    my $template_content = $self->_page_template();

Internal. Returns the content of the page template (opac-page.tt, bundled
with the plugin), read once per process and cached in C<$PAGE_TEMPLATE>.
Returns undef if the file cannot be read; the page then keeps its last
good content.

=cut

sub _page_template {
    my ($self) = @_;

    if ( defined $PAGE_TEMPLATE ) {
        return $PAGE_TEMPLATE;
    }

    my $path = $self->mbf_path('opac-page.tt');
    if ( !$path ) {
        carp 'LibraryOfThings: bundled template opac-page.tt not found';
        return;
    }

    my $fh;
    if ( !open $fh, '<:encoding(UTF-8)', $path ) {
        carp "LibraryOfThings: cannot read $path: $OS_ERROR";
        return;
    }

    # undef record separator = read the whole file at once (slurp)
    my $content = do { local $INPUT_RECORD_SEPARATOR = undef; <$fh> };
    if ( !close $fh ) {
        carp "LibraryOfThings: cannot close $path: $OS_ERROR";
    }

    $PAGE_TEMPLATE = $content;

    return $PAGE_TEMPLATE;
}

=head2 _texts

    my $texts = $self->_texts();

Internal. Returns the effective page texts as a hashref: for every key in
C<$DEFAULT_TEXTS> the stored override (plugin data "text_<key>") if it is
non-empty, otherwise the German default.

=cut

sub _texts {
    my ($self) = @_;

    my $texts = {};
    for my $key ( sort keys %{$DEFAULT_TEXTS} ) {
        my $stored = $self->retrieve_data("text_$key");
        if ( defined $stored && $stored ne q{} ) {
            $texts->{$key} = $stored;
        }
        else {
            $texts->{$key} = $DEFAULT_TEXTS->{$key};
        }
    }

    return $texts;
}

=head2 _render_page

    my $html = $self->_render_page();

Internal. Renders the page template (see L</_page_template>) with the
current things (see L</_things>) through Template Toolkit (same sandbox as
notices, EVAL_PERL off). Returns the finished HTML, or undef on template
errors.

=cut

sub _render_page {
    my ($self) = @_;

    my $template_content = $self->_page_template();
    if ( !defined $template_content ) {
        return;
    }

    require Template;

    my $tt = Template->new(
        {   EVAL_PERL => 0,
            ABSOLUTE  => 0,
        }
    );

    my $things = $self->_things();

    my $vars = {
        item_type      => $self->retrieve_data('item_type'),
        things         => $things,
        categories     => _filter_categories($things),
        texts          => $self->_texts(),
        plugin_version => $VERSION,
    };

    my $output = q{};
    if ( !$tt->process( \$template_content, $vars, \$output ) ) {
        carp 'LibraryOfThings: template error: ' . $tt->error;
        return;
    }

    return $output;
}

=head2 _content_object

    my $content_object = _content_object();

Internal. Returns the object carrying the page content: the page itself on
the legacy schema, its 'default' localization on the split schema. Returns
undef if the page does not exist.

=cut

sub _content_object {
    my $page = _find_page($PAGE_CODE);
    if ( !$page ) {
        return;
    }

    if ( !_has_split_schema() ) {
        return $page;
    }
    return $page->translated_contents->search( { lang => 'default' } )->next;
}

=head2 _things

    my $things = $self->_things();

Internal. Returns an arrayref with one entry per biblio that has at least
one item of the configured type:

    {
        biblionumber   => 123,
        title          => 'Akku-Bohrschrauber',
        available      => 2,            # items neither checked out, lost nor withdrawn
        is_new         => 1,            # an item was accessioned in the last $NEW_BADGE_DAYS days
        categories     => [ { code => 'WERKZEUG', description => 'Werkzeuge' } ],
        category_codes => 'WERKZEUG',   # space separated, for the data-category attribute
    }

Categories come from the items' collection codes (CCODE authorised
values). Returns an empty arrayref if no item type is configured.

=cut

sub _things {
    my ($self) = @_;

    my $item_type = $self->retrieve_data('item_type');
    if ( !$item_type ) {
        return [];
    }

    my $ccode_descriptions = _ccode_descriptions();
    my $new_cutoff         = dt_from_string()->subtract( days => $self->_new_badge_days() );

    my $things                = [];
    my $thing_by_biblionumber = {};
    my $category_seen         = {};

    # prefetch joins the biblio rows in, so $item->biblio below does not
    # run one query per item (like .include() in a JS ORM).
    my $items = Koha::Items->search( { itype => $item_type }, { prefetch => 'biblio' } );
    while ( my $item = $items->next ) {
        my $biblionumber = $item->biblionumber;

        my $thing = $thing_by_biblionumber->{$biblionumber};
        if ( !$thing ) {
            $thing = {
                biblionumber => $biblionumber,
                title        => $item->biblio->title,
                available    => 0,
                is_new       => 0,
                categories   => [],
            };
            $thing_by_biblionumber->{$biblionumber} = $thing;
            push @{$things}, $thing;
        }

        if ( !$item->onloan && !$item->itemlost && !$item->withdrawn ) {
            $thing->{available}++;
        }

        if ( $item->dateaccessioned && dt_from_string( $item->dateaccessioned ) >= $new_cutoff ) {
            $thing->{is_new} = 1;
        }

        my $ccode = $item->ccode;
        if ( $ccode && !$category_seen->{"$biblionumber/$ccode"} ) {
            $category_seen->{"$biblionumber/$ccode"} = 1;
            push @{ $thing->{categories} },
                {
                code        => $ccode,
                description => $ccode_descriptions->{$ccode} // $ccode,
                };
        }
    }

    for my $thing ( @{$things} ) {
        my $codes = [];
        for my $category ( @{ $thing->{categories} } ) {
            push @{$codes}, $category->{code};
        }
        $thing->{category_codes} = join q{ }, @{$codes};
    }

    return $things;
}

=head2 _new_badge_days

    my $days = $self->_new_badge_days();

Internal. Returns the configured timeframe for the "Neu" ribbon in days:
the stored value (plugin data "new_badge_days") if it is a non-negative
integer, otherwise the default of C<$NEW_BADGE_DAYS>. 0 disables the
ribbon (the cutoff is then in the future of every accession date).

=cut

sub _new_badge_days {
    my ($self) = @_;

    my $stored = $self->retrieve_data('new_badge_days');
    if ( defined $stored && $stored =~ /\A\d+\z/xms ) {
        return $stored;
    }

    return $NEW_BADGE_DAYS;
}

=head2 _ccode_descriptions

    my $descriptions = _ccode_descriptions();

Internal. Returns a hashref mapping collection codes (CCODE authorised
values) to their OPAC description.

=cut

sub _ccode_descriptions {
    my $descriptions = {};

    my $values = Koha::AuthorisedValues->search( { category => 'CCODE' } );
    while ( my $value = $values->next ) {
        $descriptions->{ $value->authorised_value } = $value->opac_description;
    }

    return $descriptions;
}

=head2 _filter_categories

    my $categories = _filter_categories($things);

Internal. Returns the distinct categories across all things, sorted by
description; the page shows one filter button per entry.

=cut

sub _filter_categories {
    my ($things) = @_;

    my $by_code = {};
    for my $thing ( @{$things} ) {
        for my $category ( @{ $thing->{categories} } ) {
            $by_code->{ $category->{code} } = $category;
        }
    }

    my $categories = [ sort { $a->{description} cmp $b->{description} } values %{$by_code} ];

    return $categories;
}

=head2 api_namespace

    my $namespace = $plugin->api_namespace();

Koha plugin hook. Namespace under which the plugin's routes are mounted:
/api/v1/contrib/libraryofthings/. Currently only used for the static
assets, see L</static_routes>.

=cut

sub api_namespace {
    my ($self) = @_;

    return 'libraryofthings';
}

=head2 static_routes

    my $spec = $plugin->static_routes();

Koha plugin hook. Registers the plugin's static files; Koha serves them
from the plugin directory. The page stylesheet and the progressive
enhancement script become available at

    /api/v1/contrib/libraryofthings/static/css/library-of-things.css
    /api/v1/contrib/libraryofthings/static/js/library-of-things.js

which is what the link and script tags in opac-page.tt point at (with the
plugin version as a query parameter, so browsers do not cache stale assets
across plugin upgrades).

=cut

sub static_routes {
    my ( $self, $args ) = @_;

    return {
        '/css/library-of-things.css' => {
            get => {
                'x-mojo-to' => 'Static#get',
                operationId => 'libraryOfThingsStaticCss',
                tags        => ['plugins'],
                produces    => ['text/css'],

                # Declared so the cache-busting ?v= passes Koha's strict
                # query parameter validation (otherwise: 400).
                parameters => [
                    {   name        => 'v',
                        in          => 'query',
                        type        => 'string',
                        description => 'Cache busting plugin version',
                    },
                ],
                responses => {
                    '200' => { description => 'File found' },
                    '404' => { description => 'File not found' },
                },
            },
        },
        '/js/library-of-things.js' => {
            get => {
                'x-mojo-to' => 'Static#get',
                operationId => 'libraryOfThingsStaticJs',
                tags        => ['plugins'],
                produces    => ['text/javascript'],
                parameters  => [
                    {   name        => 'v',
                        in          => 'query',
                        type        => 'string',
                        description => 'Cache busting plugin version',
                    },
                ],
                responses => {
                    '200' => { description => 'File found' },
                    '404' => { description => 'File not found' },
                },
            },
        },
    };
}

=head2 configure

    $plugin->configure();

Koha plugin hook for the configuration form: the item type that marks the
things of the Library of Things, the timeframe for the "Neu" ribbon (see
L</_new_badge_days>) and all texts of the OPAC page (see
C<$DEFAULT_TEXTS>; empty fields fall back to the German defaults). Saving
(POST, op 'cud-save') requires a valid CSRF token (see
L</_csrf_token_is_valid>), validates item type and timeframe, stores
everything and re-renders the page; an empty item type unsets the
configuration so the page shows its empty state.

=cut

sub configure {
    my ( $self, $args ) = @_;

    my $cgi = $self->{cgi};

    my $op         = $cgi->param('op') // q{};
    my $saved      = 0;
    my $save_error = 0;
    my $days_error = 0;
    my $csrf_error = 0;
    if ( $op eq 'cud-save' ) {
        my $item_type      = scalar $cgi->param('item_type')      // q{};
        my $new_badge_days = scalar $cgi->param('new_badge_days') // q{};

        if ( !_csrf_token_is_valid($cgi) ) {
            $csrf_error = 1;
        }
        elsif ( $item_type ne q{} && !Koha::ItemTypes->find($item_type) ) {
            $save_error = 1;
        }
        elsif ( $new_badge_days ne q{} && $new_badge_days !~ /\A\d+\z/xms ) {
            $days_error = 1;
        }
        else {
            my $values = {
                item_type      => $item_type,
                new_badge_days => $new_badge_days,
            };
            for my $key ( sort keys %{$DEFAULT_TEXTS} ) {
                $values->{"text_$key"} = scalar $cgi->param("text_$key") // q{};
            }
            $self->store_data($values);
            $self->_refresh_page_guarded();
            $saved = 1;
        }
    }

    my $template = $self->get_template( { file => 'configure.tt' } );
    $template->param(
        item_type      => $self->retrieve_data('item_type'),
        item_types     => Koha::ItemTypes->search_with_localization,
        new_badge_days => $self->_new_badge_days(),
        texts          => $self->_texts(),
        csrf_token     => Koha::Token->new->generate_csrf( { session_id => scalar $cgi->cookie('CGISESSID') // q{} } ),
        saved          => $saved,
        save_error     => $save_error,
        days_error     => $days_error,
        csrf_error     => $csrf_error,
    );

    $self->output_html( $template->output() );

    return;
}

=head2 _csrf_token_is_valid

    if ( _csrf_token_is_valid($cgi) ) { ... }

Internal. Validates the plugin's own CSRF token (form field
lot_csrf_token, bound to the CGISESSID session). Newer Koha versions
already enforce a CSRF token for every POST centrally, but the plugin's
minimum version 22.11 does not; without this check a forged cross-site
POST could change the configuration there, including the raw HTML text
fields shown to every OPAC visitor. Runs in addition to the central
check, that is harmless.

=cut

sub _csrf_token_is_valid {
    my ($cgi) = @_;

    my $session_id = $cgi->cookie('CGISESSID')            // q{};
    my $token      = scalar $cgi->param('lot_csrf_token') // q{};
    if ( $session_id eq q{} || $token eq q{} ) {
        return 0;
    }

    my $is_valid = Koha::Token->new->check_csrf(
        {   session_id => $session_id,
            token      => $token,
        }
    );

    return $is_valid ? 1 : 0;
}

1;
