#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Stream tests for upstream least_conn balancer module.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream stream_upstream_least_conn/)->plan(2)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    upstream u {
        least_conn;
        server 127.0.0.1:8081;
        server 127.0.0.1:8082;
    }

    server {
        listen      127.0.0.1:8080;
        proxy_pass  u;
    }
}

EOF

$t->run_daemon(\&stream_daemon, 8081);
$t->run_daemon(\&stream_daemon, 8082);
$t->run();

$t->waitforsocket('127.0.0.1:8081');
$t->waitforsocket('127.0.0.1:8082');

###############################################################################

is(many('.', 10), '8081: 5, 8082: 5', 'balanced');
is(parallel('w', 10), '8081: 1, 8082: 9', 'least_conn');

###############################################################################

sub many {
	my ($data, $count, %opts) = @_;
	my (%ports, $peer);

	$peer = $opts{peer};

	for (1 .. $count) {
		if (stream_get($data, $peer) =~ /(\d+)/) {
			$ports{$1} = 0 unless defined $ports{$1};
			$ports{$1}++;
		}
	}

	return join ', ', map { $_ . ": " . $ports{$_} } sort keys %ports;
}

sub parallel {
	my ($data, $count, %opts) = @_;
	my (@sockets, %ports, $peer);

	$peer = $opts{peer} || undef;

	for (1 .. $count) {
		my $s = stream_connect($peer);
		push @sockets, $s;
		stream_write($s, $data);
		select undef, undef, undef, 0.2;
	}

	for (1 .. $count) {
		my $s = pop @sockets;
		if (stream_read($s) =~ /(\d+)/) {
			$ports{$1} = 0 unless defined $ports{$1};
			$ports{$1}++;
		}
		close $s;
	}

	return join ', ', map { $_ . ": " . $ports{$_} } sort keys %ports;
}

sub stream_get {
	my ($data, $peer) = @_;

	my $s = stream_connect($peer);
	stream_write($s, $data);
	my $r = stream_read($s);

	$s->close;
	return $r;
}

sub stream_connect {
	my $peer = shift;
	my $s = IO::Socket::INET->new(
		Proto => 'tcp',
		PeerAddr => $peer || '127.0.0.1:8080'
	)
		or die "Can't connect to nginx: $!\n";

	return $s;
}

sub stream_write {
	my ($s, $message) = @_;

	local $SIG{PIPE} = 'IGNORE';

	$s->blocking(0);
	while (IO::Select->new($s)->can_write(1.5)) {
		my $n = $s->syswrite($message);
		last unless $n;
		$message = substr($message, $n);
		last unless length $message;
	}

	if (length $message) {
		$s->close();
	}
}

sub stream_read {
	my ($s) = @_;
	my ($buf);

	$s->blocking(0);
	if (IO::Select->new($s)->can_read(3)) {
		$s->sysread($buf, 1024);
	};

	log_in($buf);
	return $buf;
}

###############################################################################

sub stream_daemon {
	my ($port) = @_;

	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1',
		LocalPort => $port,
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	my $sel = IO::Select->new($server);

	local $SIG{PIPE} = 'IGNORE';

	while (my @ready = $sel->can_read) {
		foreach my $fh (@ready) {
			if ($server == $fh) {
				my $new = $fh->accept;
				$new->autoflush(1);
				$sel->add($new);

			} elsif (stream_handle_client($fh)) {
				$sel->remove($fh);
				$fh->close;
			}
		}
	}
}

sub stream_handle_client {
	my ($client) = @_;

	log2c("(new connection $client)");

	$client->sysread(my $buffer, 65536) or return 1;

	log2i("$client $buffer");

	my $port = $client->sockport();

	if ($buffer =~ /w/ && $port == 8081) {
		Test::Nginx::log_core('||', "$port: sleep(2.5)");
		select undef, undef, undef, 2.5;
	}

	$buffer = $port;

	log2o("$client $buffer");

	$client->syswrite($buffer);

	return 1;
}

sub log2i { Test::Nginx::log_core('|| <<', @_); }
sub log2o { Test::Nginx::log_core('|| >>', @_); }
sub log2c { Test::Nginx::log_core('||', @_); }

###############################################################################