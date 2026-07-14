#!/usr/bin/perl

# Must run in a Koha environment (kshell/ktd or a dev box), e.g.:
#
#   cd /path/to/koha
#   PERL5LIB=.:/path/to/library-of-things prove -v /path/to/library-of-things/t/opac-page-ssr.t
#
# (KOHA_CONF must point to a test/dev instance; all changes run inside a
# transaction and are rolled back at the end. The test resets the plugin
# state at the start, so it also runs on instances where the plugin is
# installed and configured.)

use Modern::Perl;

use Test::More;

use t::lib::TestBuilder;

use Koha::AdditionalContents;
use Koha::Database;
use Koha::DateUtils qw( dt_from_string );

use Koha::Plugin::De::StadtbuechereiTuebingen::LibraryOfThings;

our $VERSION = '1.0.0';

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

$schema->storage->txn_begin;

my $plugin = Koha::Plugin::De::StadtbuechereiTuebingen::LibraryOfThings->new( { enable_plugins => 1 } );

# Split schema (Koha >= 23.11): title/content/lang live in
# additional_contents_localizations instead of additional_contents.
my $additional_contents_source = Koha::Database->new->schema->source('AdditionalContent');
my $split                      = $additional_contents_source->has_column('lang') ? 0 : 1;

# Clean slate inside the transaction: remove a pre-existing page and unset
# the configuration, so the test also runs on a configured instance.
my $existing_pages = Koha::AdditionalContents->search(
    {   category => 'pages',
        code     => 'libraryofthings',
        location => 'opac_only',
    }
);
while ( my $page = $existing_pages->next ) {
    if ($split) {
        $page->translated_contents->delete;
    }
    $page->delete;
}
$plugin->store_data( { item_type => q{}, text_intro => q{}, new_badge_days => q{} } );

# Returns the object carrying the page content: the page itself on the legacy
# schema, its 'default' localization on the split schema.
sub content_object {
    my $page = Koha::AdditionalContents->search(
        {   category => 'pages',
            code     => 'libraryofthings',
            location => 'opac_only',
        }
    )->next;

    if ( !$page ) {
        return;
    }
    if ( !$split ) {
        return $page;
    }
    return $page->translated_contents->search( { lang => 'default' } )->next;
}

# Extracts the rendered tile markup for one biblio from the page HTML.
sub tile_for {
    my ( $html, $biblionumber ) = @_;

    if ( $html =~ m{( <a \s+ class="lot-tile" \s+ data-biblionumber="$biblionumber" .*? </a> )}xms ) {
        return $1;
    }
    return q{};
}

