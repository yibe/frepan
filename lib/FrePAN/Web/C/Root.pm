package FrePAN::Web::C::Root;
use Amon::Web::C;

sub index {
    my $page = param('page') || 1;
    $page =~ /^[0-9]+$/ or die "bad page number: $page";
    my $rows_per_page = 20;

    my @entries = db->search_by_sql(
        "SELECT dist.*, changes.body AS diff, meta_author.email AS email FROM dist LEFT JOIN changes ON (changes.dist_id=dist.dist_id) LEFT JOIN meta_author ON ( meta_author.pause_id=dist.author) ORDER BY released DESC LIMIT @{[ $rows_per_page + 1 ]} OFFSET @{[ $rows_per_page*($page-1) ]}"
    );
    my $has_next =  ($rows_per_page+1 == @entries);
    if ($has_next) { pop @entries }

    for (@entries) {
        $_->{gravatar_url} = model('CPAN')->email2gravatar_url($_->email);
    }
    render("index.mt", \@entries, $page, $has_next);
}

sub about {
    render('about.mt')
}

1;
