%% Test support: set a file's mtime, so retention tests can age trash
%% entries without sleeping.
-module(iaragon_touch_ffi).
-export([set_mtime/2]).

set_mtime(Path, MtimeUnix) ->
    case file:change_time(binary_to_list(Path),
                          calendar:system_time_to_universal_time(MtimeUnix, second)) of
        ok -> {ok, nil};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~0p", [Reason]))}
    end.
