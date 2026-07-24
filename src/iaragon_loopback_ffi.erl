%% Thin FFI over gen_tcp for the OAuth loopback redirect: listen on
%% 127.0.0.1, accept exactly ONE connection, read the HTTP request line
%% ({packet, http_bin} parses it for us), answer with a tiny HTML page and
%% hand the request target back to Gleam. All interpretation of the target
%% (query params, state check) happens on the Gleam side.
-module(iaragon_loopback_ffi).
-export([open_listener/1, await_request/2]).

open_listener(Port) ->
    %% Cap the request line: any local process can reach the ephemeral port
    %% during the login window, and without this an unterminated multi-MB URI
    %% would grow the driver buffer until the login process runs out of memory
    %% (same reasoning as the status socket's packet_size). An over-long line
    %% fails cleanly as {error, emsgsize} on recv.
    Options = [binary, {packet, http_bin}, {packet_size, 8192},
               {active, false}, {ip, {127, 0, 0, 1}}, {reuseaddr, true}],
    case gen_tcp:listen(Port, Options) of
        {ok, Listen} ->
            {ok, ActualPort} = inet:port(Listen),
            {ok, {Listen, ActualPort}};
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

%% Accept connections in a LOOP until a real HTTP request arrives or the
%% overall deadline passes. Browsers open speculative preconnects to the
%% redirect origin that never send a byte; with a single accept, one of
%% those would occupy the slot and starve the actual redirect sitting in
%% the backlog — the user authorizes and the login still times out.
await_request(Listen, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    Result = accept_until(Listen, Deadline),
    gen_tcp:close(Listen),
    Result.

accept_until(Listen, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true ->
            {error, format_reason(timeout)};
        false ->
            case gen_tcp:accept(Listen, Remaining) of
                {ok, Socket} ->
                    %% A silent connection gets a small slice of the
                    %% window, not all of it: a client that intends to send
                    %% (a real browser redirect) sends immediately, so after
                    %% 2 s we move on to the next accept instead of failing
                    %% the whole login.
                    RecvTimeout = min(2000, Remaining),
                    case gen_tcp:recv(Socket, 0, RecvTimeout) of
                        {ok, {http_request, _Method, {abs_path, Target}, _Version}} ->
                            gen_tcp:send(Socket, response_bytes()),
                            gen_tcp:close(Socket),
                            {ok, Target};
                        _SilentOrBroken ->
                            %% Preconnect, garbage or an over-long line
                            %% (emsgsize): drop THIS connection, keep
                            %% listening for the real redirect.
                            gen_tcp:close(Socket),
                            accept_until(Listen, Deadline)
                    end;
                {error, Reason} ->
                    {error, format_reason(Reason)}
            end
    end.

response_bytes() ->
    Body = <<"<html><body><p>iaragon: authorization received. "
             "You can close this tab.</p></body></html>">>,
    Length = integer_to_binary(byte_size(Body)),
    <<"HTTP/1.1 200 OK\r\n"
      "Content-Type: text/html; charset=utf-8\r\n"
      "Content-Length: ", Length/binary, "\r\n"
      "Connection: close\r\n\r\n", Body/binary>>.

format_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
