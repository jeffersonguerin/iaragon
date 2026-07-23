%% Thin FFI for the doctor's daemon-liveness probe: one exchange on the
%% status unix socket (line out, line in), then close. Mirrors the protocol
%% of iaragon_status_ffi; timeouts are short because the peer is local.
-module(iaragon_probe_ffi).
-export([query_status_line/2, halt_with_code/1, configure_unicode_stdio/0]).

%% A bare `erl -noshell -eval ...` (the installed launcher) leaves stdout in
%% latin1, mangling the report's check marks into \x{2713}; `gleam run` sets
%% this up itself. Idempotent, so the doctor just always does it.
configure_unicode_stdio() ->
    _ = io:setopts(standard_io, [{encoding, unicode}]),
    nil.

query_status_line(SockPath, Line) ->
    %% gen_tcp:connect raises badarg (rather than returning an error tuple)
    %% for an unusable address — e.g. a socket path over the ~107-byte unix
    %% limit. The probe reports, never crashes.
    try
        connect_and_query(SockPath, Line)
    catch
        _Class:Reason -> {error, describe(Reason)}
    end.

connect_and_query(SockPath, Line) ->
    Options = [binary, {packet, line}, {packet_size, 4096}, {active, false}],
    case gen_tcp:connect({local, binary_to_list(SockPath)}, 0, Options, 1000) of
        {ok, Sock} ->
            Result =
                case gen_tcp:send(Sock, [Line, "\n"]) of
                    ok ->
                        case gen_tcp:recv(Sock, 0, 2000) of
                            {ok, Reply} ->
                                {ok, iolist_to_binary(string:trim(Reply))};
                            {error, Reason} ->
                                {error, describe(Reason)}
                        end;
                    {error, Reason} ->
                        {error, describe(Reason)}
                end,
            gen_tcp:close(Sock),
            Result;
        {error, Reason} ->
            {error, describe(Reason)}
    end.

%% The doctor's exit code makes a failed run visible to systemd (a timer'd
%% doctor unit shows up as failed); Gleam has no stdlib exit-with-code.
halt_with_code(Code) ->
    erlang:halt(Code).

describe(Reason) ->
    iolist_to_binary(io_lib:format("~0p", [Reason])).
