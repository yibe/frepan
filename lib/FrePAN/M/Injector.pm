package FrePAN::M::Injector;
use strict;
use warnings;
use autodie;

use FrePAN::FTS;
use Algorithm::Diff;
use CPAN::DistnameInfo;
use Carp ();
use Cwd;
use Data::Dumper;
use DateTime;
use File::Basename;
use File::Find::Rule;
use File::Path qw/rmtree make_path mkpath/;
use Guard;
use JSON::XS;
use LWP::UserAgent;
use Path::Class;
use RPC::XML::Client;
use RPC::XML;
use Try::Tiny;
use URI;
use YAML::Tiny;
use Smart::Args;
use Log::Minimal;
use FrePAN::DB::Row::File;
use FrePAN::CwdSaver;

use Amon2::Declare;

use FrePAN::M::CPAN;
use FrePAN::M::Archive;
use FrePAN::M::RSSMaker;
use FrePAN::Pod;

our $DEBUG;
our $PATH;

sub p { warn "DEPRECATED" }

sub inject {
    args my $class,
         my $path => 'Str',
         my $released => {isa => 'Int'},  # in epoch time
         my $name => 'Str',
         my $version => 'Str',
         my $author => 'Str',
         my $force => {default => 0, isa => 'Bool'},
         ;
    infof("Run $path");

    local $PATH = $path;

    my $c = c();

    # transaction
    my $txn = $c->db->txn_scope;

    {
        my $dist = $c->db->single(
            dist => {
                name    => $name,
                version => $version,
                author  => $author,
            },
        );
        if ($dist && !$force) {
            infof("already processed: $name, $version, $author");
            $txn->rollback();
            return;
        }
    }

    # fetch archive
    my $archivepath = file(FrePAN::M::CPAN->minicpan_path(), 'authors', 'id', $path)->absolute;
    debugf "$archivepath, $path";
    unless ( -f $archivepath ) {
        my $url = 'http://cpan.cpantesters.org/authors/id/' . $path;
        $class->mirror($url, $archivepath);
    }

    # extract and chdir
    my $extracted_dir = do {
        my $distnameinfo = CPAN::DistnameInfo->new($path);
        FrePAN::M::Archive->extract(
            dist_name    => $name,
            version      => $version,
            archive_path => "$archivepath",
            srcdir       => $c->config()->{srcdir},
            author       => $author,
            c            => $c,
        );
    };
    infof("extracted directory is: $extracted_dir");

    my $guard = FrePAN::CwdSaver->new($extracted_dir);

    # render and register files.
    my $meta = $class->load_meta(dir => $extracted_dir);
    my $requires = $meta->{requires};

    $c->db->do(q{UPDATE dist SET old=1 WHERE name=?}, {}, $name);

    debugf 'creating database entry';
    my $dist = $c->db->find_or_create(
        dist => {
            name    => $name,
            version => $version,
            author  => $author,
        }
    );
    $dist->update(
        {
            path     => $path,
            released => $released,
            requires => scalar($requires ? encode_json($requires) : ''),
            abstract => $meta->{abstract},
            resources_json  => $meta->{resources} ? encode_json($meta->{resources}) : undef,
            has_meta_yml    => ( -f 'META.yml'    ? 1 : 0 ),
            has_meta_json   => ( -f 'META.json'   ? 1 : 0 ),
            has_manifest    => ( -f 'MANIFEST'    ? 1 : 0 ),
            has_makefile_pl => ( -f 'Makefile.PL' ? 1 : 0 ),
            has_changes     => ( -f 'Changes'     ? 1 : 0 ),
            has_change_log  => ( -f 'ChangeLog'   ? 1 : 0 ),
            has_build_pl    => ( -f 'Build.PL'    ? 1 : 0 ),
            old             => 0,
        }
    );

    debugf 'removing symlinks';
    $class->remove_symlinks(dir => $extracted_dir);

    debugf 'generating file table';
    $class->insert_files(
        meta     => $meta,
        dir      => $extracted_dir,
        c        => $c,
        dist     => $dist,
    );

    debugf("register to groonga");
    $dist->insert_to_fts();

    # save changes
    debugf 'make diff';
    $class->make_changes_diff(c => $c, dist => $dist);


    # regen rss
    debugf 'regenerate rss';
    FrePAN::M::RSSMaker->generate();

    unless ($DEBUG) {
        debugf 'sending ping';
        my $result = $class->send_ping();
        critf(ref($result) ? ddf($result->value) : "Error: $result");
    }

    debugf 'commit';
    $txn->commit;

    debugf "finished job";
}

