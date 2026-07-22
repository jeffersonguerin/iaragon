%% Thin FFI: locate an executable on PATH (os:find_executable), so the
%% composition root can pick the inotify watcher only where inotify-tools
%% actually exists.
-module(iaragon_exec_ffi).
-export([find_executable/1]).

find_executable(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> false;
        _Path -> true
    end.
