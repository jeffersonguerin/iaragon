%% Thin FFI over executables: locate one on PATH (os:find_executable) and
%% run one to completion. run_command uses spawn_executable — arguments are
%% passed as a vector, never through a shell, so paths with spaces or quotes
%% cannot inject anything.
-module(iaragon_exec_ffi).
-export([find_executable/1, run_command/2]).

find_executable(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> false;
        _Path -> true
    end.

run_command(Exe, Args) ->
    case os:find_executable(binary_to_list(Exe)) of
        false ->
            {error, <<"executable not found: ", Exe/binary>>};
        Path ->
            Port = open_port({spawn_executable, Path},
                             [{args, Args}, exit_status, stderr_to_stdout,
                              binary]),
            collect_output(Port, <<>>)
    end.

collect_output(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_output(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, _Failure}} ->
            {error, Acc}
    %% A hung child (e.g. `gio` stalled on a dead dbus/gvfsd) would
    %% otherwise block the CALLING ACTOR forever — the transfer pool runs
    %% this synchronously per transfer, and supervision cannot see an
    %% alive-but-stuck actor. 10 s of silence (the clock resets on every
    %% chunk of output) is far beyond anything these helpers do.
    after 10000 ->
        %% The port may already be gone (the child died just as the clock
        %% fired), which makes port_close throw badarg — irrelevant here, the
        %% outcome is the same: the port is closed. try/catch rather than the
        %% old `catch` prefix, which OTP 29 deprecates.
        try port_close(Port) catch error:badarg -> true end,
        {error, <<"command produced no output for 10s; gave up">>}
    end.
