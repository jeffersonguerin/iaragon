%% Test support: a one-shot HTTP server on an ephemeral 127.0.0.1 port that
%% answers the first request with the given status and body, then closes.
%% Lets download tests exercise the real httpc streaming path without any
%% network access.
-module(iaragon_serve_once_ffi).
-export([serve_once/2, serve_redirect/1, serve_auth_reporting/0]).

%% Answers the first request with a 302 to Location, so download tests can
%% exercise redirect following.
serve_redirect(Location) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, http_bin},
                                      {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listen, 10000),
        {ok, _RequestLine} = gen_tcp:recv(Socket, 0, 5000),
        drain_headers(Socket),
        gen_tcp:send(Socket, ["HTTP/1.1 302 Found\r\n",
                              "Location: ", binary_to_list(Location), "\r\n",
                              "Content-Length: 0\r\n",
                              "Connection: close\r\n\r\n"]),
        gen_tcp:close(Socket),
        gen_tcp:close(Listen)
    end),
    Port.

%% Answers 200 with a body that reports whether the request carried an
%% Authorization header ("leaked-auth" if it did, "no-auth" if it did not) —
%% lets a test prove the bearer is (not) forwarded across a redirect.
serve_auth_reporting() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, http_bin},
                                      {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listen, 10000),
        {ok, _RequestLine} = gen_tcp:recv(Socket, 0, 5000),
        Body = case headers_have_auth(Socket, false) of
                   true -> <<"leaked-auth">>;
                   false -> <<"no-auth">>
               end,
        Length = integer_to_list(byte_size(Body)),
        gen_tcp:send(Socket, ["HTTP/1.1 200 OK\r\n",
                              "Content-Length: ", Length, "\r\n",
                              "Connection: close\r\n\r\n", Body]),
        gen_tcp:close(Socket),
        gen_tcp:close(Listen)
    end),
    Port.

headers_have_auth(Socket, Found) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, http_eoh} -> Found;
        {ok, {http_header, _, Name, _, _Value}} ->
            headers_have_auth(Socket, Found orelse is_auth_header(Name));
        {ok, _Other} -> headers_have_auth(Socket, Found);
        {error, _Reason} -> Found
    end.

is_auth_header(Name) when is_atom(Name) ->
    string:to_lower(atom_to_list(Name)) =:= "authorization";
is_auth_header(Name) when is_binary(Name) ->
    string:to_lower(binary_to_list(Name)) =:= "authorization";
is_auth_header(Name) when is_list(Name) ->
    string:to_lower(Name) =:= "authorization".

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
