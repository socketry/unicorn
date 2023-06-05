#!perl -w
# Copyright (C) unicorn hackers <unicorn-public@yhbt.net>
# License: GPL-3.0+ <https://www.gnu.org/licenses/gpl-3.0.txt>

# This is the main integration test for fast-ish things to minimize
# Ruby startup time penalties.

use v5.14; BEGIN { require './t/lib.perl' };
use autodie;
my $srv = tcp_server();
my $host_port = tcp_host_port($srv);
my $t0 = time;
my $conf = "$tmpdir/u.conf.rb";
open my $conf_fh, '>', $conf;
$conf_fh->autoflush(1);
my $ar = unicorn(qw(-E none t/integration.ru -c), $conf, { 3 => $srv });
my $curl = which('curl');
END { diag slurp("$tmpdir/err.log") if $tmpdir };
sub slurp_hdr {
	my ($c) = @_;
	local $/ = "\r\n\r\n"; # affects both readline+chomp
	chomp(my $hdr = readline($c));
	my ($status, @hdr) = split(/\r\n/, $hdr);
	diag explain([ $status, \@hdr ]) if $ENV{V};
	($status, \@hdr);
}

my %PUT = (
	chunked_md5 => sub {
		my ($in, $out, $path, %opt) = @_;
		my $bs = $opt{bs} // 16384;
		require Digest::MD5;
		my $dig = Digest::MD5->new;
		print $out <<EOM;
PUT $path HTTP/1.1\r
Transfer-Encoding: chunked\r
Trailer: Content-MD5\r
\r
EOM
		my ($buf, $r);
		while (1) {
			$r = read($in, $buf, $bs);
			last if $r == 0;
			printf $out "%x\r\n", length($buf);
			print $out $buf, "\r\n";
			$dig->add($buf);
		}
		print $out "0\r\nContent-MD5: ", $dig->b64digest, "\r\n\r\n";
	},
	identity => sub {
		my ($in, $out, $path, %opt) = @_;
		my $bs = $opt{bs} // 16384;
		my $clen = $opt{-s} // -s $in;
		print $out <<EOM;
PUT $path HTTP/1.0\r
Content-Length: $clen\r
\r
EOM
		my ($buf, $r, $len);
		while ($clen) {
			$len = $clen > $bs ? $bs : $clen;
			$r = read($in, $buf, $len);
			die 'premature EOF' if $r == 0;
			print $out $buf;
			$clen -= $r;
		}
	},
);

my ($c, $status, $hdr);

# response header tests
$c = tcp_start($srv, 'GET /rack-2-newline-headers HTTP/1.0');
($status, $hdr) = slurp_hdr($c);
like($status, qr!\AHTTP/1\.[01] 200\b!, 'status line valid');
my $orig_200_status = $status;
is_deeply([ grep(/^X-R2: /, @$hdr) ],
	[ 'X-R2: a', 'X-R2: b', 'X-R2: c' ],
	'rack 2 LF-delimited headers supported') or diag(explain($hdr));

SKIP: { # Date header check
	my @d = grep(/^Date: /i, @$hdr);
	is(scalar(@d), 1, 'got one date header') or diag(explain(\@d));
	eval { require HTTP::Date } or skip "HTTP::Date missing: $@", 1;
	$d[0] =~ s/^Date: //i or die 'BUG: did not strip date: prefix';
	my $t = HTTP::Date::str2time($d[0]);
	ok($t >= $t0 && $t > 0 && $t <= time, 'valid date') or
		diag(explain([$t, $!, \@d]));
};


$c = tcp_start($srv, 'GET /rack-3-array-headers HTTP/1.0');
($status, $hdr) = slurp_hdr($c);
is_deeply([ grep(/^x-r3: /, @$hdr) ],
	[ 'x-r3: a', 'x-r3: b', 'x-r3: c' ],
	'rack 3 array headers supported') or diag(explain($hdr));

SKIP: {
	eval { require JSON::PP } or skip "JSON::PP missing: $@", 1;
	my $c = tcp_start($srv, 'GET /env_dump');
	my $json = do { local $/; readline($c) };
	unlike($json, qr/^Connection: /smi, 'no connection header for 0.9');
	unlike($json, qr!\AHTTP/!s, 'no HTTP/1.x prefix for 0.9');
	my $env = JSON::PP->new->decode($json);
	is(ref($env), 'HASH', 'JSON decoded body to hashref');
	is($env->{SERVER_PROTOCOL}, 'HTTP/0.9', 'SERVER_PROTOCOL is 0.9');
}

# cf. <CAO47=rJa=zRcLn_Xm4v2cHPr6c0UswaFC_omYFEH+baSxHOWKQ@mail.gmail.com>
$c = tcp_start($srv, 'GET /nil-header-value HTTP/1.0');
($status, $hdr) = slurp_hdr($c);
is_deeply([grep(/^X-Nil:/, @$hdr)], ['X-Nil: '],
	'nil header value accepted for broken apps') or diag(explain($hdr));

