use v6;

unit class WebSocket::P6SGI;

use MIME::Base64;
use WebSocket::Handle;
use WebSocket::Handshake;
use WebSocket::Frame::Grammar;

constant WS_DEBUG=so %*ENV<WS_DEBUG>;

sub debug($msg) {
    say "WS:S: [DEBUG] $msg";
}

sub ws-psgi(%env, Callable :$on-ready, Callable :$on-text, Callable :$on-binary, Callable :$on-close) is export {
    # use socket directly is bad idea. But HTTP/2 deprecates `connection: upgrade`. Then, this code may not
    # break on feature HTTP updates.
    my $sock = %env<p6sgix.io>;

    debug(%env.perl) if WS_DEBUG;

    die 'no p6sgix.io in psgi env' unless $sock;
    die 'p6sgix.io must contain instance of IO::Socket::Async' unless $sock ~~ IO::Socket::Async;

    unless %env<HTTP_UPGRADE> ~~ 'websocket' {
        warn 'no upgrade header in HTTP request';
        return bad-request
    }
    unless %env<HTTP_SEC_WEBSOCKET_VERSION> ~~ /^\d+$/ {
        warn "invalid websocket version... we don't support draft version of websocket.";
        return bad-request
    }

    my $ws-key = %env<HTTP_SEC_WEBSOCKET_KEY>;
    unless $ws-key {
        warn 'no HTTP_SEC_WEBSOCKET_KEY';
        return bad-request
    }

    my $accept = make-sec-websocket-accept($ws-key);

    debug 'return 101' if WS_DEBUG;

    return 101, [
        Connection => 'Upgrade',
        Upgrade => 'websocket',
        Sec-WebSocket-Accept => $accept,
    ], on -> \s { # } # vim sucks
        debug("handshake succeeded") if WS_DEBUG;

        my $handle = WebSocket::Handle.new(socket => $sock);

        $on-ready($handle);

        my $buf;
        $sock.bytes-supply.tap(-> $got {
            $buf ~= $got.decode('latin1');

            loop {
                my $m = WebSocket::Frame::Grammar.subparse($buf);
                if $m {
                    my $frame = $m.made;
                    debug "got frame {$frame.opcode}, {$frame.fin.Str}" if WS_DEBUG;
                    $buf = $buf.substr($m.to);
                    given $frame.opcode {
                        when (WebSocket::Frame::TEXT) {
                            debug "got text frame" if WS_DEBUG;
                            $on-text($handle, $frame.payload.encode('latin1').decode('utf-8')) if $on-text;
                        }
                        when (WebSocket::Frame::BINARY) {
                            debug "got binary frame" if WS_DEBUG;
                            $on-binary($handle, $frame.payload) if $on-binary;
                        }
                        when (WebSocket::Frame::CLOSE) {
                            debug "got close frame" if WS_DEBUG;
                            $on-close($handle);
                            try $handle.close;
                            s.done;
                        }
                        when (WebSocket::Frame::PING) {
                            debug "got ping frame" if WS_DEBUG;
                            $handle.pong;
                        }
                        when (WebSocket::Frame::PONG) {
                            debug "got pong frame" if WS_DEBUG;
                            # nop
                        }
                    }
                } else {
                    # maybe, frame is partial. maybe...
                    debug 'frame is partial' if WS_DEBUG;
                    last;
                }
            };

            CATCH { default {
                %env<p6sgi.errors>.print: "error in websocket processing: $_\n{.backtrace.full}";
                s.done;
            } }
        });

        (); # on requires a callable that returns a list of pairs with Supply keys
    };
}

sub internal-server-error {
    return 500, [], ['Internal Server Error'];
}

sub bad-request() {
    return 400, [], ['Bad Request'];
}

=begin pod

=head1 NAME

WebSocket::P6SGI - P6SGI utility for WebSocket

=head1 SYNOPSIS

=begin code

    use HTTP::Server::Tiny;
    use WebSocket::P6SGI;

    -> %env {
        ws-psgi(%env,
            on-ready => -> $ws {
                $ws.send('hoge');
            },
            on-text => -> $ws, $txt {
                $ws.send-text(uc $txt);
                if $txt eq 'quit' {
                    $ws.close();
                }
            },
            on-binary => -> $ws, $binary {
                $ws.send-binary($binary);
            },
            on-close => -> $ws {
                say "closing socket";
            },
        );
    }

=end code

=head1 DESCRIPTION

=end pod

