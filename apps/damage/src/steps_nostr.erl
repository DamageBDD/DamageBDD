-module(steps_nostr).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("damage.hrl").

-export([step/6]).
-export([test/0]).

-include_lib("kernel/include/logger.hrl").
step(
    _Config,
    Context,
    _,
    _N,
    ["I create and store a nostr event as", NostrEventVariable],
    Body
) ->
    ?LOG_DEBUG("create store nostr event ~p ~p", [NostrEventVariable, Body]),
    maps:put(
        NostrEventVariable,
        damage_nostr:construct_event(Body),
        Context
    );
%% Generate unsigned NIP-56 reports from monitored events in Context
%%
%% Body expects JSON like:
%% {
%%   "from": "monitored_events",
%%   "store_as": "reports_out",
%%   "report_type": "spam",
%%   "content": "reason text",
%%   "opts": {"L":"social.nos.ontology","l":"NS-spam"}
%% }
%%
step(
    _Config,
    Context,
    _,
    _N,
    ["I generate NIP-56 reports from", FromVar, "store as", OutVar],
    Body
) ->
    %% pull config from body
    ReportType = map_get_bin(Body, <<"report_type">>, <<"other">>),
    Content = map_get_bin(Body, <<"content">>, <<>>),
    Opts = maps:get(<<"opts">>, Body, #{}),

    Events = maps:get(FromVar, Context, []),
    Reports =
        [
            mk_report_from_event(E, ReportType, Content, Opts)
         || E <- Events, is_map(E)
        ],

    maps:put(OutVar, Reports, Context);
%% Publish NIP-56 reports from monitored events in Context
%%
%% Body expects JSON like:
%% {
%%   "from": "monitored_events",
%%   "store_as": "report_responses",
%%   "nsec_key": "damage_nostr_nsec",
%%   "report_type": "illegal",
%%   "content": "why",
%%   "opts": {}
%% }
%%
step(
    _Config,
    Context,
    _,
    _N,
    ["I publish NIP-56 reports from", FromVar, "store responses as", OutVar],
    Body
) ->
    NsecKey = map_get_atom_or_bin(Body, <<"nsec_key">>, damage_nostr_nsec),
    ReportType = map_get_bin(Body, <<"report_type">>, <<"other">>),
    Content = map_get_bin(Body, <<"content">>, <<>>),
    Opts = maps:get(<<"opts">>, Body, #{}),

    Events = maps:get(FromVar, Context, []),
    Responses =
        [
            publish_report_from_event(NsecKey, E, ReportType, Content, Opts)
         || E <- Events, is_map(E)
        ],

    maps:put(OutVar, Responses, Context).

%% --- helpers ------------------------------------------------------------

mk_report_from_event(Event, ReportType, Content, Opts) ->
    %% We don’t have reporter pubkey here (that’s in damage_nostr state),
    %% so we return a “report request” structure you can later sign/publish.
    %% If you want unsigned *nostr event maps*, call into damage_nostr directly
    %% with a ReporterPubKey; but steps typically don’t have it.
    ReportedPubKey = pick_pubkey(Event),
    MaybeEventId = pick_id(Event),
    #{
        reported_pubkey => ReportedPubKey,
        event_id => MaybeEventId,
        report_type => ReportType,
        content => Content,
        opts => Opts
    }.

publish_report_from_event(NsecKey, Event, ReportType, Content, Opts) ->
    ReportedPubKey = pick_pubkey(Event),
    MaybeEventId = pick_id(Event),
    %% delegate to damage_nostr publisher
    damage_nostr:post_report(NsecKey, ReportedPubKey, MaybeEventId, ReportType, Content, Opts).

pick_pubkey(#{<<"pubkey">> := P}) -> P;
pick_pubkey(#{pubkey := P}) -> P;
pick_pubkey(_) -> <<>>.

pick_id(#{<<"id">> := I}) -> I;
pick_id(#{id := I}) -> I;
pick_id(_) -> <<>>.

map_get_bin(M, K, Default) ->
    case maps:get(K, M, Default) of
        V when is_binary(V) -> V;
        V when is_list(V) -> unicode:characters_to_binary(V);
        V when is_atom(V) -> atom_to_binary(V, utf8);
        _ -> Default
    end.

map_get_atom_or_bin(M, K, DefaultAtom) ->
    case maps:get(K, M, DefaultAtom) of
        A when is_atom(A) -> A;
        B when is_binary(B) -> binary_to_atom(B, utf8);
        L when is_list(L) -> list_to_atom(L);
        _ -> DefaultAtom
    end.

test() ->
    ok.
