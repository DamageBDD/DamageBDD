-module(ecai_content_util).

-export([
    to_binary/1,
    to_list/1,
    mget/3,
    json_safe/1,
    sha256_hex/1,
    now_iso8601/0,
    atomic_write/2,
    endpoint/1,
    http_opts/3,
    header/2,
    base64_json/1,
    sanitize_filename/1
]).

to_binary(undefined) -> <<>>;
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(F) when is_float(F) -> float_to_binary(F, [compact]);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

to_list(L) when is_list(L) -> L;
to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(V) -> binary_to_list(to_binary(V)).

mget(Key, Map, Default) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error when is_binary(Key) ->
            try binary_to_existing_atom(Key, utf8) of
                AtomKey -> maps:get(AtomKey, Map, Default)
            catch error:badarg -> Default
            end;
        error when is_atom(Key) ->
            maps:get(atom_to_binary(Key, utf8), Map, Default);
        error -> Default
    end;
mget(_Key, _Map, Default) -> Default.

json_safe(Map) when is_map(Map) ->
    maps:from_list([{json_key(K), json_safe(V)} || {K, V} <- maps:to_list(Map)]);
json_safe(List) when is_list(List) -> [json_safe(V) || V <- List];
json_safe(Tuple) when is_tuple(Tuple) -> [json_safe(V) || V <- tuple_to_list(Tuple)];
json_safe(true) -> true;
json_safe(false) -> false;
json_safe(null) -> null;
json_safe(undefined) -> null;
json_safe(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
json_safe(Bin) when is_binary(Bin) -> Bin;
json_safe(Number) when is_number(Number) -> Number;
json_safe(Other) -> to_binary(Other).

json_key(K) when is_binary(K) -> K;
json_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
json_key(K) when is_list(K) -> unicode:characters_to_binary(K);
json_key(K) -> to_binary(K).

sha256_hex(Data) ->
    Bin = iolist_to_binary(Data),
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= crypto:hash(sha256, Bin)]).

now_iso8601() ->
    to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{unit, second}, {offset, "Z"}]
    )).

atomic_write(Path0, Data) ->
    Path = to_list(Path0),
    ok = filelib:ensure_dir(Path),
    Tmp = Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive, monotonic])),
    case file:write_file(Tmp, Data) of
        ok ->
            case file:rename(Tmp, Path) of
                ok -> ok;
                {error, Reason} ->
                    _ = file:delete(Tmp),
                    {error, {rename_failed, Reason}}
            end;
        {error, Reason} -> {error, {write_failed, Reason}}
    end.

endpoint(Url0) ->
    Url = to_binary(Url0),
    try uri_string:parse(Url) of
        Parsed when is_map(Parsed) ->
            Scheme = lower(to_binary(maps:get(scheme, Parsed, <<"http">>))),
            Host = to_binary(maps:get(host, Parsed, <<>>)),
            Port = maps:get(port, Parsed, default_port(Scheme)),
            Path0 = to_binary(maps:get(path, Parsed, <<"/">>)),
            Path1 = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
            Query = to_binary(maps:get(query, Parsed, <<>>)),
            Path = case Query of
                <<>> -> Path1;
                _ -> <<Path1/binary, "?", Query/binary>>
            end,
            case Host of
                <<>> -> {error, {invalid_url, Url}};
                _ -> {ok, #{scheme => Scheme, host => Host, port => Port, path => Path}}
            end
    catch
        Class:Reason -> {error, {invalid_url, Url, Class, Reason}}
    end.

default_port(<<"https">>) -> 443;
default_port(_) -> 80.

http_opts(#{scheme := Scheme, host := Host}, Timeout, Decode) ->
    Transport = case Scheme of <<"https">> -> tls; _ -> tcp end,
    Base = #{
        transport => Transport,
        proxy => direct,
        protocols => [http],
        connect_timeout => min(Timeout, 15000),
        timeout => Timeout,
        close => true,
        decode => Decode
    },
    case Transport of
        tls -> Base#{tls_opts => damage_gun:tls_opts(Host)};
        tcp -> Base
    end.

header(Name0, Headers) ->
    Name = lower(to_binary(Name0)),
    header_1(Name, Headers).

header_1(_Name, []) -> undefined;
header_1(Name, [{K, V} | Rest]) ->
    case lower(to_binary(K)) =:= Name of
        true -> to_binary(V);
        false -> header_1(Name, Rest)
    end;
header_1(Name, [_ | Rest]) -> header_1(Name, Rest).

base64_json(Map) when is_map(Map) -> base64:encode(jsx:encode(json_safe(Map))).

sanitize_filename(Value0) ->
    Value = lower(to_binary(Value0)),
    Chars = [
        case C of
            X when X >= $a, X =< $z -> X;
            X when X >= $0, X =< $9 -> X;
            $- -> $-;
            $_ -> $_;
            $. -> $.;
            _ -> $-
        end
     || C <- binary_to_list(Value)
    ],
    unicode:characters_to_binary(string:trim(Chars, both, "-")).

lower(Bin) -> unicode:characters_to_binary(string:lowercase(binary_to_list(Bin))).
