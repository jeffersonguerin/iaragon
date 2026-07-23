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
    end.
