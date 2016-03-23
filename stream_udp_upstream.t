#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Stream tests for upstream module and balancers with datagrams.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ dgram /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream/)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    proxy_responses      1;
    proxy_timeout        1s;

    upstream u {
        server 127.0.0.1:8087;
        server 127.0.0.1:8088;
    }

    upstream u2 {
        server 127.0.0.1:8089 down;
        server 127.0.0.1:8089;
        server 127.0.0.1:8087;
        server 127.0.0.1:8088;
    }

    upstream u3 {
        server 127.0.0.1:8087;
        server 127.0.0.1:8088 weight=2;
    }

    upstream u4 {
        server 127.0.0.1:8089;
        server 127.0.0.1:8087 backup;
    }

    server {
        listen      127.0.0.1:8081 udp;
        proxy_pass  u;
    }

    server {
        listen      127.0.0.1:8082 udp;
        proxy_pass  u2;
    }

    server {
        listen      127.0.0.1:8083 udp;
        proxy_pass  u3;
    }

    server {
        listen      127.0.0.1:8084 udp;
        proxy_pass  u4;
    }
}

EOF

$t->run_daemon(\&udp_daemon, 8087, $t);
$t->run_daemon(\&udp_daemon, 8088, $t);
$t->try_run('no stream udp')->plan(4);

$t->waitforfile($t->testdir . '/8087');
$t->waitforfile($t->testdir . '/8088');

###############################################################################

is(many('.', 30, peer => '127.0.0.1:8081'), '8087: 15, 8088: 15', 'balanced');
is(many('.', 30, peer => '127.0.0.1:8082'), '8087: 15, 8088: 15', 'failures');
is(many('.', 30, peer => '127.0.0.1:8083'), '8087: 10, 8088: 20', 'weight');
is(many('.', 30, peer => '127.0.0.1:8084'), '8087: 30', 'backup');

###############################################################################

sub many {
	my ($data, $count, %opts) = @_;
	my (%ports, $peer);

	$peer = $opts{peer};

	for (1 .. $count) {
		if (dgram($peer)->io($data) =~ /(\d+)/) {
			$ports{$1} = 0 unless defined $ports{$1};
			$ports{$1}++;
		}
	}

	return join ', ', map { $_ . ": " . $ports{$_} } sort keys %ports;
}

###############################################################################

sub udp_daemon {
	my ($port, $t) = @_;

	my $server = IO::Socket::INET->new(
		Proto => 'udp',
		LocalAddr => '127.0.0.1:' . $port,
		Reuse => 1,
	)
		or die "Can't create listening socket: $!\n";

	# signal we are ready

	open my $fh, '>', $t->testdir() . '/' . $port;
	close $fh;

	while (1) {
		$server->recv(my $buffer, 65536);
		$buffer = $server->sockport();
		$server->send($buffer);
	}
}

###############################################################################