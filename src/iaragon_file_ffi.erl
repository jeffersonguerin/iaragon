%% Thin FFI over Erlang's file module for chunked reads: resumable uploads
%% send 256 KB-multiple pieces and must never hold a whole file in memory.
%% Returns Gleam-shaped results matching iaragon/infrastructure/fs/chunked_read.
-module(iaragon_file_ffi).
-export([open_read/1, read_chunk/2, close/1]).

open_read(Path) ->
    case file:open(binary_to_list(Path), [read, binary, raw]) of
        {ok, IoDevice} -> {ok, IoDevice};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

read_chunk(IoDevice, Size) ->
    case file:read(IoDevice, Size) of
        {ok, Data} -> {ok, {next_chunk, Data}};
        eof -> {ok, end_of_file};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

close(IoDevice) ->
    case file:close(IoDevice) of
        ok -> {ok, nil};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

format_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
