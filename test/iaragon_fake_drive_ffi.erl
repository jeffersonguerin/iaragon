%% Test support: a minimal multi-request HTTP/1.1 server on an ephemeral
%% 127.0.0.1 port, standing in for the Drive API. Google ships no official
%% Drive emulator/sandbox, so end-to-end tests speak the real wire protocol
%% to this fake. Every request is parsed and handed to a Gleam callback
%%   fun(Method, Target, Body) -> {Status, Headers, Body}
%% (all binaries; Headers a list of {Name, Value}); routing and payloads
%% live on the Gleam side.
-module(iaragon_fake_drive_ffi).
-export([start_server/1]).

start_server(Handle) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {packet, http_bin},
                                      {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    spawn(fun() -> accept_loop(Listen, Handle) end),
    Port.

accept_loop(Listen, Handle) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            spawn(fun() -> serve(Socket, Handle) end),
            accept_loop(Listen, Handle);
        {error, _Closed} ->
            ok
    end.

%% httpc reuses connections: keep answering on the same socket until the
%% peer closes.
serve(Socket, Handle) ->
    case gen_tcp:recv(Socket, 0, 30000) of
        {ok, {http_request, Method, Target, _Version}} ->
            Length = drain_headers(Socket, 0),
            Body = read_body(Socket, Length),
            {Status, Headers, RespBody} =
                Handle(method_bin(Method), target_bin(Target), Body),
            ok = gen_tcp:send(Socket, render(Status, Headers, RespBody)),
            serve(Socket, Handle);
        {ok, _Unexpected} ->
            gen_tcp:close(Socket);
        {error, _ClosedOrTimeout} ->
            gen_tcp:close(Socket)
    end.

drain_headers(Socket, Length) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, http_eoh} ->
            Length;
        {ok, {http_header, _, 'Content-Length', _, Value}} ->
            drain_headers(Socket, binary_to_integer(Value));
        {ok, {http_header, _, _Name, _, _Value}} ->
            drain_headers(Socket, Length);
        {ok, _Other} ->
            drain_headers(Socket, Length);
        {error, _} ->
            Length
    end.

read_body(_Socket, 0) ->
    <<>>;
read_body(Socket, Length) ->
    ok = inet:setopts(Socket, [{packet, raw}]),
    {ok, Body} = gen_tcp:recv(Socket, Length, 10000),
    ok = inet:setopts(Socket, [{packet, http_bin}]),
    Body.

method_bin(Method) when is_atom(Method) -> atom_to_binary(Method, utf8);
method_bin(Method) when is_binary(Method) -> Method;
method_bin(Method) when is_list(Method) -> list_to_binary(Method).

target_bin({abs_path, Target}) -> Target;
target_bin({absoluteURI, _Scheme, _Host, _Port, Target}) -> Target;
target_bin(Target) when is_binary(Target) -> Target.

render(Status, Headers, Body) ->
    HeaderLines = [[Name, ": ", Value, "\r\n"] || {Name, Value} <- Headers],
    ["HTTP/1.1 ", integer_to_list(Status), " Whatever\r\n",
     HeaderLines,
     "Content-Length: ", integer_to_list(byte_size(Body)), "\r\n",
     "Connection: keep-alive\r\n\r\n",
     Body].
