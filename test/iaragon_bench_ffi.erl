%% Test support for performance measurements: run a closure while a sampler
%% process records the peak of erlang:memory(binary) — where file contents
%% live (large binaries are reference-counted, off-heap), so a whole-file
%% read shows up here even when the caller's heap stays small.
-module(iaragon_bench_ffi).
-export([peak_binary_memory/1, deep_size_bytes/1]).

%% Exact heap footprint of a term (deep), in bytes — what the in-memory
%% remote model really costs inside the reconciler.
deep_size_bytes(Term) ->
    erts_debug:size(Term) * erlang:system_info(wordsize).

peak_binary_memory(Fun) ->
    Caller = self(),
    Baseline = erlang:memory(binary),
    Sampler = spawn(fun() -> sampler(Caller, Baseline) end),
    Result = Fun(),
    Sampler ! stop,
    Peak = receive {peak, Max} -> Max end,
    {Result, Peak - Baseline}.

sampler(Caller, Max) ->
    receive
        stop -> Caller ! {peak, Max}
    after 2 ->
        sampler(Caller, max(Max, erlang:memory(binary)))
    end.
