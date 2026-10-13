%%--------------------------------------------------------------------
%% DamageBDD steps for Phase 3 relay/NIP-46 bridge behaviour.
%% These steps avoid live relays by default and verify the relay boundary:
%% signing result is independent of publication result.
%%--------------------------------------------------------------------
-module(steps_nsecbunker_phase3).

-export([step/6, step_dry/6]).

-define(NS, nsecbunker_phase3).

-define(S_MODE, ["Phase", "3", "relay publication mode is", Mode]).
-define(S_CLIENT, ["Phase", "3", "disposable client pubkey is", Client]).
-define(S_BUNKER, ["Phase", "3", "disposable bunker pubkey is", Bunker]).
-define(S_RESPONSE, ["the bunker has produced a signed NIP46 response event"]).
-define(S_HANDLE, ["the Phase", "3", "relay client handles the signed response event"]).
-define(S_RESULT_OK, ["the Phase", "3", "relay result MUST be ok"]).
-define(S_RESPONSE_PRESENT, ["the Phase", "3", "relay result MUST contain a response event"]).
-define(S_PUBLISH_OK, ["the Phase", "3", "publication result MUST be ok"]).
-define(S_PUBLISH_FAIL, ["the Phase", "3", "publication result MUST be failure"]).
-define(S_SIGNING_SURVIVES, [
    "the Phase", "3", "signing decision MUST survive relay publication failure"
]).
-define(S_FILTER, ["the Phase", "3", "subscription filter is created"]).
-define(S_FILTER_KIND, ["the Phase", "3", "subscription filter MUST include kind", "24133"]).
-define(S_FILTER_PTAG, ["the Phase", "3", "subscription filter MUST be p tagged to the bunker"]).

step_dry(Config, Context, Keyword, LineNo, Body, Args) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args).

step(_Config, Context, _Keyword, _Line, ?S_MODE, _Args) ->
    put_ns(Context, (ns(Context))#{mode => mode(Mode)});
step(_Config, Context, _Keyword, _Line, ?S_CLIENT, _Args) ->
    put_ns(Context, (ns(Context))#{client => strip(Client)});
step(_Config, Context, _Keyword, _Line, ?S_BUNKER, _Args) ->
    put_ns(Context, (ns(Context))#{bunker => strip(Bunker)});
step(_Config, Context, _Keyword, _Line, ?S_RESPONSE, _Args) ->
    Client = maps:get(client, ns(Context), fake_client()),
    Event = #{
        id => <<"phase3-response-id">>,
        pubkey => maps:get(bunker, ns(Context), fake_bunker()),
        created_at => erlang:system_time(second),
        kind => 24133,
        tags => [[<<"p">>, Client]],
        content => <<"phase3-encrypted-response-placeholder">>,
        sig => <<"phase3-signature-placeholder">>
    },
    put_ns(Context, (ns(Context))#{response_event => Event});
step(_Config, Context, _Keyword, _Line, ?S_HANDLE, _Args) ->
    Mode = maps:get(mode, ns(Context), return_only),
    Event = maps:get(response_event, ns(Context)),
    Config = #{relay_publication_mode => Mode},
    Result = damage_nostr_relay_client:handle_bunker_result({ok, Event}, Config),
    put_ns(Context, (ns(Context))#{last_result => Result});
step(_Config, Context, _Keyword, _Line, ?S_RESULT_OK, _Args) ->
    case maps:get(last_result, ns(Context), undefined) of
        {ok, _} -> Context;
        Other -> error({phase3_result_not_ok, Other})
    end;
step(_Config, Context, _Keyword, _Line, ?S_RESPONSE_PRESENT, _Args) ->
    {ok, Map} = maps:get(last_result, ns(Context)),
    _ = maps:get(response_event, Map),
    Context;
step(_Config, Context, _Keyword, _Line, ?S_PUBLISH_OK, _Args) ->
    {ok, Map} = maps:get(last_result, ns(Context)),
    case maps:get(publish_result, Map) of
        {ok, _} -> Context;
        Other -> error({phase3_publish_not_ok, Other})
    end;
step(_Config, Context, _Keyword, _Line, ?S_PUBLISH_FAIL, _Args) ->
    {ok, Map} = maps:get(last_result, ns(Context)),
    case maps:get(publish_result, Map) of
        {error, _} -> Context;
        Other -> error({phase3_publish_not_failure, Other})
    end;
step(_Config, Context, _Keyword, _Line, ?S_SIGNING_SURVIVES, _Args) ->
    {ok, Map} = maps:get(last_result, ns(Context)),
    ok = maps:get(signing_result, Map),
    {error, _} = maps:get(publish_result, Map),
    _ = maps:get(response_event, Map),
    Context;
step(_Config, Context, _Keyword, _Line, ?S_FILTER, _Args) ->
    Bunker = maps:get(bunker, ns(Context), fake_bunker()),
    {ok, #{filter := Filter}} = damage_nostr_relay_client:subscribe(#{
        relay_publication_mode => return_only,
        bunker_pubkey_hex => Bunker
    }),
    put_ns(Context, (ns(Context))#{filter => Filter});
step(_Config, Context, _Keyword, _Line, ?S_FILTER_KIND, _Args) ->
    Filter = maps:get(filter, ns(Context)),
    [24133] = maps:get(kinds, Filter),
    Context;
step(_Config, Context, _Keyword, _Line, ?S_FILTER_PTAG, _Args) ->
    Filter = maps:get(filter, ns(Context)),
    Bunker = maps:get(bunker, ns(Context), fake_bunker()),
    [Bunker] = maps:get(<<"#p">>, Filter),
    Context.

ns(Context) ->
    maps:get(?NS, Context, #{}).

put_ns(Context, Value) ->
    Context#{?NS => Value}.

strip(V) when is_binary(V) -> trim_quotes(V);
strip(V) when is_list(V) -> trim_quotes(unicode:characters_to_binary(V));
strip(V) when is_atom(V) -> atom_to_binary(V, utf8);
strip(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

trim_quotes(Bin0) ->
    Bin = trim(Bin0),
    unquote(Bin).

unquote(Bin = <<$", Rest/binary>>) ->
    N = byte_size(Rest),
    case N > 0 andalso binary:at(Rest, N - 1) =:= $" of
        true -> binary:part(Rest, 0, N - 1);
        false -> Bin
    end;
unquote(Bin) ->
    Bin.

%% Keep this local. Some deployed OTP versions do not expose binary:trim/3.
trim(Bin) when is_binary(Bin) ->
    trim_right(trim_left(Bin)).

trim_left(<<C, Rest/binary>>) when C =:= 32; C =:= 9; C =:= 10; C =:= 13 ->
    trim_left(Rest);
trim_left(Bin) ->
    Bin.

trim_right(Bin) ->
    trim_right(Bin, byte_size(Bin)).

trim_right(_Bin, N) when N =< 0 ->
    <<>>;
trim_right(Bin, N) ->
    case binary:at(Bin, N - 1) of
        C when C =:= 32; C =:= 9; C =:= 10; C =:= 13 ->
            trim_right(binary:part(Bin, 0, N - 1), N - 1);
        _ ->
            Bin
    end.
mode(V0) ->
    V = strip(V0),
    case V of
        <<"return_only">> -> return_only;
        <<"test_fail">> -> test_fail;
        <<"normal">> -> normal;
        _ -> binary_to_atom(V, utf8)
    end.

fake_client() ->
    <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>.

fake_bunker() ->
    <<"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">>.
