package FrePAN::M::Search;
use strict;
use warnings;
use utf8;
use Log::Minimal;
use Time::Duration ();
use SQL::Interp qw/sql_interp/;
use Smart::Args;
use Data::Page;
use FrePAN::FTS;

sub search_module {
    args my $class,
         my $c,
         my $query,
         my $page,
         my $rows => {isa => 'Int', default => 1024},
         ;

    return ([], Data::Page->new(0, $rows, $page)) unless $query =~ /\S/;

    my $search_result = $c->fts->search(query => $query, page => $page, rows => $rows);
    my $file_infos = $search_result->rows;
    # debugf("FILES IDS: %s", ddf($file_infos));

    if ($search_result->pager->total_entries == 0) {
        return ([], $search_result->pager);
    }

    # get "I use this" info for scoring
    my $cache_ver = $c->is_devel ? rand : 1;
    my $i_use_this = +{
        map { $_->[0] => $_->[1] } @{
            $c->dbh->selectall_arrayref(
                q{select SQL_CACHE dist_name, count(*) from i_use_this group by dist_name;}
            )
          }
    };

    my ($sql, @binds) = q{
        SELECT SQL_CACHE
            file.file_id, file.package, file.description, file.path,
            dist.dist_id, dist.author, dist.name AS dist_name, dist.version AS dist_version, dist.released AS dist_released,
            meta_author.fullname AS fullname
        FROM file
            INNER JOIN dist ON (dist.dist_id=file.dist_id)
            LEFT JOIN meta_author ON (meta_author.pause_id=dist.author)
        WHERE file_id IN (} . join(',', ('?')x@$file_infos) . ')';

    my %files =
      map { $_->{file_id} => $_ } @{
        $c->dbh->selectall_arrayref(
            $sql,
            { Slice => +{} },
            map { $_->{file_id} } @$file_infos
        )
      };

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
            $rdbms_row->{score} *= 20;
        }
        # if the query matched to package prefix, give the 2x score
        if (index(lc($rdbms_row->{package}), lc($query)) == 0) {
            $rdbms_row->{score} *= 5;
        }
        # i use this!
        if (exists $i_use_this->{$rdbms_row->{dist_name}}) {
            $rdbms_row->{score} *= $i_use_this->{$rdbms_row->{dist_name}}+7;
            $rdbms_row->{i_use_this_cnt} = $i_use_this->{$rdbms_row->{dist_name}};
        }
        # give low score for module released at older than 2005-01-01
        if ($rdbms_row->{dist_released} < 1104537600) {
            $rdbms_row->{score} /= (1104537600-$rdbms_row->{dist_released})/(24*60*60*365);
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

    return (\@files, $search_result->pager);
}

sub search_author {
    args my $class,
         my $c,
         my $query,
         my $limit => {isa => 'Int', default => 3},
         ;

    # escape for LIKE
    $query =~ s!_!\\_!g;
    $query =~ s!%!\\%!g;

    return @{
        $c->dbh->selectall_arrayref(
            q{SELECT pause_id, fullname FROM meta_author WHERE pause_id LIKE CONCAT(?, '%') OR fullname LIKE CONCAT(?, '%') LIMIT ?},
            { Slice => {} }, $query, $query, $limit
        )
      };
}

1;

