%% Test helper: a line-protocol client for the status socket, so tests can
%% talk to the server exactly like the Dolphin plugin does.
-module(iaragon_status_client_ffi).
-export([query_lines/2]).

query_lines(SockPath, Lines) ->
    Options = [binary, {packet, line}, {active, false}],
    case gen_tcp:connect({local, binary_to_list(SockPath)}, 0, Options, 1000) of
        {ok, Sock} ->
            Result = exchange(Sock, Lines, []),
            gen_tcp:close(Sock),
            Result;
        {error, Reason} ->
            {error, describe(Reason)}
    end.

exchange(_Sock, [], Replies) ->
    {ok, lists:reverse(Replies)};
exchange(Sock, [Line | Rest], Replies) ->
    ok = gen_tcp:send(Sock, [Line, "\n"]),
    case gen_tcp:recv(Sock, 0, 2000) of
        {ok, Reply} ->
            exchange(Sock, Rest, [string:trim(Reply) | Replies]);
        {error, Reason} ->
            {error, describe(Reason)}
    end.

describe(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
