package FrePAN::DB::Row::Dist;
use strict;
use warnings;
use parent qw/DBIx::Skinny::Row/;
use Amon2::Declare;
use Log::Minimal;
use Smart::Args;
use autodie;
use File::Spec;
use FrePAN::M::CPAN;
use LWP::UserAgent;
use Path::Class;
use Try::Tiny;
use FrePAN::M::Archive;
use FrePAN::Pod;

sub download_url {
    my ($self) = @_;
    my $base = time() - $self->released > 24*60*60 ?
        'http://search.cpan.org/CPAN/authors/id/'
        : 'http://cpan.cpantesters.org/authors/id/';
    return $base . $self->path;
}

sub mirror_archive {
    my $self = shift;

    my $dstpath = file($self->archive_path);
    unless ( -f $dstpath ) {
        my $url = $self->download_url;
        debugf "mirror '$url' to '$dstpath'";
        my $ua = LWP::UserAgent->new(agent => "FrePAN/$FrePAN::VERSION");
        make_path($dstpath->dir->stringify);
        my $res = $ua->get($url, ':content_file' => "$dstpath");
        $res->code =~ /^(?:304|200)$/ or die "fetch failed: $url, $dstpath, " . $res->status_line;
    }
    return;
}

sub extract_archive {
    my $self = shift;

    FrePAN::M::Archive->extract(
        dist_name    => $self->name,
        version      => $self->version,
        archive_path => $self->archive_path,
        srcdir       => c->config()->{srcdir},
        author       => $self->author,
        c            => c(),
    );
}

sub load_meta {
    args my $self,  my $dir;

    my $json_file = file($dir, 'META.json');
    my $yml_file = file($dir, 'META.yml');

    if (-f $json_file) {
        try {
            my $fh = $json_file->openr;
            my $src = do { local $/; <$fh> };
            decode_json($src);
        } catch {
            warn "cannot open META.json file: $_";
            +{};
        };
    } elsif (-f $yml_file) {
        try {
            YAML::Tiny::LoadFile("$yml_file");
        } catch {
            warn "Cannot parse META.yml($dir): $_";
            +{};
        };
    } else {
        infof("missing META file in $dir");
        +{};
    }
}

# insert to 'file' table.
sub insert_files {
    args my $self,
         my $meta,
         my $dir,
         my $c,
         ;

    my $txn = $c->db->txn_scope();

    my $no_index = join '|', map { quotemeta $_ } @{
        do {
            my $x = $meta->{no_index}->{directory} || [];
            $x = [$x] unless ref $x; # http://cpansearch.perl.org/src/CFAERBER/Net-IDN-Nameprep-1.100/META.yml
            $x;
          }
      };
       $no_index = qr/^(?:$no_index)/ if $no_index;

    # remove old things
    $c->db->dbh->do(q{DELETE FROM file WHERE dist_id=?}, {}, $self->dist_id) or die;

    my $guard = FrePAN::CwdSaver->new($dir);

    dir('.')->recurse(
        callback => sub {
            my $f = shift;
            return if -d $f;
            debugf("processing $f");

            if ($f =~ /(?:\.PL)$/ || $f =~ /MANIFEST\.SKIP$/) {
                return;
            }
            unless ($f =~ /(?:\.pm|\.pod)$/) {
                my $fh = $f->openr or return;
                read $fh, my $buf, 1024;
                if ($buf !~ /#!.+perl/) { # script contains shebang
                    return;
                }
            }
            if ($no_index && "$f" =~ $no_index) {
                return;
            }
            # lib/auto/ is a workaround for http://search.cpan.org/~schwigon/Benchmark-Perl-Formance-Cargo-0.02/
            if ("$f" =~ m{(^|/)(?:t/|inc/|sample/|blib/|lib/auto/)} || "$f" eq './Build.PL') {
                return;
            }
            debugf("do processing $f");
            my $parser = FrePAN::Pod->new();
            $parser->parse_file("$f") or do {
                critf("Cannot parse pod: %s", $parser->error);
                return;
            };

            my $path = $f->relative->stringify;
            $c->db->insert(
                file => {
                    dist_id     => $self->dist_id,
                    path        => $path,
                    'package'   => $parser->package(),
                    description => $parser->description(),
                    html        => $parser->html(),
                }
            );
        }
    );

    $txn->commit;

    return;
}

sub files {
    my ($self) = @_;
    c->db->search(file => {dist_id => $self->dist_id});
}

sub delete_files {
    my ($self) = @_;
    c->dbh->do(q{DELETE FROM file WHERE dist_id=?}, {}, $self->dist_id);
}

sub remove_from_fts {
    my ($self) = @_;
    for my $file ($self->files()) {
        c->fts->delete($file->file_id);
    }
}

sub insert_to_fts {
    my ($self) = @_;

    if ($self->version =~ /_/) {
        infof("This is a developer release(%s). Do not register to groonga", $self->version);
        return;
    }

    # remove old entries
    {
        my @old_dists = c->db->search(dist => {name => $self->name});
        for my $old_dist (@old_dists) {
            $old_dist->remove_from_fts();
        }
    }

    # insert to fts
    for my $file ($self->files) {
        $file->insert_to_fts() if $file->html();
    }
}

sub archive_path {
    args_pos my $self;

    my $minicpan = c->config->{'M::CPAN'}->{minicpan} // die;

    return File::Spec->catfile(
        $minicpan,
        'authors', 'id',
        $self->path
    );
}

sub delete {
    my $self = shift;

    if (-f $self->archive_path) {
        unlink $self->archive_path();
    }

    $self->remove_from_fts();
    $self->delete_files();

    $self->SUPER::delete();
}

sub extracted_dir {
    args_pos my $self;

    my $srcdir = c->config()->{srcdir} // die "missing counfiguration for srcdir";
    return File::Spec->catdir($srcdir, $self->author, $self->name . '-' . $self->version);
}

sub author_dir {
    args_pos my $self;

    my $srcdir = c->config()->{srcdir} // die "missing counfiguration for srcdir";
    return File::Spec->catdir($srcdir, $self->author);
}

sub last_release {
    args_pos my $self;

    c->db->single(dist => {
        released => { '<', $self->released },
        name     => $self->name,
    }, {order_by => {released => 'DESC'}, limit => 1});
}

sub get_changes {
    args_pos my $self;

    my $base = $self->extracted_dir();
    for my $name (qw/CHANGES Changes ChangeLog/) {
        my $fname = File::Spec->catfile($base, $name);
        next unless -f $fname;

        open my $fh, '<', $fname or die "cannot open file: $fname, $!";
        return do { local $/; <$fh> };
    }
    return undef;
}

sub relative_url {
    args_pos my $self;

    sprintf('/~%s/%s-%s/', lc($self->author), $self->name, $self->version);
}

1;
