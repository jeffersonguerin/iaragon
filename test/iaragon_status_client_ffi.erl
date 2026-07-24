%% Test helper: a line-protocol client for the status socket, so tests can
%% talk to the server exactly like the Dolphin plugin does.
-module(iaragon_status_client_ffi).
-export([query_lines/2, slam/2]).

%% Abusive client: connect and abort (RST via linger 0) N times as fast as
%% possible, to race the acceptor's controlling_process call. Returns nil.
slam(SockPath, N) ->
    slam_loop(SockPath, N),
    nil.

slam_loop(_Path, 0) ->
    ok;
slam_loop(Path, N) ->
    case gen_tcp:connect({local, Path}, 0,
                         [binary, {active, false}, {linger, {true, 0}}], 1000) of
        {ok, Sock} -> gen_tcp:close(Sock);
        {error, _} -> ok
    end,
    slam_loop(Path, N - 1).

query_lines(SockPath, Lines) ->
    Options = [binary, {packet, line}, {active, false}],
    case gen_tcp:connect({local, SockPath}, 0, Options, 1000) of
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
