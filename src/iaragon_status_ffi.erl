%% Thin FFI: a line-protocol server on a unix domain socket, feeding each
%% trimmed request line to a Gleam callback and writing its reply back. The
%% listen socket is owned by the calling process (the supervised actor), so
%% a crashed actor closes the socket and the restarted one re-binds fresh.
-module(iaragon_status_ffi).
-export([serve_status_lines/2]).

serve_status_lines(SockPath, Answer) ->
    %% Keep the path as the UTF-8 BINARY Gleam handed us: both {local, _} and
    %% the file module take binaries as-is. binary_to_list/1 would yield the
    %% raw bytes as codepoints, which inet re-encodes to native — double
    %% encoding, so under a non-ASCII $HOME the daemon would bind a mojibake
    %% sibling path that the Dolphin plugin and the tray (which compute the
    %% true UTF-8 path) can never find.
    PathString = SockPath,
    %% A previous daemon that died without cleanup leaves the bound socket
    %% file behind; binding needs the path free.
    _ = file:delete(PathString),
    Options = [binary,
               {ifaddr, {local, PathString}},
               {packet, line},
               %% Cap one request line: a path is short, and without this an
               %% endless line with no newline would grow the driver buffer
               %% until the daemon runs out of memory. Overflow drops the
               %% connection (emsgsize on recv).
               {packet_size, 4096},
               {active, false},
               {reuseaddr, true}],
    case gen_tcp:listen(0, Options) of
        {ok, Listen} ->
            %% Owner-only: the status protocol discloses which files exist in
            %% the user's mirror, so no other local user may connect. (The
            %% fallback socket dir is not guaranteed private.)
            _ = file:change_mode(PathString, 8#600),
            Acceptor = spawn_link(fun() -> accept_clients(Listen, Answer) end),
            {ok, Acceptor};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

accept_clients(Listen, Answer) ->
    case gen_tcp:accept(Listen) of
        {ok, Client} ->
            Server = spawn(fun() -> serve_client(Client, Answer) end),
            %% Hand the socket to the per-client server. A peer that aborted
            %% between accept and here can make controlling_process return
            %% {error, closed}; drop that one client instead of letting an
            %% `ok =` assertion crash the acceptor (which would take the listen
            %% socket down until the supervisor restarts it).
            case gen_tcp:controlling_process(Client, Server) of
                ok -> ok;
                {error, _} -> gen_tcp:close(Client)
            end,
            accept_clients(Listen, Answer);
        {error, closed} ->
            ok;
        {error, _Transient} ->
            accept_clients(Listen, Answer)
    end.

serve_client(Client, Answer) ->
    case gen_tcp:recv(Client, 0) of
        {ok, Line} ->
            Reply = Answer(iolist_to_binary(string:trim(Line))),
            ok = gen_tcp:send(Client, [Reply, "\n"]),
            serve_client(Client, Answer);
        {error, _ClosedOrBroken} ->
            gen_tcp:close(Client)
    end.
