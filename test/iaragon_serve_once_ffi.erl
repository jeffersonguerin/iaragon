%% Test support: a one-shot HTTP server on an ephemeral 127.0.0.1 port that
%% answers the first request with the given status and body, then closes.
%% Lets download tests exercise the real httpc streaming path without any
%% network access.
-module(iaragon_serve_once_ffi).
-export([serve_once/2]).

serve_once(Status, Body) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, http_bin},
                                      {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listen, 10000),
        {ok, _RequestLine} = gen_tcp:recv(Socket, 0, 5000),
        drain_headers(Socket),
        Length = integer_to_list(byte_size(Body)),
        gen_tcp:send(Socket, ["HTTP/1.1 ", integer_to_list(Status), " Whatever\r\n",
                              "Content-Length: ", Length, "\r\n",
                              "Connection: close\r\n\r\n", Body]),
        gen_tcp:close(Socket),
        gen_tcp:close(Listen)
    end),
    Port.

drain_headers(Socket) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, http_eoh} -> ok;
        {ok, _Header} -> drain_headers(Socket);
        {error, _Reason} -> ok
    end.
