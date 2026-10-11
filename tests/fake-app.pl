#!/usr/bin/perl
# fake-app.pl <socket> <log> <mode>: a stand-in for Earshot for Mac.
# Logs each message line; mode ok answers {"ok":true}, reject answers
# {"ok":false}, silent never answers, late answers ok after 0.5 s.
# Listens with a backlog of 32 like the real app, and handles each
# connection in a child process, so messages sent at the same moment (a
# status in the background and a line) are all accepted.
use strict;
use warnings;
use IO::Socket::UNIX;
use IO::Handle;
use POSIX ':sys_wait_h';
my ($path, $log, $mode) = @ARGV;
unlink $path;
my $server = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $path, Listen => 32) or die "listen: $!";
$SIG{CHLD} = sub { 1 while waitpid(-1, WNOHANG) > 0 };
while (1) {
    my $client = $server->accept or next;
    my $pid = fork;
    if (defined $pid && $pid == 0) {
        close $server;   # only the parent listens, so killing it is a real crash
        my $line = <$client>;
        if (defined $line) {
            open(my $fh, '>>', $log) or exit 1;
            print $fh $line;
            close $fh;
            if ($mode eq 'ok') { print $client "{\"ok\":true}\n" }
            elsif ($mode eq 'reject') { print $client "{\"ok\":false,\"reason\":\"version\"}\n" }
            elsif ($mode eq 'late') { select(undef, undef, undef, 0.5); print $client "{\"ok\":true}\n" }
            else { sleep 1 }   # silent
        }
        close $client;
        exit 0;
    }
    close $client;
}
