%% Test support: a one-shot HTTP server on an ephemeral 127.0.0.1 port that
%% answers the first request with the given status and body, then closes.
%% Lets download tests exercise the real httpc streaming path without any
%% network access.
-module(iaragon_serve_once_ffi).
-export([serve_once/2, serve_redirect/1, serve_auth_reporting/0,
         serve_redirect_to_self/0, serve_redirect_loop/0]).

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

%% Answers the first request with a 302 to its OWN port, then reports whether
%% the redirected request still carried the Authorization header. Same scheme,
%% same host, same port — the one case that is NOT a credential boundary, so
%% the bearer is expected to survive.
serve_redirect_to_self() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, http_bin},
                                      {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    Location = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/signed",
    spawn(fun() ->
        {ok, First} = gen_tcp:accept(Listen, 10000),
        {ok, _RequestLine} = gen_tcp:recv(First, 0, 5000),
        drain_headers(First),
        gen_tcp:send(First, ["HTTP/1.1 302 Found\r\n",
                             "Location: ", Location, "\r\n",
                             "Content-Length: 0\r\n",
                             "Connection: close\r\n\r\n"]),
        gen_tcp:close(First),
        {ok, Second} = gen_tcp:accept(Listen, 10000),
        {ok, _SecondLine} = gen_tcp:recv(Second, 0, 5000),
        Body = case headers_have_auth(Second, false) of
                   true -> <<"leaked-auth">>;
                   false -> <<"no-auth">>
               end,
        Length = integer_to_list(byte_size(Body)),
        gen_tcp:send(Second, ["HTTP/1.1 200 OK\r\n",
                              "Content-Length: ", Length, "\r\n",
                              "Connection: close\r\n\r\n", Body]),
        gen_tcp:close(Second),
        gen_tcp:close(Listen)
    end),
    Port.

%% Redirects to itself forever, so a test can prove the follower gives up
%% instead of looping — httpc's own redirect cap no longer applies now that
%% the FFI follows redirects itself.
serve_redirect_loop() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, http_bin},
                                      {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    Location = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/again",
    spawn(fun() -> redirect_loop(Listen, Location) end),
    Port.

redirect_loop(Listen, Location) ->
    case gen_tcp:accept(Listen, 10000) of
        {ok, Socket} ->
            {ok, _RequestLine} = gen_tcp:recv(Socket, 0, 5000),
            drain_headers(Socket),
            gen_tcp:send(Socket, ["HTTP/1.1 302 Found\r\n",
                                  "Location: ", Location, "\r\n",
                                  "Content-Length: 0\r\n",
                                  "Connection: close\r\n\r\n"]),
            gen_tcp:close(Socket),
            redirect_loop(Listen, Location);
        {error, _Reason} ->
            gen_tcp:close(Listen)
    end.

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
