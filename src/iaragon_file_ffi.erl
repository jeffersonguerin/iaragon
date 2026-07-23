%% Thin FFI over Erlang's file module for chunked reads: resumable uploads
%% send 256 KB-multiple pieces and must never hold a whole file in memory.
%% Returns Gleam-shaped results matching iaragon/infrastructure/fs/chunked_read.
-module(iaragon_file_ffi).
-export([open_read/1, read_chunk/2, close/1]).

open_read(Path) ->
    case file:open(path_chars(Path), [read, binary, raw]) of
        {ok, IoDevice} -> {ok, IoDevice};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

%% Gleam strings arrive as UTF-8 binaries. binary_to_list/1 would hand the file
%% module the raw BYTES, which it reads back as codepoints when
%% native_name_encoding is utf8 — "ç" (0xC3 0xA7) becomes "Ã§", so an accented
%% file looks missing and never uploads. Decode to codepoints instead.
path_chars(Path) ->
    case unicode:characters_to_list(Path, utf8) of
        Chars when is_list(Chars) -> Chars;
        %% Not valid UTF-8 (a mirror can hold any byte sequence): the raw bytes
        %% are the best remaining guess, and the caller reports the open error.
        _ -> binary_to_list(Path)
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
