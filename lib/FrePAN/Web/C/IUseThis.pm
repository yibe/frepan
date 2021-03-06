package FrePAN::Web::C::IUseThis;
use strict;
use warnings;
use utf8;

sub ranking {
    my ($class, $c) = @_;

    my $ranking = $c->dbh->selectall_arrayref(
        q{SELECT dist.name, dist.version, dist.author, COUNT(*) AS cnt
         FROM i_use_this
            INNER JOIN dist ON (dist.name=i_use_this.dist_name AND old=0)
         GROUP BY dist_name
         ORDER BY cnt DESC
         LIMIT 30}, {Slice => +{}}
    );
    return $c->render('i_use_this/ranking.tx', {ranking => $ranking});
}

sub post {
    my ($class, $c) = @_;

    my $session_user = $c->session_user();
    my $dist_name = $c->req->param('dist_name') // die "missing dist_name";
    my $body = $c->req->param('body'); # optional

    if ($session_user && $dist_name && $c->req->method eq 'POST') {
        $c->db->replace(
            i_use_this => {
                user_id   => $session_user->user_id,
                dist_name => $dist_name,
                body      => $body,
                ctime     => time(),
            }
        );
    }

    return $c->redirect('/i_use_this/list', {dist_name => $dist_name});
}

sub list {
    my ($class, $c) = @_;
    my $dist_name = $c->req->param('dist_name') // die;
    my @reviews = $c->db->search_by_sql(q{SELECT i_use_this.*, user.login AS user_login, user.name AS user_name, user.gravatar_id FROM i_use_this INNER JOIN user USING (user_id) WHERE dist_name=? ORDER BY mtime DESC}, [$dist_name], 'i_use_this');

    return $c->render('/i_use_this/list.tx', {reviews => \@reviews});
}

1;