subtest 'install creates the OPAC page with materialized content' => sub {
    plan tests => 6;

    ok( $plugin->install, 'install runs through' );

    my $content_object = content_object();
    ok( $content_object, 'page exists in additional_contents' );

    # The page stores finished HTML, not the template
    unlike( $content_object->content, qr/\[%/xms, 'stored content contains no TT directives' );

    my $static_route = qr{/api/v1/contrib/libraryofthings/static}xms;
    like( $content_object->content, qr{$static_route/css/library-of-things[.]css[?]v=}xms, 'stylesheet is linked via the plugin static route' );
    like( $content_object->content, qr{$static_route/js/library-of-things[.]js[?]v=}xms,   'enhancement script is linked via the plugin static route' );

    # No item type configured yet -> empty state
    like( $content_object->content, qr/Aktuell\s+sind\s+keine\s+Dinge/xms, 'empty state rendered before configuration' );
};

subtest 'data changes re-render the page instantly' => sub {
    plan tests => 24;

    # Fixtures: an item type marking the things, two biblios with items of
    # that type (one of them twice, to prove one tile per biblio); plus a
    # text override to prove the configurable texts reach the page
    my $item_type = $builder->build_object( { class => 'Koha::ItemTypes' } );
    $plugin->store_data( { item_type => $item_type->itemtype, text_intro => 'Custom Intro 4711' } );

    my $drill          = $builder->build_sample_biblio( { title => 'Akku-Bohrschrauber GSR 12V' } );
    my $sewing         = $builder->build_sample_biblio( { title => 'Naehmaschine W6 N 2800' } );
    my $drill_item_new = $builder->build_sample_item( { biblionumber => $drill->biblionumber,  itype => $item_type->itemtype } );
    my $drill_item_old = $builder->build_sample_item( { biblionumber => $drill->biblionumber,  itype => $item_type->itemtype } );
    my $sewing_item    = $builder->build_sample_item( { biblionumber => $sewing->biblionumber, itype => $item_type->itemtype } );

    # Accession dates decide the "Neu" ribbon; a category code becomes a
    # filter button (without a CCODE authorised value the code itself is
    # the label)
    $drill_item_new->set( { dateaccessioned => dt_from_string()->ymd } )->store;
    $drill_item_old->set( { dateaccessioned => '2020-01-01' } )->store;
    $sewing_item->set( { dateaccessioned => '2020-01-01', ccode => 'LOTCAT1' } )->store;

    # TestBuilder bypasses the plugin hooks, so fire one as Koha would
    $plugin->after_item_action( { action => 'create' } );

    my $html = content_object()->content;
    like( $html, qr/Akku-Bohrschrauber\s+GSR\s+12V/xms, 'first thing shows up as a tile' );
    like( $html, qr/Naehmaschine\s+W6\s+N\s+2800/xms,   'second thing shows up as a tile' );
    unlike( $html, qr/Aktuell\s+sind\s+keine\s+Dinge/xms, 'empty state replaced by the grid' );
    like( $html, qr/Custom\s+Intro\s+4711/xms, 'configured text override is rendered' );

    my $tiles = [ $html =~ /class="lot-tile"/gxms ];
    is( scalar @{$tiles}, 2, 'one tile per biblio, not per item' );

    unlike( $html, qr/\[%/xms, 'no TT directives in the output' );
    note "Rendered:\n$html";

    like( tile_for( $html, $drill->biblionumber ), qr/lot-ribbon/xms, 'recently accessioned thing gets the ribbon' );
    unlike( tile_for( $html, $sewing->biblionumber ), qr/lot-ribbon/xms, 'old thing gets no ribbon' );

    # The "Neu" timeframe is configurable; 0 disables the ribbon, an empty
    # value falls back to the default of 30 days
    $plugin->store_data( { new_badge_days => '0' } );
    $plugin->after_biblio_action( { action => 'modify', biblio_id => $drill->biblionumber } );
    unlike( content_object()->content, qr/lot-ribbon/xms, 'new_badge_days 0 disables the ribbon' );
    $plugin->store_data( { new_badge_days => q{} } );
    $plugin->after_biblio_action( { action => 'modify', biblio_id => $drill->biblionumber } );
    like( content_object()->content, qr/lot-ribbon/xms, 'empty new_badge_days falls back to the default' );

    like( $html,                                    qr/data-filter="LOTCAT1"/xms,   'collection code becomes a filter button' );
    like( tile_for( $html, $sewing->biblionumber ), qr/data-category="LOTCAT1"/xms, 'tile carries its category' );

    like( tile_for( $html, $sewing->biblionumber ), qr/lot-available/xms, 'thing with a free item shows as available' );

    # Checkout: the item goes on loan, the badge flips instantly
    $sewing_item->set( { onloan => '2026-06-11' } )->store;
    $plugin->after_circ_action( { action => 'checkout' } );

    $html = content_object()->content;
    unlike( tile_for( $html, $sewing->biblionumber ), qr/lot-available/xms, 'checked-out thing shows as unavailable' );
    like( tile_for( $html, $drill->biblionumber ), qr/lot-available/xms, 'other things stay available' );

    # Holds: a reserved item is not available. Reserve both of the drill's
    # items (reservedate today, not suspended, so current_holds counts them)
    # and the tile flips, driven by the hold hook Koha would fire.
    my $drill_hold;
    for my $drill_item ( $drill_item_new, $drill_item_old ) {
        $drill_hold = $builder->build_object(
            {   class => 'Koha::Holds',
                value => {
                    biblionumber => $drill->biblionumber,
                    itemnumber   => $drill_item->itemnumber,
                    reservedate  => dt_from_string()->ymd,
                    waitingdate  => undef,
                    found        => undef,
                    suspend      => 0,
                    priority     => 1,
                },
            }
        );
    }
    $plugin->after_hold_action( { action => 'place', payload => { hold => $drill_hold } } );

    $html = content_object()->content;
    unlike( tile_for( $html, $drill->biblionumber ), qr/lot-available/xms, 'reserved thing shows as unavailable' );

    # Irrelevant changes (other item type, biblio not on the page) skip
    # the refresh entirely, so batch jobs stay cheap
    content_object()->content('<p>manually edited</p>')->store;
    my $other_type     = $builder->build_object( { class => 'Koha::ItemTypes' } );
    my $unrelated      = $builder->build_sample_biblio( { title => 'Unrelated title' } );
    my $unrelated_item = $builder->build_sample_item( { biblionumber => $unrelated->biblionumber, itype => $other_type->itemtype } );

    $plugin->after_item_action( { action => 'create', item => $unrelated_item } );
    like( content_object()->content, qr/manually\s+edited/xms, 'irrelevant item change skips the refresh' );

    $plugin->after_biblio_action( { action => 'modify', biblio_id => $unrelated->biblionumber } );
    like( content_object()->content, qr/manually\s+edited/xms, 'irrelevant biblio change skips the refresh' );

    # Newer Koha versions pass item/biblio_id inside payload instead of at
    # the top level; the guards must understand both shapes
    $plugin->after_item_action( { action => 'create', payload => { item => $unrelated_item } } );
    like( content_object()->content, qr/manually\s+edited/xms, 'payload-shaped item params are understood' );

    $plugin->after_biblio_action( { action => 'modify', payload => { biblio_id => $unrelated->biblionumber } } );
    like( content_object()->content, qr/manually\s+edited/xms, 'payload-shaped biblio params are understood' );

    my $unrelated_checkout = $builder->build_object(
        {   class => 'Koha::Checkouts',
            value => { itemnumber => $unrelated_item->itemnumber },
        }
    );
    $plugin->after_circ_action( { action => 'checkout', payload => { checkout => $unrelated_checkout } } );
    like( content_object()->content, qr/manually\s+edited/xms, 'irrelevant checkout skips the refresh' );

    my $sewing_checkout = $builder->build_object(
        {   class => 'Koha::Checkouts',
            value => { itemnumber => $sewing_item->itemnumber },
        }
    );
    $plugin->after_circ_action( { action => 'checkout', payload => { checkout => $sewing_checkout } } );
    like( content_object()->content, qr/lot-grid/xms, 'relevant checkout re-renders the page' );

    # A manual edit of the page is overwritten on the next relevant change
    content_object()->content('<p>manually edited</p>')->store;
    $plugin->after_biblio_action( { action => 'modify', biblio_id => $drill->biblionumber } );
    like( content_object()->content, qr/Akku-Bohrschrauber/xms, 'manual edits are overwritten on refresh' );

    # A broken template must not take the page down: keep last good content
    # ([% IF %] is a complete but invalid directive, so TT really fails;
    # an unclosed [% would be treated as plain text)
    my $previous_template = $Koha::Plugin::De::StadtbuechereiTuebingen::LibraryOfThings::PAGE_TEMPLATE;
    $Koha::Plugin::De::StadtbuechereiTuebingen::LibraryOfThings::PAGE_TEMPLATE = '<p>[% IF %]</p>';
    $plugin->after_item_action( { action => 'modify' } );
    $Koha::Plugin::De::StadtbuechereiTuebingen::LibraryOfThings::PAGE_TEMPLATE = $previous_template;
    like( content_object()->content, qr/Akku-Bohrschrauber/xms, 'TT error: last good content kept' );
};

subtest 'uninstall cleans up' => sub {
    plan tests => 2;

    ok( $plugin->uninstall, 'uninstall runs through' );
    is( content_object(), undef, 'page is removed' );
};

$schema->storage->txn_rollback;

done_testing();
