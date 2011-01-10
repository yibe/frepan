package FrePAN::Web::C::Search;
use strict;
use warnings;
use utf8;
use Log::Minimal;
use SQL::Interp qw/sql_interp/;
use Data::Page;

sub result {
    my ($class, $c) = @_;
    my $page = $c->req->param('page') // 1;
    my $query = $c->req->param('q') || return $c->redirect('/');
    my $search_result = $c->fts->search(query => $query, page => $page, rows => 1024);
    my $file_infos = $search_result->rows;
    debugf("FILES IDS: %s", ddf($file_infos));
    my ($sql, @binds) = sql_interp(q{
        SELECT
            file.*,
            dist.dist_id, dist.author, dist.name AS dist_name, dist.version AS dist_version, dist.released AS dist_released,
            meta_author.fullname AS fullname
        FROM file
            INNER JOIN dist ON (dist.dist_id=file.dist_id)
            LEFT JOIN meta_author ON (meta_author.pause_id=dist.author)
        WHERE file_id IN }, [map { $_->{file_id} } @$file_infos]);
      warn ddf(@{$c->dbh->selectall_arrayref( $sql, {Slice => +{}}, @binds )});
    my %files =
      map { $_->{file_id} => $_ }
      @{$c->dbh->selectall_arrayref( $sql, {Slice => +{}}, @binds )};
    my @files;
    for my $row (@$file_infos) {
        my $fid = $row->{file_id};
        my $rdbms_row = $files{$fid};
        unless ($rdbms_row) {
            # warnf("not matched: $fid");
            next;
        }
        $rdbms_row->{score} = $row->{score};
        # if the query matched to package name, give the 10x score.
        if (lc($rdbms_row->{package}) eq lc($query)) {
            $rdbms_row->{score} *= 10;
        }
        # if the query matched to package prefix, give the 2x score
        if (index(lc($rdbms_row->{package}), lc($query)) == 0) {
            $rdbms_row->{score} *= 2;
        }
        push @files, $rdbms_row;
    }

    # sort by files
    @files = reverse sort { $a->{score} <=> $b->{score} } @files;

    # show only one package in dist.
    my %seen;
    @files = grep { !($seen{$_->{'dist_id'}}++) } @files;

    my $now = time();
    for (@files) {
        $_->{timestamp} = Time::Duration::ago($now - $_->{'dist_released'}, 1);
    }
    debugf("FILES IDS: %s", ddf([map { $_->{file_id} } @files]));
    if ($c->req->param('ajax')) {
        return $c->render('search/result-ajax.tx', {files => \@files, pager => $search_result->pager});
    } else {
        return $c->render('search/result.tx', {files => \@files, query => $query, pager => $search_result->pager});
    }
}

1;

