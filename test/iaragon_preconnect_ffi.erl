%% Test helper: a connection that never sends a byte, like a browser's
%% speculative preconnect to the OAuth redirect origin.
-module(iaragon_preconnect_ffi).
-export([silent_connect/1]).

silent_connect(Port) ->
    spawn(fun() ->
        case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]) of
            {ok, Sock} ->
                timer:sleep(30000),
                gen_tcp:close(Sock);
            _CannotConnect ->
                ok
        end
    end),
    nil.
