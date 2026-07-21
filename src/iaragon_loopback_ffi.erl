%% Thin FFI over gen_tcp for the OAuth loopback redirect: listen on
%% 127.0.0.1, accept exactly ONE connection, read the HTTP request line
%% ({packet, http_bin} parses it for us), answer with a tiny HTML page and
%% hand the request target back to Gleam. All interpretation of the target
%% (query params, state check) happens on the Gleam side.
-module(iaragon_loopback_ffi).
-export([open_listener/1, await_request/2]).

open_listener(Port) ->
    Options = [binary, {packet, http_bin}, {active, false},
               {ip, {127, 0, 0, 1}}, {reuseaddr, true}],
    case gen_tcp:listen(Port, Options) of
        {ok, Listen} ->
            {ok, ActualPort} = inet:port(Listen),
            {ok, {Listen, ActualPort}};
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

await_request(Listen, TimeoutMs) ->
    Result =
        case gen_tcp:accept(Listen, TimeoutMs) of
            {ok, Socket} ->
                Response =
                    case gen_tcp:recv(Socket, 0, TimeoutMs) of
                        {ok, {http_request, _Method, {abs_path, Target}, _Version}} ->
                            gen_tcp:send(Socket, response_bytes()),
                            {ok, Target};
                        {ok, Other} ->
                            {error, format_reason({unexpected_packet, Other})};
                        {error, Reason} ->
                            {error, format_reason(Reason)}
                    end,
                gen_tcp:close(Socket),
                Response;
            {error, Reason} ->
                {error, format_reason(Reason)}
        end,
    gen_tcp:close(Listen),
    Result.

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
