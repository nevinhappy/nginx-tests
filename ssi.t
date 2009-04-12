#!/usr/bin/perl

# (C) Maxim Dounin

# Tests for nginx ssi module.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->plan(9);

$t->write_file_expand('nginx.conf', <<'EOF');

master_process off;
daemon         off;

events {
}

http {
    access_log    off;
    root          %%TESTDIR%%;

    client_body_temp_path  %%TESTDIR%%/client_body_temp;
    fastcgi_temp_path      %%TESTDIR%%/fastcgi_temp;
    proxy_temp_path        %%TESTDIR%%/proxy_temp;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;
        ssi on;
    }
}

EOF

$t->write_file('test1.html', 'X<!--#echo var="arg_test" -->X');
$t->write_file('test2.html',
	'X<!--#include virtual="/test1.html?test=test" -->X');
$t->write_file('test3.html',
	'X<!--#set var="blah" value="test" --><!--#echo var="blah" -->X');

$t->run();

###############################################################################

like(http_get('/test1.html'), qr/^X\(none\)X$/m, 'echo no argument');
like(http_get('/test1.html?test='), qr/^XX$/m, 'empty argument');
like(http_get('/test1.html?test=test'), qr/^XtestX$/m, 'argument');
like(http_get('/test1.html?test=test&a=b'), qr/^XtestX$/m, 'argument 2');
like(http_get('/test1.html?a=b&test=test'), qr/^XtestX$/m, 'argument 3');
like(http_get('/test1.html?a=b&test=test&d=c'), qr/^XtestX$/m, 'argument 4');
like(http_get('/test1.html?atest=a&testb=b&ctestc=c&test=test'), qr/^XtestX$/m,
	'argument 5');

like(http_get('/test2.html'), qr/^XXtestXX$/m, 'argument via include');

like(http_get('/test3.html'), qr/^XtestX$/m, 'set');

###############################################################################