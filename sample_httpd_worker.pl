#!/usr/bin/env perl

use strict;
use warnings;

use Coro;
use Net::RabbitFoot;
use JSON::XS;
use Readonly;
use Data::Dumper;

Readonly my @MQ_CONNECT_ARGS => (
    host  => 'localhost',
    port  => 5672,
    user  => 'guest',
    pass  => 'guest',
    vhost => '/',
);

Readonly my $PREFETCH => 5;

$| = 1;

my $is_finish;
$SIG{HUP} = $SIG{INT} = $SIG{TERM} = sub {
    warn "Trapped SIGNAL.\n";
    $is_finish = 1;
    $Coro::main->ready;
};

my $json = JSON::XS->new()->utf8();

my $rf = eval {
    Net::RabbitFoot->new()->load_xml_spec()->connect(
        @MQ_CONNECT_ARGS,
        (map {
            'on_' . $_ => failure_handler('connecn.on_' . $_)
        } qw(close read_failure)),
    );
};
die $@ if $@;

eval {
    my $ch = $rf->open_channel(
        on_close => failure_handler('channel.on_close'),
    );
    $ch->qos(prefetch_count => $PREFETCH);
    $ch->consume(
        queue      => 'http',
        no_ack     => 0,
        on_consume => unblock_sub {
            work($json, $ch, shift);
            $Coro::main->ready;
        }
    );
};
if ($@) {
    warn $@;
    $is_finish = 1;
};

schedule while !$is_finish;
$rf->close;
exit;

sub failure_handler {
    my ($event) = @_;
    return unblock_sub {
        warn Dumper({$event => \@_});
        $is_finish = 1;
        $Coro::main->ready;
    };
}

sub work {
    my ($json, $ch, $request,) = @_;

    my $response = make_http_response(@_);

    $ch->publish(
        routing_key => $request->{header}->reply_to,
        header      => {
            app_id  => $response->{code},
            headers => $response->{headers},
        },
        body        => $response->{body},
        on_return   => failure_handler('channel.on_return'),
    );

    $ch->ack(
        delivery_tag => $request->{deliver}->method_frame->delivery_tag,
    );

    return;
}

sub make_http_response {
    my ($json, $ch, $request,) = @_;

    warn Dumper({headers => $request->{header}->headers});

    my $request_body = $json->decode($request->{body}->payload);

    warn Dumper({body => $request_body});

    return {
        code    => 200,
        headers => {
            'Content-Type' => 'text/plain; charset=UTF-8',
        },
        body    => 'Hello world.',
    };
}

