%% Thin FFI over Erlang's httpc for downloads that stream straight to disk
%% ({stream, Path}) — gleam_httpc only supports whole-body responses, which
%% would hold entire files in memory. TLS verification relies on the httpc
%% defaults (verify_peer with OS CA certificates, the default since OTP 26),
%% the same behaviour gleam_httpc's verify_tls=true mode relies on.
%%
%% Redirects are followed HERE rather than by httpc (autoredirect is off): a
%% Drive alt=media request carries the OAuth bearer and is answered with a 302
%% to a signed googleusercontent URL that needs no credential, so forwarding
%% the Authorization header across that hop would hand the token to the
%% redirect target. This module drops the credential whenever the target's
%% scheme, host or port differs (RFC 9110 15.4). httpc itself only started
%% stripping those headers in inets 9.3.2.6 / 9.6.2.2 / 9.7.1
%% (CVE-2026-48856), so delegating the guarantee to the runtime silently
%% leaked the token on every older OTP — including the OTP 27 that current
%% distro packages still ship.
%%
%% Returns Gleam-shaped results: {ok, nil}, or {error, {refused_by_server,
%% Status}} / {error, {transport_failed, Reason}} matching the DownloadError
%% constructors in iaragon/infrastructure/drive/download.
-module(iaragon_download_ffi).
-export([download_to_file/4]).

%% Drive needs exactly one hop; the cap only has to stop a chain that never
%% terminates, now that httpc's own redirect limit is out of the picture.
-define(MAX_REDIRECTS, 5).

download_to_file(Url, AuthorizationValue, DestPath, TimeoutMs) ->
    {ok, _Started} = application:ensure_all_started([inets, ssl]),
    get_following_redirects(binary_to_list(Url),
                            binary_to_list(AuthorizationValue),
                            path_chars(DestPath),
                            TimeoutMs,
                            ?MAX_REDIRECTS).

%% Drive names are UTF-8 and routinely carry accents, so the destination is a
%% UTF-8 binary. binary_to_list/1 would pass the raw BYTES to the file layer,
%% which reads them back as codepoints when native_name_encoding is utf8 — "ç"
%% (0xC3 0xA7) lands as "Ã§". The bytes would then be written beside the wanted
%% path under a mangled lookalike and the rename into the mirror would find
%% nothing, losing the download silently. Decode to codepoints instead. (The
%% URL and the header stay byte lists: both are ASCII by construction.)
path_chars(Path) ->
    case unicode:characters_to_list(Path, utf8) of
        Chars when is_list(Chars) -> Chars;
        %% Not valid UTF-8: the raw bytes are the best remaining guess, and a
        %% failed write surfaces as a normal transport error.
        _ -> binary_to_list(Path)
    end.

get_following_redirects(_Url, _Authorization, _DestPath, _TimeoutMs, 0) ->
    {error, {transport_failed, <<"too many redirects">>}};
get_following_redirects(Url, Authorization, DestPath, TimeoutMs, HopsLeft) ->
    %% {stream, Path} APPENDS to an existing file, so a hop that already wrote
    %% bytes would concatenate into the next one. Start every hop from nothing.
    _ = file:delete(DestPath),
    Headers = case Authorization of
                  stripped -> [];
                  _ -> [{"authorization", Authorization}]
              end,
    HttpOptions = [{timeout, TimeoutMs}, {autoredirect, false}],
    Options = [{stream, DestPath}, {body_format, binary}],
    case httpc:request(get, {Url, Headers}, HttpOptions, Options) of
        {ok, saved_to_file} ->
            {ok, nil};
        {ok, {{_Version, Status, _Phrase}, RespHeaders, _Body}}
          when Status =:= 301; Status =:= 302; Status =:= 303;
               Status =:= 307; Status =:= 308 ->
            follow_redirect(Url, Authorization, DestPath, TimeoutMs, HopsLeft,
                            RespHeaders);
        {ok, {{_Version, Status, _Phrase}, _Headers, _Body}} ->
            {error, {refused_by_server, Status}};
        {error, Reason} ->
            {error, {transport_failed,
                     unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}}
    end.

follow_redirect(Url, Authorization, DestPath, TimeoutMs, HopsLeft, RespHeaders) ->
    case location(RespHeaders) of
        none ->
            {error, {transport_failed, <<"redirect without a location header">>}};
        {ok, Location} ->
            Target = resolve(Url, Location),
            %% Same origin is not a credential boundary; anything else is.
            Next = case same_origin(Url, Target) of
                       true -> Authorization;
                       false -> stripped
                   end,
            get_following_redirects(Target, Next, DestPath, TimeoutMs,
                                    HopsLeft - 1)
    end.

location([]) ->
    none;
location([{Name, Value} | Rest]) ->
    case string:lowercase(Name) of
        "location" -> {ok, string:trim(Value)};
        _ -> location(Rest)
    end.

%% A Location may be relative; resolving it against the current URL is what
%% decides which origin the next hop actually reaches.
resolve(Base, Location) ->
    case uri_string:resolve(Location, Base) of
        {error, _, _} -> Location;
        Resolved -> Resolved
    end.

same_origin(A, B) ->
    origin(A) =:= origin(B).

origin(Url) ->
    case uri_string:parse(Url) of
        Parsed when is_map(Parsed) ->
            Scheme = string:lowercase(maps:get(scheme, Parsed, "")),
            Host = string:lowercase(maps:get(host, Parsed, "")),
            {Scheme, Host, maps:get(port, Parsed, default_port(Scheme))};
        _ ->
            %% Unparseable target: a fresh ref never compares equal, so the
            %% credential is dropped. Failing closed is the only safe
            %% direction when the destination cannot be identified.
            make_ref()
    end.

default_port("https") -> 443;
default_port("http") -> 80;
default_port(_) -> undefined.