sub make_changes_diff {
    args my $class,
        my $dist,
        my $c,
        ;

    my $old = $dist->last_release();
    unless ($old) {
        infof("cannot retrieve last_release info");
        return;
    }

    my $old_changes = $old->get_changes();
    my $new_changes = $dist->get_changes();

    my $diff = do {
        if ($old_changes && $new_changes) {
            infof("make diff");
            make_diff($old_changes, $new_changes);
        } elsif ($old_changes) {
            infof("old changes file is available");
            $old_changes
        } elsif ($new_changes) {
            infof("missing old changes");
            $new_changes;
        } else {
            infof("no changes file is available");
            "no changes file";
        }
    };
    infof("diff is : %s", ddf($diff));
    $c->db->do(q{INSERT INTO changes (dist_id, version, body) VALUES (?,?,?)
                    ON DUPLICATE KEY UPDATE body=?}, {}, $dist->dist_id, $dist->version, $diff, $diff);
}

sub send_ping {
    my $result =
        RPC::XML::Client->new('http://ping.feedburner.com/')
        ->send_request( 'weblogUpdates.ping',
        "Yet Another CPAN Recent Changes",
        "http://frepan.64p.org/" );
    return $result;
}

sub make_diff {
    my ($old, $new) = @_;
    my $res = '';
    my $diff = Algorithm::Diff->new(
        [ split /\n/, $old ],
        [ split /\n/, $new ],
    );
    $diff->Base(1);
    while ($diff->Next()) {
        next if $diff->Same();
        $res .= "$_\n" for $diff->Items(2);
    }
    return $res;
}

sub write_file {
    my ($fname, $content) = @_;
    open my $fh, '>', $fname;
    print {$fh} $content;
    close $fh;
}

sub load_meta {
    args my $class,
         my $dir,
    ;

    my $guard = FrePAN::CwdSaver->new($dir);

    if (-f 'META.json') {
        try {
            open my $fh, '<', 'META.json';
            my $src = do { local $/; <$fh> };
            decode_json($src);
        } catch {
            warn "cannot open META.json file: $_";
            +{};
        };
    } elsif (-f 'META.yml') {
        try {
            YAML::Tiny::LoadFile('META.yml');
        } catch {
            warn "Cannot parse META.yml($dir): $_";
            +{};
        };
    } else {
        infof("missing META file in $dir");
        +{};
    }
}

sub mirror {
    my ($self, $url, $dstpath) = @_;

    debugf "mirror '$url' to '$dstpath'";
    my $ua = LWP::UserAgent->new(agent => "FrePAN/$FrePAN::VERSION");
    make_path($dstpath->dir->stringify, {error => \my $err});
    if (@$err) {
        for my $diag (@$err) {
            my ( $file, $message ) = %$diag;
            print "mkpath: error: '@{[ $file || '' ]}', $message\n";
        }
    }
    my $res = $ua->get($url, ':content_file' => "$dstpath");
    $res->code =~ /^(?:304|200)$/ or die "fetch failed: $url, $dstpath, " . $res->status_line;
}

# insert to 'file' table.
sub insert_files {
    args my $class,
         my $meta,
         my $dir,
         my $c,
         my $dist => {isa => 'FrePAN::DB::Row::Dist'},
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
    $c->db->dbh->do(q{DELETE FROM file WHERE dist_id=?}, {}, $dist->dist_id) or die;

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
            if ("$f" =~ m{^(?:t/|inc/|sample/|blib/)} || "$f" eq './Build.PL') {
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
                    dist_id     => $dist->dist_id,
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

sub remove_symlinks {
    args my $class,
         my $dir,
         ;

    # Some dists contains symlinks.
    # symlinks cause deep recursion, or security issue.
    # I should remove it first.
    # e.g. C/CM/CMORRIS/Parse-Extract-Net-MAC48-0.01.tar.gz
    debugf 'removing symlinks';
    File::Find::Rule->new()
                    ->symlink()
                    ->exec( sub {
                        debugf("unlink symlink $_");
                        unlink $_;
                    } )
                    ->in($dir);
}

1;
