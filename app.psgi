use 5.014;
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
use JSON::XS;

use Encode;

our $VERSION = '0.10';

use Class::Accessor::Lite::Lazy (
    ro_lazy => [ qw/git github datadir json/ ]
);

sub _build_datadir {
    my $self = shift;
    my $datadir = catfile(dirname(__FILE__), $self->config->{datadir});
}

sub _build_git {
    my $self = shift;

    my $repos;

    if (-d $self->datadir) {
        mkdir $self->datadir;
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

sub _build_json {
    my $json_driver = JSON::XS->new->utf8;
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
    $html = $c->_filter_html($html);

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

get '/task/:title/_history' => sub {
    my ($c, $args) = @_;
    my $title = $args->{title};

    # fetch git log about this file
    my $output = $c->git->run('log', '--', "$title.md");

    #say 'git log' . $output;

    my $git_log = $c->_parse_git_log($output);

    return $c->render('history.tx', {
        title    => $title,
        contents => $git_log,
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

post '/task/:title/_delete' => sub {
    my ($c, $args) = @_;
    my $title = $args->{title};

    # delete
    $c->git->run('rm', "$title.md");
    $c->git->run('commit', '-m', "delete $title.md");

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

sub _filter_html {
    my ($self, $html) = @_;

    # tableにclass="table-bordered table-striped" つける
    $html =~ s/<table>/<table class="table table-bordered table-striped">/gr;
}

sub _replace_issues {
    my ($self, $html) = @_;

    $html = $self->_replace_github_issues($html);

    $html = $self->_replace_redmine_issues($html);

    my $result = $html;

    return $result;
}

sub _replace_github_issues {
    my ($self, $html) = @_;

    # replace issue status for each issue
    for my $key (keys $self->config->{github}{issues}) {
        my @bulk_ids;
        my @issue_ids;
        push @bulk_ids, $html =~ /$key:([\d,]+)/g;
        map { push @issue_ids, split /,/, $_ } @bulk_ids;

        next unless scalar @issue_ids;

        # まずOpenのIssueをリストで一気に取得
        my %result_hash;

        # ホントはpithubのauto_paginationで回したいのだが
        # utf8をちゃんと扱ってないので自力で回す
        my $result = $self->github->issues->list(
            %{ $self->config->{github}{issues}{$key} },
            state => 'open',
        );
        while ($result) {
            my $arrayref = $self->json->decode($result->response->content);

            for my $hash (@$arrayref) {
                $result_hash{ $hash->{number} } = $hash;
            }

            $result = $result->next_page;
        }

        # 残り、hashが存在しないものを取得
        for my $id (@issue_ids) {
            next if $result_hash{$id};

            my $result = $self->github->issues->get(
                %{ $self->config->{github}{issues}{$key} },
                issue_id => $id,
            );

            $result_hash{$id} = $self->json->decode($result->response->content);
        }

#        use YAML;
#        warn Dump %result_hash;

        {
            $html =~ s!$key:([\d,]+)!
                my @ids = split /,/, $1;
                #say 'ids: ' . join ',', @ids;
                $self->_markup_issue(map { $result_hash{$_} } @ids);
            !gex;
        }

    }

    return $html;
}


sub _replace_redmine_issues {
    my ($self, $html) = @_;

    # replace issue status for each issue
    for my $key (keys $self->config->{github}{issues}) {
        my @bulk_ids;
        my @issue_ids;
        push @bulk_ids, $html =~ /$key:([\d,]+)/g;
        map { push @issue_ids, split /,/, $_ } @bulk_ids;

        next unless scalar @issue_ids;

        # まずOpenのIssueをリストで一気に取得
        my %result_hash;

        # ホントはpithubのauto_paginationで回したいのだが
        # utf8をちゃんと扱ってないので自力で回す
        my $result = $self->github->issues->list(
            %{ $self->config->{github}{issues}{$key} },
            state => 'open',
        );
        while ($result) {
            my $arrayref = $self->json->decode($result->response->content);

            for my $hash (@$arrayref) {
                $result_hash{ $hash->{number} } = $hash;
            }

            $result = $result->next_page;
        }

        # 残り、hashが存在しないものを取得
        for my $id (@issue_ids) {
            next if $result_hash{$id};

            my $result = $self->github->issues->get(
                %{ $self->config->{github}{issues}{$key} },
                issue_id => $id,
            );

            $result_hash{$id} = $self->json->decode($result->response->content);
        }

#        use YAML;
#        warn Dump %result_hash;

        {
            $html =~ s!$key:([\d,]+)!
                my @ids = split /,/, $1;
                #say 'ids: ' . join ',', @ids;
                $self->_markup_issue(map { $result_hash{$_} } @ids);
            !gex;
        }

    }

    return $html;
}

sub _markup_issue {
    my ($self, @result) = @_;

    # $result->contentはencoding utf8じゃなくて使い物にならないので
    # ここで直接JSON::XSでやってしまう
    my @contents;
    for my $res (@result) {
        push @contents, $res;
    }

#    use YAML;
#    warn Dump @contents;

    $self->create_view->render('issue.tx', {
        contents => [ @contents ]
    });
}

sub _parse_git_log {
    my ($self, $output) = @_;

    #say 'output' . $output;

    my @result;
    my $working;
    for my $line (split /\n/, $output) {
        chomp $line;
        #say $line;
        given ($line) {
            when (/^commit/) {
                push @result, $working if $working;
                $working = {};
                $working->{commit} = s/^commit ([0-9a-z]+)/$1/r;
            }
            when (/^Author:/) {
                $working->{author} = s/^Author: (.+)/$1/r;
            }
            when (/^Date:/) {
                $working->{date} = s/^Date:\s+(.+)/$1/r;
            }
            default {
                my $trimed = s/^\s*//r;
                if ($trimed) {
                    $working->{message} .= "<br />" if $working->{message};
                    $working->{message} .= $trimed;
                }
            }
        }
    }

    push @result, $working if $working;

#    use YAML;
#    warn Dump @result;

    return [ @result ];
}


# load plugins
__PACKAGE__->load_plugin('Web::CSRFDefender' => {
    post_only => 1,
});
# __PACKAGE__->load_plugin('DBI');
# __PACKAGE__->load_plugin('Web::FillInFormLite');
# __PACKAGE__->load_plugin('Web::JSON');


__PACKAGE__->enable_session( store => 'File' );
__PACKAGE__->template_options(
    syntax => 'Kolon',
#    cache => 0,
);

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
<link href="//netdna.bootstrapcdn.com/bootstrap/3.0.0/css/bootstrap.min.css" rel="stylesheet">
<script src="//netdna.bootstrapcdn.com/bootstrap/3.0.0/js/bootstrap.min.js"></script>
<link rel="stylesheet" href="<: uri_for('/static/css/main.css') :>">
</head>
<body>
<div class="container">
<header><h1><a href="<: uri_for('/') :>">Powawa::Taskmemo</a></h1></header>

<div class="row">
: block main -> {}
</div>
<footer>Powered by <a href="http://amon.64p.org/">Amon2::Lite</a></footer>
</div>
</body>
</html>


@@ index.tx
: cascade template
: around main -> { 
<p>Task Memo List</p>
<ul>
: for $memos -> $memo {
<li><a href="<: uri_for('/task/' ~ $memo.path) :>"><:= $memo.name :></a></li>
: }
<li><a href="<: uri_for('/new') :>">... or create new</a></li>
</ul>
: }


@@ new.tx
: cascade template
: around main -> { 
<h2>Input Name</h2>
<form action="<: uri_for('/new') :>" method="post">
<input name="name" type="text" size="30"></input>
<input type="submit" class="btn btn-primary"></input>
</form>
: }

@@ markdown.tx
: cascade template
: around main -> { 
<h2><:= $title :></h2>

<p>
<a href="<: uri_for('/task/' ~ $title ~ '/_edit') :>" class="btn btn-primary">Edit</a>
<a href="<: uri_for('/task/' ~ $title ~ '/_delete') :>" class="btn btn-danger">Delete</a>
<a href="<: uri_for('/task/' ~ $title ~ '/_history') :>" class="btn btn-info">History</a>
</p>

<:= $body | mark_raw:>

: }

@@ edit.tx

: cascade template
: around main -> { 
<h2>Edit: <:= $title :>.md</h2>

<form action="<: uri_for('/task/' ~ $title ~ '/_edit') :>" method="post" class="form-horizontal">
<div class="control-group">
<div class="control">
<textarea name="body" rows="28" class="input-xlarge" cols="120">
<:= $body | mark_raw :>
</textarea>
</div>
<div>
<div class="form-actions">
<button type="submit" class="btn btn-primary"/>Submit</button>
</div>

</form>
: }


@@ delete_confirm.tx
: cascade template
: around main -> { 
<h2>Are you sure to delete '<:= $title :>.md' ?</h2>
<form action="<: uri_for('/task/' ~ $title ~ '/_delete') :>" method="post">
<input type="submit" value="Yes, Delete." class="btn btn-danger"/>
<a href="<: uri_for('/task/' ~ $title) :>" class="btn btn-info">No, I will back...</a>
</form>
: }

@@ history.tx

: cascade template
: around main -> {
<h2>History of <:= $title :>.md</h2>


<table class="table table-bordered table-striped">
<thead>
<tr>
<th>date</th>
<th>commit</th>
<th>message</th>
</tr>
</thead>
<tbody>
: for $contents -> $content {
<tr>
<td><:= $content.date :></td>
<td><:= $content.commit :></td>
<td><:= $content.message :></td>
</tr>
: }
</tbody>
</table>

: }



@@ issue.tx
<table class="table table-bordered table-striped">
<tbody>
: for $contents -> $content {
<tr>
<th style="width: 50px"> #<:= $content.number :> </th>
<th ><a href="<:= $content.html_url :>"><:= $content.title :></a></th>
<td style="width: 60px">
: if $content.state == 'open' {
<span class="label label-success">Open</span>
: } else {
<span class="label label-danger">Closed</span>
: }
</td>
<td style="width: 150px">
: if $content.assignee {
<img src="<:= $content.assignee.avatar_url :>" alt="<:= $content.assignee.login :>" width="16" height="16"/> <:= $content.assignee.login :>
: } else {
<i class="icon-remove"></i> not assigned...
: }
</td>
<td style="width: 150px">
: if $content.milestone {
<a href="<:= $content.milestone.url :>"><span class="label label-warning"><:= $content.milestone.title :></span></a>
: } else {
<span class="label label-info">No Milestone</span>
: }
</td>
</tr>
: }
</tbody>
</table>



@@ /static/js/main.js

@@ /static/css/main.css
footer {
    text-align: right;
}
body {
    background-color: #F8F8F8;
}
div.row {
    padding: 0 10px;
    background-color: #FFFFFF;
    border: 1px solid #999999;
}

textarea {
    font-family: monospace;
}
li {
    line-height: 1.5em;
}

