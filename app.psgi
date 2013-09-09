use 5.016;
use strict;
use warnings;
use utf8;
use File::Spec;
use File::Basename;
use Amon2::Lite;
use Path::Class qw/file dir/;

use Git::Repository;
use Time::Piece;
use Pithub;

use Encode;

our $VERSION = '0.10';

use Class::Accessor::Lite::Lazy (
    ro_lazy => [ qw/git github datadir/ ]
);

sub _build_datadir {
    my $self = shift;
    my $datadir = catfile(dirname(__FILE__), $self->config->{datadir});
}

sub _build_git {
    my $self = shift;

    my $repos;

    if (-d $self->datadir) {
        $repos = Git::Repository->new( git_dir => $self->datadir . '/.git' );
    } else {
        $repos = Git::Repository->run( init => $self->datadir );
    }

    $repos;
}

sub _build_github {
    my $self = shift;

    my $github = Pithub->new( %{ $self->config->{github}{auth} } );
}

sub catfile {
    return File::Spec->catfile(@_);
}


# override config (like Ark...)
sub load_config {
    my $c = shift;

    my $config_file = catfile(dirname(__FILE__), 'config.pl');

    my $config = do "$config_file" or die "cannot exec config.pl";
    die "config is not hashref" unless ref $config eq 'HASH';

    my $config_local_file = catfile(dirname(__FILE__), 'config_local.pl');
    my $config_local = -e $config_local_file ?
        (do "$config_local_file" or die "cannot exec config_local.pl") :  (undef);
    die "config_local is not hashref" if $config_local && ref $config_local ne 'HASH';

    return +{
        %$config,
        $config_local ? %$config_local : (),
    };
}


# dispatchers
get '/' => sub {
    my $c = shift;

    # show files
    $c->git->run('status');

    my @filelist = map { s!^.*/!!r } glob $c->datadir . "/*.md";

    return $c->render('index.tx', {
        memos => [ map { my $part = s!\.md!!r; +{ name => $part, path => $part} } @filelist ]
    });
};

get '/new' => sub {
    my $c = shift;
    return $c->render('new.tx');
};

post '/new' => sub {
    my $c = shift;

    my $name = $c->req->param('name') or return $c->redirect('/');
    return $c->redirect('/') if -e $c->datadir . "/$name.md";

    # create new file & commit
    dir($c->datadir)->file("$name.md")->touch;
    $c->git->run('add', "$name.md");
    $c->git->run('commit', '-m', "first commit of $name.md");

    return $c->redirect('/');
};

get '/task/:title' => sub {
    my ($c, $args) = @_;
    my $title = $args->{title};

    my $body = dir($c->datadir)->file("$title.md")->slurp( iomode => '<:encoding(utf8)');

    my $result = $c->_markdown($body);
    my $html = $c->_replace_issues(decode_utf8 $result->response->content);

    return $c->render('markdown.tx', {
        title => $title,
        body  => $html,
    });
};


get '/task/:title/_edit' => sub {
    my ($c, $args) = @_;
    my $title = $args->{title};

    my $body = dir($c->datadir)->file("$title.md")->slurp( iomode => '<:encoding(utf8)');

    return $c->render('edit.tx', {
        title => $title,
        body  => $body,
    });
};

get '/task/:title/_hisory' => sub {
    my ($c, $args) = @_;
    my $title = $args->{title};

    # fetch git log about this file

    return $c->render('history.tx', {
        title => $title,
        body  => 'ここにhistoryが入るぞ',
    });
};

post '/task/:title/_edit' => sub {
    my ($c, $args) = @_;
    my $title = $args->{title};
    my $body = $c->req->param('body');

    # 保存してgit commitする
    dir($c->datadir)->file($title . '.md')->spew(iomode => '>:encoding(utf8)', $body);
    my $now = localtime;
    $c->git->run('commit', '-a', '-m', "commit at $now");

    return $c->redirect('/task/' . $title);
};

