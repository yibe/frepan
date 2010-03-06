package FrePAN::Web::Dispatcher;
use Amon::Web::Dispatcher;
use 5.010;

sub dispatch {
    my ($class, $c) = @_;
    warn "@_";
    my $path = $c->request->path_info;
    if ($path eq '/') {
        call('Root', 'index');
    } elsif ($path =~ m{^/~(?<author>[^/]+)/(?<dist_ver>[^/]+)/$}) {
        call('Dist', 'show', $+{author}, $+{dist_ver});
    } elsif ($path =~ m{^/~(?<author>[^/]+)/(?<dist_ver>[^/]+)/(?<path>.+)$}) {
        call('Dist', 'show_file', $+{author}, $+{dist_ver}, $+{path});
    } else {
        res_404();
    }
}

1;
