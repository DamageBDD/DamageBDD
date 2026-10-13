%%--------------------------------------------------------------------
%% Source acquisition/staging for Quick Index.
%% URL retrieval rejects local/special-use destinations and does not follow
%% redirects. File and URL bytes are staged into the configured local Kubo
%% node only after deterministic inspection succeeds.
%%--------------------------------------------------------------------
-module(ecai_quick_index_source).

-export([acquire/2, stage/2, normalize_cid/1]).

-ifdef(TEST).
-export([public_address/1, host_name_safe/1]).
-endif.

-define(URL_TIMEOUT_MS, 15000).

-spec acquire(map(), pos_integer()) ->
    {ok, binary(), map(), map()} | {error, term()}.
acquire(#{kind := file, bytes := Bytes} = Source, MaxBytes) when is_binary(Bytes) ->
    case byte_size(Bytes) =< MaxBytes of
        true ->
            Name = safe_name(maps:get(filename, Source, <<"upload.txt">>)),
            Mime = safe_text(maps:get(mime, Source, <<"application/octet-stream">>), 256),
            {ok, Bytes, #{filename => Name, mime => Mime}, #{kind => file, title => Name}};
        false -> {error, {source_too_large, byte_size(Bytes), MaxBytes}}
    end;
acquire(#{kind := ipfs, cid := Cid0}, MaxBytes) ->
    case normalize_cid(Cid0) of
        {ok, Cid} ->
            case damage_ipfs:cat_binary(Cid, [{max_bytes, MaxBytes}, {timeout, ?URL_TIMEOUT_MS}]) of
                {ok, Bytes} ->
                    Title = <<"IPFS ", (short(Cid))/binary>>,
                    {ok, Bytes, #{filename => <<>>, mime => <<>>},
                        #{kind => ipfs, cid => Cid, title => Title, source_key => <<"ipfs://", Cid/binary>>}};
                {error, Reason} -> {error, {ipfs_fetch_failed, Reason}}
            end;
        Error -> Error
    end;
acquire(#{kind := url, url := Url0}, MaxBytes) ->
    fetch_url(Url0, MaxBytes);
acquire(_Source, _MaxBytes) ->
    {error, invalid_source}.

-spec stage(map(), map()) -> {ok, map()} | {error, term()}.
stage(#{kind := ipfs} = Source, _Analysis) ->
    {ok, Source};
stage(#{kind := Kind, title := Title} = Source, Analysis) when Kind =:= file; Kind =:= url ->
    Bytes = maps:get(bytes, Source),
    Name = safe_name(maps:get(filename, Source, Title)),
    case add_bytes(Bytes, Name) of
        {ok, Cid} ->
            SourceKey = case Kind of
                url -> maps:get(source_key, Source);
                file -> <<"upload://", (maps:get(sha256, Analysis))/binary, "/", Name/binary>>
            end,
            {ok, #{kind => Kind, cid => Cid, title => Title, source_key => SourceKey}};
        Error -> Error
    end.

normalize_cid(Value) ->
    Bin0 = trim(to_binary(Value)),
    Bin = case Bin0 of
        <<"ipfs://", Rest/binary>> -> first_path(Rest);
        <<"/ipfs/", Rest/binary>> -> first_path(Rest);
        _ -> first_path(Bin0)
    end,
    case damage_ipfs:valid_cid(Bin) of
        true -> {ok, Bin};
        false -> {error, invalid_ipfs_cid}
    end.

fetch_url(Url0, MaxBytes) ->
    Url = trim(to_binary(Url0)),
    case parse_public_url(Url) of
        {ok, Parsed, Address, Host, Port, Transport} ->
            Path = request_path(Parsed),
            Opts0 = #{retry => 0, connect_timeout => 5000, protocols => [http], supervise => false},
            Opts = case Transport of
                tcp -> Opts0#{transport => tcp};
                tls -> Opts0#{transport => tls, tls_opts => tls_options(Host)}
            end,
            case gun:open(Address, Port, Opts) of
                {ok, Conn} ->
                    try
                        case gun:await_up(Conn, 5000) of
                            {ok, _Protocol} ->
                                Ref = gun:get(Conn, Path, [
                                    {<<"host">>, Host},
                                    {<<"accept">>, <<"text/*, application/json, application/*+json, application/xml, application/*+xml;q=0.9, */*;q=0.2">>},
                                    {<<"user-agent">>, <<"ECAI-Quick-Index/1">>}
                                ]),
                                case read_url_response(Conn, Ref, MaxBytes) of
                                    {ok, Bytes, Headers} ->
                                        Mime = response_header(<<"content-type">>, Headers, <<>>),
                                        Name = url_filename(Parsed, Host),
                                        {ok, Bytes, #{filename => Name, mime => Mime}, #{
                                            kind => url,
                                            bytes => Bytes,
                                            filename => Name,
                                            title => Name,
                                            source_key => canonical_url(Parsed)
                                        }};
                                    Error -> Error
                                end;
                            {error, Reason} -> {error, {url_connect_failed, Reason}};
                            _ -> {error, url_connect_failed}
                        end
                    after
                        try gun:close(Conn)
                        catch
                            _:_ -> ok
                        end
                    end;
                {error, Reason} -> {error, {url_connect_failed, Reason}}
            end;
        Error -> Error
    end.

read_url_response(Conn, Ref, MaxBytes) ->
    case gun:await(Conn, Ref, ?URL_TIMEOUT_MS) of
        {response, fin, Status, Headers} when Status >= 200, Status < 300 ->
            {ok, <<>>, Headers};
        {response, nofin, Status, Headers} when Status >= 200, Status < 300 ->
            case content_length_ok(Headers, MaxBytes) of
                true -> collect_body(Conn, Ref, MaxBytes, <<>> , Headers);
                false -> {error, source_too_large}
            end;
        {response, _Fin, Status, _Headers} when Status >= 300, Status < 400 ->
            {error, url_redirect_not_allowed};
        {response, _Fin, Status, _Headers} ->
            {error, {url_http_status, Status}};
        {error, timeout} -> {error, url_fetch_timeout};
        {error, Reason} -> {error, {url_fetch_failed, Reason}}
    end.

collect_body(Conn, Ref, MaxBytes, Acc, Headers) ->
    case gun:await(Conn, Ref, ?URL_TIMEOUT_MS) of
        {data, Fin, Data} when is_binary(Data) ->
            Size = byte_size(Acc) + byte_size(Data),
            case Size =< MaxBytes of
                false -> {error, {source_too_large, Size, MaxBytes}};
                true ->
                    Acc1 = <<Acc/binary, Data/binary>>,
                    case Fin of
                        fin -> {ok, Acc1, Headers};
                        nofin -> collect_body(Conn, Ref, MaxBytes, Acc1, Headers)
                    end
            end;
        {error, timeout} -> {error, url_fetch_timeout};
        {error, Reason} -> {error, {url_fetch_failed, Reason}}
    end.

parse_public_url(Url) ->
    try uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} = Parsed when Scheme =:= <<"http">>; Scheme =:= <<"https">> ->
            case maps:is_key(userinfo, Parsed) of
                true -> {error, url_userinfo_not_allowed};
                false ->
                    case maps:is_key(fragment, Parsed) of
                        true -> {error, url_fragment_not_allowed};
                        false -> resolve_public(Parsed, Scheme, Host)
                    end
            end;
        _ -> {error, invalid_url}
    catch
        _:_ -> {error, invalid_url}
    end.

resolve_public(Parsed, Scheme, Host0) ->
    Host = string:lowercase(to_binary(Host0)),
    case host_name_safe(Host) of
        false -> {error, url_host_not_allowed};
        true ->
            DefaultPort = case Scheme of <<"https">> -> 443; _ -> 80 end,
            Port = maps:get(port, Parsed, DefaultPort),
            case Port =:= DefaultPort of
                false -> {error, url_nonstandard_port_not_allowed};
                true ->
                    Addresses = resolve_addresses(Host),
                    case Addresses of
                        [] -> {error, url_dns_failed};
                        _ ->
                            case lists:all(fun public_address/1, Addresses) of
                                true -> {ok, Parsed, hd(Addresses), Host, Port, case Scheme of <<"https">> -> tls; _ -> tcp end};
                                false -> {error, url_private_address_not_allowed}
                            end
                    end
            end
    end.

resolve_addresses(Host) ->
    Name = binary_to_list(Host),
    V4 = case inet:getaddrs(Name, inet) of {ok, A4} -> A4; _ -> [] end,
    V6 = case inet:getaddrs(Name, inet6) of {ok, A6} -> A6; _ -> [] end,
    lists:usort(V4 ++ V6).

host_name_safe(<<>>) -> false;
host_name_safe(Host) ->
    Host =/= <<"localhost">> andalso
    not suffix(Host, <<".localhost">>) andalso
    not suffix(Host, <<".local">>) andalso
    not suffix(Host, <<".internal">>).

public_address({A, B, C, _D}) ->
    not (
        A =:= 0 orelse A =:= 10 orelse A =:= 127 orelse
        (A =:= 100 andalso B >= 64 andalso B =< 127) orelse
        (A =:= 169 andalso B =:= 254) orelse
        (A =:= 172 andalso B >= 16 andalso B =< 31) orelse
        (A =:= 192 andalso B =:= 168) orelse
        (A =:= 192 andalso B =:= 0 andalso C =:= 0) orelse
        (A =:= 192 andalso B =:= 0 andalso C =:= 2) orelse
        (A =:= 192 andalso B =:= 88 andalso C =:= 99) orelse
        (A =:= 198 andalso (B =:= 18 orelse B =:= 19)) orelse
        (A =:= 198 andalso B =:= 51 andalso C =:= 100) orelse
        (A =:= 203 andalso B =:= 0 andalso C =:= 113) orelse
        A >= 224
    );
public_address({0,0,0,0,0,0,0,0}) -> false;
public_address({0,0,0,0,0,0,0,1}) -> false;
public_address({0,0,0,0,0,16#ffff,X,Y}) ->
    public_address({X bsr 8, X band 16#ff, Y bsr 8, Y band 16#ff});
public_address({A, B, _C, _D, _E, _F, _G, _H}) ->
    not (
        (A band 16#fe00) =:= 16#fc00 orelse
        (A band 16#ffc0) =:= 16#fe80 orelse
        (A band 16#ffc0) =:= 16#fec0 orelse
        (A band 16#ff00) =:= 16#ff00 orelse
        (A =:= 16#2001 andalso B =:= 16#0db8)
    );
public_address(_) -> false.

tls_options(Host) ->
    [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, binary_to_list(Host)},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].

request_path(Parsed) ->
    Path0 = maps:get(path, Parsed, <<"/">>),
    Path = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
    case maps:get(query, Parsed, undefined) of
        undefined -> Path;
        <<>> -> Path;
        Query -> <<Path/binary, "?", Query/binary>>
    end.

canonical_url(Parsed) ->
    to_binary(uri_string:recompose(maps:remove(fragment, Parsed))).

url_filename(Parsed, Host) ->
    Path = maps:get(path, Parsed, <<>>),
    Parts = [P || P <- binary:split(Path, <<"/">>, [global]), P =/= <<>>],
    Candidate = case Parts of [] -> Host; _ -> lists:last(Parts) end,
    safe_name(percent_decode(Candidate)).

response_header(Name, Headers, Default) ->
    Lower = string:lowercase(Name),
    case lists:dropwhile(fun({K, _V}) -> string:lowercase(K) =/= Lower end, Headers) of
        [{_, V} | _] -> safe_text(V, 512);
        [] -> Default
    end.

content_length_ok(Headers, MaxBytes) ->
    case response_header(<<"content-length">>, Headers, <<>>) of
        <<>> -> true;
        Value ->
            try binary_to_integer(Value) =< MaxBytes catch _:_ -> true end
    end.

add_bytes(Bytes, Name) ->
    Filename = unicode:characters_to_list(Name),
    case damage_ipfs:add({data, Bytes, Filename}) of
        Result -> extract_cid(Result)
    end.

extract_cid({ok, Value}) -> extract_cid(Value);
extract_cid(#{<<"Hash">> := Cid}) -> valid_added_cid(Cid);
extract_cid(#{<<"hash">> := Cid}) -> valid_added_cid(Cid);
extract_cid(#{hash := Cid}) -> valid_added_cid(Cid);
extract_cid([Head | Rest]) ->
    case extract_cid(Head) of
        {ok, _} = Ok -> Ok;
        _ -> extract_cid(Rest)
    end;
extract_cid([]) -> {error, invalid_ipfs_add_response};
extract_cid(Cid) when is_binary(Cid) -> valid_added_cid(Cid);
extract_cid({error, _} = Error) -> Error;
extract_cid(_Other) -> {error, invalid_ipfs_add_response}.

valid_added_cid(Cid0) ->
    Cid = to_binary(Cid0),
    case damage_ipfs:valid_cid(Cid) of
        true -> {ok, Cid};
        false -> {error, invalid_ipfs_add_cid}
    end.

safe_name(Value) ->
    Bin0 = safe_text(Value, 240),
    Base0 = unicode:characters_to_binary(filename:basename(binary_to_list(Bin0))),
    Base = re:replace(Base0, <<"[^A-Za-z0-9._+ -]">>, <<"_">>, [global, {return, binary}]),
    case trim(Base) of <<>> -> <<"source.txt">>; Name -> Name end.

safe_text(Value, Max) ->
    Bin = to_binary(Value),
    case byte_size(Bin) =< Max of true -> Bin; false -> binary:part(Bin, 0, Max) end.

to_binary(Bin) when is_binary(Bin) -> Bin;
to_binary(List) when is_list(List) -> unicode:characters_to_binary(List);
to_binary(undefined) -> <<>>;
to_binary(null) -> <<>>;
to_binary(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).

trim(Bin) -> string:trim(Bin).
short(Bin) when byte_size(Bin) =< 18 -> Bin;
short(Bin) -> <<(binary:part(Bin, 0, 10))/binary, "…", (binary:part(Bin, byte_size(Bin) - 6, 6))/binary>>.
first_path(Bin) -> hd(binary:split(Bin, <<"/">>, [global])).
suffix(Bin, Suffix) when byte_size(Bin) >= byte_size(Suffix) ->
    binary:part(Bin, byte_size(Bin) - byte_size(Suffix), byte_size(Suffix)) =:= Suffix;
suffix(_, _) -> false.
percent_decode(Bin) ->
    try to_binary(uri_string:percent_decode(Bin)) catch _:_ -> Bin end.
