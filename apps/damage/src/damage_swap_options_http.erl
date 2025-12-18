%%%-------------------------------------------------------------------
%%% damage_swap_options_http.erl
%%% REST API for Lightning Swap Options
%%%
%%% Routes:
%%%   GET  /api/swap_options
%%%   POST /api/swap_options
%%%
%%% Notes:
%%% - POST starts damage_swap_option gen_server on-demand using contract_id.
%%% - issue_url is stored in ETS keyed by payment_hash so GET can include it.
%%%-------------------------------------------------------------------
-module(damage_swap_options_http).

-vsn("0.1.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-export([init/2]).
-export([trails/0]).
-export([is_authorized/2]).
-export([allowed_methods/2]).
-export([content_types_provided/2]).
-export([content_types_accepted/2]).
-export([to_json/2]).
-export([from_json/2]).

-define(TRAILS_TAG, ["Lightning Swap Options"]).
-define(ISSUE_TAB, damage_swap_option_issues).

trails() ->
    [
        trails:trail(
            "/swaps",
            ?MODULE,
            #{},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "List Lightning swap options tracked by this node.",
                        produces => ["application/json"],
                        parameters => []
                    },
                post =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Create a Lightning swap option (returns bolt11 + payment_hash).",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{name => <<"contract_id">>, in => <<"body">>, required => true, type => <<"string">>},
                                #{name => <<"issue_url">>,   in => <<"body">>, required => true, type => <<"string">>},
                                #{name => <<"buyer_ak">>,    in => <<"body">>, required => true, type => <<"string">>},
                                #{name => <<"seller_ak">>,   in => <<"body">>, required => true, type => <<"string">>},
                                #{name => <<"sats_amount">>, in => <<"body">>, required => true, type => <<"integer">>},
                                #{name => <<"damage_amount">>, in => <<"body">>, required => true, type => <<"integer">>},
                                #{name => <<"expiry_seconds">>, in => <<"body">>, required => true, type => <<"integer">>}
                            ]
                    }
            }
        )
    ].

init(Req, Opts) ->
    ensure_issue_table(),
    {cowboy_rest, Req, Opts}.

%% Reuse your existing auth strategy
is_authorized(Req, State) ->
    damage_http:is_authorized(Req, State).

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

%% -------------------------------------------------------------------
%% GET /api/swap_options
%% -------------------------------------------------------------------
to_json(Req, State) ->
    %% Return whatever is currently tracked in-memory by the orchestrator
    %% (the gen_server already supports list_tracked/0). :contentReference[oaicite:3]{index=3}
    Opts0 =
        case catch damage_swap_option:list_tracked() of
            {'EXIT', _} -> [];
            Opts -> Opts
        end,

    %% Enrich with issue_url (stored locally keyed by payment_hash)
    Opts0 =
        [ enrich_issue(Opt) || Opt <- Opts0 ],

    {jsx:encode(Opts0), Req, State}.

enrich_issue(Opt) when is_map(Opt) ->
    case maps:get(payment_hash, Opt, undefined) of
        undefined ->
            Opt;
        PH ->
            case ets:lookup(?ISSUE_TAB, PH) of
                [{PH, IssueUrl}] -> maps:put(issue_url, IssueUrl, Opt);
                _ -> Opt
            end
    end;
enrich_issue(Other) ->
    %% If your list_tracked returns records, you can convert later;
    %% for now just pass through.
    Other.

%% -------------------------------------------------------------------
%% POST /api/swap_options
%% -------------------------------------------------------------------
from_json(Req, State) ->
    {ok, Body, _Req2} = cowboy_req:read_body(Req),
    Decoded =
        case catch jsx:decode(Body, [{labels, atom}, return_maps]) of
            {'EXIT', _} -> {error, bad_json};
            Map when is_map(Map) -> {ok, Map}
        end,

    case Decoded of
        {error, bad_json} ->
            reply_json(Req, State, 400, #{error => <<"Json decoding failed.">>});

        {ok, #{
            contract_id := CtId0,
            issue_url := IssueUrl0,
            buyer_ak := Buyer0,
            seller_ak := Seller0,
            sats_amount := Sats0,
            damage_amount := Damage0,
            expiry_seconds := Ttl0
        } = _In} ->
            CtId = to_bin(CtId0),
            IssueUrl = to_bin(IssueUrl0),
            Buyer = to_bin(Buyer0),
            Seller = to_bin(Seller0),
            Sats = to_int(Sats0),
            Damage = to_int(Damage0),
            Ttl = to_int(Ttl0),

            case ensure_swap_server(CtId) of
                ok ->
                    %% Call your orchestrator API. :contentReference[oaicite:4]{index=4}
                    case damage_swap_option:create_option(Sats, Damage, Buyer, Seller, Ttl) of
                        {ok, Out0} when is_map(Out0) ->
                            %% Store issue_url keyed by payment_hash so GET can include it
                            PH = maps:get(payment_hash, Out0, undefined),
                            _ = maybe_store_issue(PH, IssueUrl),

                            Out =
                                maps:merge(
                                    Out0,
                                    #{
                                        contract_id => CtId,
                                        issue_url => IssueUrl,
                                        buyer_ak => Buyer,
                                        seller_ak => Seller,
                                        sats_amount => Sats,
                                        damage_amount => Damage,
                                        expiry_seconds => Ttl
                                    }
                                ),
                            reply_json(Req, State, 201, Out);

                        {error, Reason} ->
                            reply_json(Req, State, 500, #{error => to_bin(io_lib:format("~p", [Reason]))});

                        Other ->
                            reply_json(Req, State, 500, #{error => to_bin(io_lib:format("~p", [Other]))})
                    end;

                {error, Why} ->
                    reply_json(Req, State, 500, #{error => to_bin(io_lib:format("~p", [Why]))})
            end;

        {ok, _Missing} ->
            reply_json(Req, State, 400, #{error => <<"Missing required fields.">>})
    end.

%% -------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------
ensure_issue_table() ->
    case ets:info(?ISSUE_TAB) of
        undefined ->
            ets:new(?ISSUE_TAB, [named_table, public, set, {read_concurrency, true}]),
            ok;
        _ ->
            ok
    end.

maybe_store_issue(undefined, _IssueUrl) -> ok;
maybe_store_issue(PaymentHash, IssueUrl) ->
    ets:insert(?ISSUE_TAB, {PaymentHash, IssueUrl}),
    ok.

ensure_swap_server(CtId) ->
    case whereis(damage_swap_option) of
        undefined ->
            %% Start the orchestrator with contract id. :contentReference[oaicite:5]{index=5}
            case damage_swap_option:start_link(CtId) of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok;
                Other -> {error, Other}
            end;
        _Pid ->
            ok
    end.

reply_json(Req, State, Status, Map) ->
    RespReq = cowboy_req:set_resp_body(jsx:encode(Map), Req),
    cowboy_req:reply(Status, RespReq),
    {stop, RespReq, State}.

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B) -> binary_to_integer(B);
to_int(L) when is_list(L) -> list_to_integer(L).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I).