if ('TODO: ensure Rack::Utils::HTTP_STATUS_CODES is available') {
	$c = tcp_start($srv, 'POST /tweak-status-code HTTP/1.0');
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 200 HI\b!, 'status tweaked');

	$c = tcp_start($srv, 'POST /restore-status-code HTTP/1.0');
	($status, $hdr) = slurp_hdr($c);
	is($status, $orig_200_status, 'original status restored');
}

SKIP: {
	eval { require HTTP::Tiny } or skip "HTTP::Tiny missing: $@", 1;
	my $ht = HTTP::Tiny->new;
	my $res = $ht->get("http://$host_port/write_on_close");
	is($res->{content}, 'Goodbye', 'write-on-close body read');
}

if ('bad requests') {
	$c = tcp_start($srv, 'GET /env_dump HTTP/1/1');
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 400 \b!, 'got 400 on bad request');

	$c = tcp_start($srv);
	print $c 'GET /';;
	my $buf = join('', (0..9), 'ab');
	for (0..1023) { print $c $buf }
	print $c " HTTP/1.0\r\n\r\n";
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 414 \b!,
		'414 on REQUEST_PATH > (12 * 1024)');

	$c = tcp_start($srv);
	print $c 'GET /hello-world?a';
	$buf = join('', (0..9));
	for (0..1023) { print $c $buf }
	print $c " HTTP/1.0\r\n\r\n";
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 414 \b!,
		'414 on QUERY_STRING > (10 * 1024)');

	$c = tcp_start($srv);
	print $c 'GET /hello-world#a';
	$buf = join('', (0..9), 'a'..'f');
	for (0..63) { print $c $buf }
	print $c " HTTP/1.0\r\n\r\n";
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 414 \b!, '414 on FRAGMENT > (1024)');
}

# input tests
my ($blob_size, $blob_hash);
SKIP: {
	CORE::open(my $rh, '<', 't/random_blob') or
		skip "t/random_blob not generated $!", 1;
	$blob_size = -s $rh;
	require Digest::SHA;
	$blob_hash = Digest::SHA->new(1)->addfile($rh)->hexdigest;

	my $ck_hash = sub {
		my ($sub, $path, %opt) = @_;
		seek($rh, 0, SEEK_SET);
		$c = tcp_start($srv);
		$c->autoflush(0);
		$PUT{$sub}->($rh, $c, $path, %opt);
		$c->flush or die $!;
		($status, $hdr) = slurp_hdr($c);
		is(readline($c), $blob_hash, "$sub $path");
	};
	$ck_hash->('identity', '/rack_input', -s => $blob_size);
	$ck_hash->('chunked_md5', '/rack_input');
	$ck_hash->('identity', '/rack_input/size_first', -s => $blob_size);
	$ck_hash->('identity', '/rack_input/rewind_first', -s => $blob_size);
	$ck_hash->('chunked_md5', '/rack_input/size_first');
	$ck_hash->('chunked_md5', '/rack_input/rewind_first');


	$curl // skip 'no curl found in PATH', 1;

	my ($copt, $cout);
	my $url = "http://$host_port/rack_input";
	my $do_curl = sub {
		my (@arg) = @_;
		pipe(my $cout, $copt->{1});
		open $copt->{2}, '>', "$tmpdir/curl.err";
		my $cpid = spawn($curl, '-sSf', @arg, $url, $copt);
		close(delete $copt->{1});
		is(readline($cout), $blob_hash, "curl @arg response");
		is(waitpid($cpid, 0), $cpid, "curl @arg exited");
		is($?, 0, "no error from curl @arg");
		is(slurp("$tmpdir/curl.err"), '', "no stderr from curl @arg");
	};

	$do_curl->(qw(-T t/random_blob));

	seek($rh, 0, SEEK_SET);
	$copt->{0} = $rh;
	$do_curl->('-T-');
}


# ... more stuff here

# SIGHUP-able stuff goes here

if ('max_header_len internal API') {
	undef $c;
	my $req = 'GET / HTTP/1.0';
	my $len = length($req."\r\n\r\n");
	my $fifo = "$tmpdir/fifo";
	POSIX::mkfifo($fifo, 0600) or die "mkfifo: $!";
	print $conf_fh <<EOM;
Unicorn::HttpParser.max_header_len = $len
listen "$host_port" # TODO: remove this requirement for SIGHUP
after_fork { |_,_| File.open('$fifo', 'w') { |fp| fp.write "pid=#\$\$" } }
EOM
	$ar->do_kill('HUP');
	open my $fifo_fh, '<', $fifo;
	my $wpid = readline($fifo_fh);
	like($wpid, qr/\Apid=\d+\z/a , 'new worker ready');
	close $fifo_fh;
	$wpid =~ s/\Apid=// or die;
	ok(CORE::kill(0, $wpid), 'worker PID retrieved');

	$c = tcp_start($srv, $req);
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 200\b!, 'minimal request succeeds');

	$c = tcp_start($srv, 'GET /xxxxxx HTTP/1.0');
	($status, $hdr) = slurp_hdr($c);
	like($status, qr!\AHTTP/1\.[01] 413\b!, 'big request fails');
}


undef $ar;

check_stderr;

undef $tmpdir;
done_testing;
