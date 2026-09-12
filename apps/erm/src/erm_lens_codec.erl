%%% One bounded JSON boundary for relays, decoder replies, and attestations.
%%% Nostr event IDs continue to use their dedicated canonical serializer.
-module(erm_lens_codec).
-export([encode/1, decode/1]).

encode(Value) ->
    case codec() of
        json -> protect(fun() -> iolist_to_binary(json:encode(Value)) end);
        jsx -> protect(fun() -> iolist_to_binary(jsx:encode(Value)) end);
        unavailable -> {error, json_codec_unavailable}
    end.

decode(Data) when is_binary(Data), byte_size(Data) =< 262144 ->
    case codec() of
        json -> protect(fun() -> json:decode(Data) end);
        jsx -> protect(fun() -> jsx:decode(Data, [return_maps]) end);
        unavailable -> {error, json_codec_unavailable}
    end;
decode(_) -> {error, invalid_json_input}.

codec() ->
    _ = code:ensure_loaded(json),
    case erlang:function_exported(json, encode, 1) andalso
         erlang:function_exported(json, decode, 1) of
        true -> json;
        false ->
            _ = code:ensure_loaded(jsx),
            case erlang:function_exported(jsx, encode, 1) andalso
                 erlang:function_exported(jsx, decode, 2) of
                true -> jsx;
                false -> unavailable
            end
    end.

protect(Fun) ->
    try {ok, Fun()}
    %% Exceptions can contain the input (including attestation/URL data).
    catch _:_ -> {error, invalid_json} end.