get '/task/:title/_delete' => sub {
    my ($c, $args) = @_;
    my $title = $args->{title};

    return $c->render('delete_confirm.tx', {
        title => $title
    });
};

get '/task/:title/_delete/_yes' => sub {
    my ($c, $args) = @_;
    my $title = $args->{title};

    return $c->redirect('/');
};


# internal methods

sub _markdown {
    my ($self, $body) = @_;
    # githubに投げる
    my $result = $self->github->request(
        method => 'POST',
        path   => '/markdown',
        data => {
            text => encode_utf8($body),
            mode => 'gfm',
        }
    );
}

sub _replace_issues {
    my ($self, $html) = @_;

    # replace issue status for each issue
    for my $key (keys $self->config->{github}{issues}) {
        my @issue_ids;
        push @issue_ids, $html =~ /$key:([\d]+)/g;

    }

    my $result = $html;


    return $result;
}


# load plugins
__PACKAGE__->load_plugin('Web::CSRFDefender' => {
    post_only => 1,
});
# __PACKAGE__->load_plugin('DBI');
# __PACKAGE__->load_plugin('Web::FillInFormLite');
# __PACKAGE__->load_plugin('Web::JSON');

__PACKAGE__->enable_session();
__PACKAGE__->template_options( syntax => 'Kolon' );

__PACKAGE__->to_app(handle_static => 1);


__DATA__

@@ template.tx
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Powawa::Taskmemo</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<script type="text/javascript" src="http://ajax.googleapis.com/ajax/libs/jquery/1.9.1/jquery.min.js"></script>
<script type="text/javascript" src="<: uri_for('/static/js/main.js') :>"></script>
<link href="//netdna.bootstrapcdn.com/twitter-bootstrap/2.3.1/css/bootstrap-combined.min.css" rel="stylesheet">
<script src="//netdna.bootstrapcdn.com/twitter-bootstrap/2.3.1/js/bootstrap.min.js"></script>
<link rel="stylesheet" href="<: uri_for('/static/css/main.css') :>">
</head>
<body>
<div class="container">
<header><h1>Powawa::Taskmemo</h1></header>
: block main -> {}
<footer>Powered by <a href="http://amon.64p.org/">Amon2::Lite</a></footer>
</div>
</body>
</html>


@@ index.tx
: cascade template
: around main -> { 
<section class="row">
<p>Task Memo List</p>
<ul>
: for $memos -> $memo {
<li><a href="<: uri_for('/task/' ~ $memo.path) :>"><:= $memo.name :></a></li>
: }
<li><a href="<: uri_for('/new') :>">... or create new</a></li>
</ul>
</section>
: }


@@ new.tx
: cascade template
: around main -> { 
<section class="row">
<h2>Input Name</h2>
<form action="<: uri_for('/new') :>" method="post">
<input name="name" type="text" size="30"></input>
<input type="submit" class="btn btn-info"></input>
</form>
</section>
: }

@@ markdown.tx
: cascade template
: around main -> { 
<section class="row">
<h2><:= $title :></h2>

<:= $body | mark_raw:>

<a href="<: uri_for('/task/' ~ $title ~ '/_edit') :>"><input type="button" value="Edit" /></a>

</section>
: }

@@ edit.tx

: cascade template
: around main -> { 
<section class="row">
<h2>Edit: <:= $title :>.md</h2>

<form action="<: uri_for('/task/' ~ $title ~ '/_edit') :>" method="post">
<div>
<textarea name="body" rows="28" class="span8">
<:= $body | mark_raw :>
</textarea>
<div>
<p><input type="submit" class="btm btn-info"/></p>

</form>
</section>
: }


@@ delete_confirm.tx
: cascade template
: around main -> { 
<section class="row">
<h2>Are you sure to delete '<:= $title :>.md' ?</h2>

</section>
: }


@@ /static/js/main.js

@@ /static/css/main.css
footer {
    text-align: right;
}
