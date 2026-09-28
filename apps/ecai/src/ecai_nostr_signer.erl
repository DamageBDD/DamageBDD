-module(ecai_nostr_signer).

-export([sign_event/1, sign_event/2]).

sign_event(Event) -> sign_event(Event, #{}).

sign_event(Event, Opts) when is_map(Event), is_map(Opts) ->
    case requester_pubkey(Opts) of
        {error, _} = Error -> Error;
        {ok, Requester} ->
            Now = erlang:system_time(second),
            RequestId = ecai_content_util:sha256_hex(term_to_binary({Requester, Now, Event}, [deterministic])),
            Request = #{
                requester_pubkey => Requester,
                request_id => RequestId,
                id => RequestId,
                method => <<"sign_event">>,
                event => Event,
                created_at => Now,
                skip_rate_limit => maps:get(skip_rate_limit, Opts, false)
            },
            decode_sign_response(damage_nsecbunker:handle_plain_request(Request))
    end.

requester_pubkey(Opts) ->
    V0 = maps:get(requester_pubkey, Opts,
        application:get_env(ecai, content_nostr_requester_pubkey, undefined)),
    case ecai_content_util:to_binary(V0) of
        <<>> -> {error, content_nostr_requester_pubkey_not_configured};
        V -> {ok, V}
    end.

decode_sign_response({ok, Resp}) when is_map(Resp) ->
    Error = ecai_content_util:mget(<<"error">>, Resp,
        ecai_content_util:mget(error, Resp, <<>>)),
    case empty_error(Error) of
        false -> {error, {nsecbunker_sign_rejected, Error}};
        true ->
            Result = ecai_content_util:mget(<<"result">>, Resp,
                ecai_content_util:mget(result, Resp, undefined)),
            decode_signed_event(Result)
    end;
decode_sign_response({error, _} = Error) -> Error;
decode_sign_response(Other) -> {error, {unexpected_nsecbunker_sign_response, Other}}.

decode_signed_event(Map) when is_map(Map) -> validate_signed(Map);
decode_signed_event(Bin) when is_binary(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        Map when is_map(Map) -> validate_signed(Map);
        Other -> {error, {signed_event_not_object, Other}}
    catch Class:Reason -> {error, {invalid_signed_event_json, Class, Reason}} end;
decode_signed_event(List) when is_list(List) -> decode_signed_event(unicode:characters_to_binary(List));
decode_signed_event(Other) -> {error, {signed_event_missing, Other}}.

validate_signed(Event) ->
    Id = ecai_content_util:mget(<<"id">>, Event, ecai_content_util:mget(id, Event, <<>>)),
    Sig = ecai_content_util:mget(<<"sig">>, Event, ecai_content_util:mget(sig, Event, <<>>)),
    case {ecai_content_util:to_binary(Id), ecai_content_util:to_binary(Sig)} of
        {<<>>, _} -> {error, signed_event_missing_id};
        {_, <<>>} -> {error, signed_event_missing_sig};
        _ -> {ok, Event}
    end.

empty_error(undefined) -> true;
empty_error(<<>>) -> true;
empty_error("") -> true;
empty_error(null) -> true;
empty_error(false) -> true;
empty_error(_) -> false.
