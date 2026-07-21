%% Thin FFI over Erlang's httpc for downloads that stream straight to disk
%% ({stream, Path}) — gleam_httpc only supports whole-body responses, which
%% would hold entire files in memory. TLS verification relies on the OTP >= 26
%% httpc defaults (verify_peer with OS CA certificates), the same behaviour
%% gleam_httpc's verify_tls=true mode relies on.
%%
%% Returns Gleam-shaped results: {ok, nil}, or {error, {refused_by_server,
%% Status}} / {error, {transport_failed, Reason}} matching the DownloadError
%% constructors in iaragon/infrastructure/drive/download.
-module(iaragon_download_ffi).
-export([download_to_file/4]).

download_to_file(Url, AuthorizationValue, DestPath, TimeoutMs) ->
    {ok, _Started} = application:ensure_all_started([inets, ssl]),
    Headers = [{"authorization", binary_to_list(AuthorizationValue)}],
    Request = {binary_to_list(Url), Headers},
    HttpOptions = [{timeout, TimeoutMs}],
    Options = [{stream, binary_to_list(DestPath)}, {body_format, binary}],
    case httpc:request(get, Request, HttpOptions, Options) of
        {ok, saved_to_file} ->
            {ok, nil};
        {ok, {{_Version, Status, _Phrase}, _Headers, _Body}} ->
            {error, {refused_by_server, Status}};
        {error, Reason} ->
            {error, {transport_failed,
                     unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}}
    end.
