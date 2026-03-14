%%%-------------------------------------------------------------------
%%% damage_swap_option.erl (updated)
%%% Lightning Swap Option orchestrator
%%%
%%% New workflow:
%%%   1) list_offers(ContractId) -> list offers from LightningSwapOption.aes
%%%   2) execute_offer(ContractId, OfferId, BuyerAk, IssueUrl) ->
%%%        - calls execute_offer on-chain (creates option without hash)
%%%        - reads option (lnaddress, sats)
%%%        - resolves lnaddress (LNURL-pay) to fetch bolt11 invoice
%%%        - decodes payment_hash from bolt11 via CLN
%%%        - attaches payment_hash to option on-chain
%%%        - tracks option in-memory keyed by payment_hash (for invoice_paid callback)
%%%-------------------------------------------------------------------
-module(damage_swap_option).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

%% -------------------------------------------------------------------
%% Records
%% -------------------------------------------------------------------

-record(option, {
    id,
    buyer,
    seller,
    sats_amount,
    damage_amount,
    premium = 0,
    lnaddress = undefined,
    payment_hash = undefined,
    bolt11 = undefined,
    issue_url = undefined,
    expiry_unix = undefined
}).

-record(state, {
    contract_id,
    %% PaymentHashBin() -> #option{}
    options_by_hash = #{}
}).

%% -------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------

-export([
    start_link/1,

    %% legacy (still supported)
    create_option/5,
    list_tracked/0,
    lookup_by_payment_hash/1,

    %% new
    list_offers/1,
    execute_offer/4,
    deploy_options_contract/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SWAP_OPTIONS_CONTRACT,
    "ct_2T1Zv7DnUgxWxCDWXe4i5649Tyx1uxBeBk7SUymUWpbpABiMhg"
).
%%%===================================================================
%%% Public API
%%%===================================================================

start_link(ContractId) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [ContractId], []).

%% legacy: creates hold invoice locally first, then creates option on-chain
create_option(SatsAmount, DamageAmount, BuyerAk, SellerAk, OptionTtlSecs) ->
    gen_server:call(
        ?MODULE,
        {create_option, SatsAmount, DamageAmount, BuyerAk, SellerAk, OptionTtlSecs},
        ?AE_TIMEOUT
    ).

%% List currently tracked options in memory
list_tracked() ->
    gen_server:call(?MODULE, list_tracked, ?AE_TIMEOUT).

%% Lookup an option by Lightning payment_hash
lookup_by_payment_hash(PaymentHash) ->
    gen_server:call(?MODULE, {lookup_by_payment_hash, PaymentHash}, ?AE_TIMEOUT).

%% New: list offers from contract (for UI)
list_offers(ContractId) ->
    %% This is stateless; doesn't require server pid. Useful for HTTP list.
    damage_ae:contract_call_dry(
        ContractId,
        "contracts/LightningSwapOption.aes",
        "list_offers",
        []
    ).

%% New: execute offer and immediately fetch invoice from lnaddress
execute_offer(ContractId, OfferId, BuyerAk, IssueUrl) ->
    %% Ensure server is running with this contract id (supports single-contract for now)
    ensure_started(ContractId),
    gen_server:call(?MODULE, {execute_offer, OfferId, BuyerAk, IssueUrl}, ?AE_TIMEOUT).

ensure_started(ContractId) ->
    case whereis(?MODULE) of
        undefined ->
            {ok, _} = start_link(ContractId),
            ok;
        _Pid ->
            ok
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([ContractId]) ->
    process_flag(trap_exit, true),
    cln:register_listener(invoice_paid),
    ?LOG_INFO("damage_swap_option started with contract ~p", [ContractId]),
    {ok, #state{contract_id = ContractId}};
init(Args) ->
    {stop, {bad_init_args, Args}}.

%% -------------------------------------------------------------------
%% handle_call
%% -------------------------------------------------------------------

handle_call(
    {create_option, SatsAmount, DamageAmount, BuyerAk, SellerAk, OptionTtlSecs},
    _From,
    State = #state{contract_id = ContractId, options_by_hash = Map0}
) ->
    try
        %% 1) Create the hold invoice on our CLN node
        Label = iolist_to_binary([
            "swapopt-", integer_to_list(erlang:unique_integer([monotonic, positive]))
        ]),
        Expiry = OptionTtlSecs,

        {ok, #{bolt11 := Bolt11, payment_hash := PaymentHash}} =
            cln:hold_invoice(SatsAmount, Label, Expiry),

        %% 2) Create the option in the contract (backwards compatible entrypoint)
        Now = date_util:now_to_seconds(os:timestamp()),
        ExpiryUnix = Now + OptionTtlSecs,
        Premium = 0,
        OptionId =
            damage_ae:contract_call(
                ContractId,
                "contracts/LightningSwapOption.aes",
                "create_option",
                [
                    BuyerAk,
                    SellerAk,
                    <<"">>,
                    DamageAmount,
                    SatsAmount,
                    Premium,
                    ExpiryUnix,
                    PaymentHash
                ]
            ),

        Opt =
            #option{
                id = OptionId,
                buyer = BuyerAk,
                seller = SellerAk,
                sats_amount = SatsAmount,
                damage_amount = DamageAmount,
                premium = Premium,
                payment_hash = PaymentHash,
                bolt11 = Bolt11,
                expiry_unix = ExpiryUnix
            },

        Map1 = Map0#{PaymentHash => Opt},

        Reply =
            {ok, #{
                id => OptionId,
                bolt11 => Bolt11,
                payment_hash => PaymentHash
            }},

        {reply, Reply, State#state{options_by_hash = Map1}}
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("create_option failed ~p:~p ~p", [Class, Reason, Stack]),
            {reply, {error, Reason}, State}
    end;
handle_call(
    {execute_offer, OfferId0, BuyerAk0, IssueUrl0},
    _From,
    State0 = #state{contract_id = CtId, options_by_hash = Map0}
) ->
    try
        OfferId = to_int(OfferId0),
        BuyerAk = to_bin(BuyerAk0),

        %% 1) execute offer on-chain -> option_id
        OptionId =
            damage_ae:contract_call(
                CtId,
                "contracts/LightningSwapOption.aes",
                "execute_offer",
                [OfferId, BuyerAk]
            ),

        %% 2) read option back to get lnaddress + sats_amount
        OptRes =
            damage_ae:contract_call_dry(
                CtId,
                "contracts/LightningSwapOption.aes",
                "get_option",
                [OptionId]
            ),

        #{lnaddress := LnAddr0, sats_amount := Sats} = normalize_option(OptRes),

        AmountMsat = Sats * 1000,

        %% 3) resolve lnaddress and fetch invoice immediately
        {ok, Invoice} = lnaddress_fetch_invoice(LnAddr0, AmountMsat),
        Bolt11 = maps:get(<<"pr">>, Invoice),

        %% 4) decode payment_hash from bolt11 using CLN
        {ok, PaymentHash} = decode_payment_hash(Bolt11),

        %% 5) attach payment hash to option on-chain (admin-only)
        _ =
            damage_ae:contract_call(
                CtId,
                "contracts/LightningSwapOption.aes",
                "attach_payment_hash",
                [OptionId, PaymentHash]
            ),

        %% 6) track option in-memory for invoice_paid callback
        Opt =
            #option{
                id = OptionId,
                buyer = BuyerAk,
                seller = maps:get(seller, normalize_option(OptRes)),
                sats_amount = Sats,
                damage_amount = maps:get(damage_amount, normalize_option(OptRes), undefined),
                premium = maps:get(premium, normalize_option(OptRes), 0),
                lnaddress = to_bin(LnAddr0),
                payment_hash = PaymentHash,
                bolt11 = Bolt11,
                issue_url = to_bin_opt(IssueUrl0),
                expiry_unix = maps:get(expiry, normalize_option(OptRes), undefined)
            },

        Map1 = Map0#{PaymentHash => Opt},

        Reply =
            {ok, #{
                id => OptionId,
                offer_id => OfferId,
                lnaddress => to_bin(LnAddr0),
                bolt11 => Bolt11,
                payment_hash => PaymentHash,
                issue_url => to_bin_opt(IssueUrl0)
            }},

        {reply, Reply, State0#state{options_by_hash = Map1}}
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("execute_offer failed ~p:~p ~p", [Class, Reason, Stack]),
            {reply, {error, Reason}, State0}
    end;
handle_call(list_tracked, _From, State = #state{options_by_hash = Map}) ->
    {reply, maps:values(Map), State};
handle_call({lookup_by_payment_hash, PaymentHash0}, _From, State = #state{options_by_hash = Map}) ->
    PaymentHash = to_bin(PaymentHash0),
    case maps:get(PaymentHash, Map, undefined) of
        undefined -> {reply, not_found, State};
        Opt -> {reply, {ok, Opt}, State}
    end;
handle_call(Other, _From, State) ->
    ?LOG_WARNING("unknown call ~p", [Other]),
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% invoice paid callback from CLN
handle_info(
    {cln_event, invoice_paid, Invoice}, State = #state{contract_id = CtId, options_by_hash = Map0}
) ->
    try
        PaymentHash = maps:get(payment_hash, Invoice),
        case maps:get(PaymentHash, Map0, undefined) of
            undefined ->
                {noreply, State};
            #option{id = OptionId} ->
                _ =
                    damage_ae:contract_call(
                        CtId,
                        "contracts/LightningSwapOption.aes",
                        "mark_exercised",
                        [OptionId, PaymentHash]
                    ),
                Map1 = maps:remove(PaymentHash, Map0),
                {noreply, State#state{options_by_hash = Map1}}
        end
    catch
        _:_:_ ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Helpers
%%%===================================================================

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(A) -> unicode:characters_to_binary(io_lib:format("~p", [A])).

to_bin_opt(undefined) -> undefined;
to_bin_opt(V) -> to_bin(V).

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B) ->
    binary_to_integer(B);
to_int(L) when is_list(L) ->
    list_to_integer(L).

%% normalize get_option response (depends on damage_ae decoding)
%% Expect either a map already, or nested structure that includes these fields.
normalize_option(#{lnaddress := _, sats_amount := _} = M) ->
    M;
normalize_option(#{return_value := M}) when is_map(M) ->
    M;
normalize_option(Other) ->
    erlang:error({unexpected_option_shape, Other}).

decode_payment_hash(Bolt11) ->
    %% Try cln:decodepay/1 if available, otherwise attempt generic rpc.
    case erlang:function_exported(cln, decodepay, 1) of
        true ->
            case cln:decodepay(Bolt11) of
                {ok, #{payment_hash := PH}} -> {ok, PH};
                {ok, #{<<"payment_hash">> := PH}} -> {ok, PH};
                Other -> {error, {decodepay_unexpected, Other}}
            end;
        false ->
            case erlang:function_exported(cln, rpc, 2) of
                true ->
                    case cln:rpc(<<"decodepay">>, #{bolt11 => Bolt11}) of
                        {ok, #{payment_hash := PH}} -> {ok, PH};
                        {ok, #{<<"payment_hash">> := PH}} -> {ok, PH};
                        Other -> {error, {cln_rpc_decodepay_unexpected, Other}}
                    end;
                false ->
                    {error, no_decodepay_available}
            end
    end.

%% LNURL-pay fetch
lnaddress_fetch_invoice(LnAddress0, AmountMsat) ->
    LnAddress = to_bin(LnAddress0),
    {User, Domain} = parse_lnaddress(LnAddress),

    WellKnown =
        <<"https://", Domain/binary, "/.well-known/lnurlp/", User/binary>>,
    {ok, LnurlpInfo} = http_get_json(WellKnown),

    Callback0 = to_bin(maps:get(<<"callback">>, LnurlpInfo)),
    Min = maps:get(<<"minSendable">>, LnurlpInfo, 0),
    Max = maps:get(<<"maxSendable">>, LnurlpInfo, 0),

    true = (AmountMsat >= Min),
    true = (Max =:= 0 orelse AmountMsat =< Max),

    Query = uri_string:compose_query([{<<"amount">>, integer_to_binary(AmountMsat)}]),
    Callback =
        case binary:match(Callback0, <<"?">>) of
            nomatch -> <<Callback0/binary, "?", Query/binary>>;
            _ -> <<Callback0/binary, "&", Query/binary>>
        end,

    http_get_json(Callback).

parse_lnaddress(LnAddress) ->
    case binary:split(LnAddress, <<"@">>, []) of
        [User, Domain] when User =/= <<>>, Domain =/= <<>> ->
            {User, Domain};
        _ ->
            erlang:error({bad_lnaddress, LnAddress})
    end.

http_get_json(UrlBin0) ->
    UrlBin = to_bin(UrlBin0),
    #{scheme := Scheme0, host := Host0, port := Port0, path := Path0, query := Query0} =
        uri_string:parse(UrlBin),
    Scheme = to_bin(Scheme0),
    Host = to_bin(Host0),
    Path1 = to_bin(Path0),
    Query = to_bin(Query0),

    Port =
        case Port0 of
            undefined ->
                case Scheme of
                    <<"https">> -> 443;
                    _ -> 80
                end;
            P ->
                P
        end,

    Path =
        case Path1 of
            <<>> -> <<"/">>;
            _ -> Path1
        end,
    FullPath =
        case Query of
            <<>> -> Path;
            _ -> <<Path/binary, "?", Query/binary>>
        end,

    Opts =
        case Scheme of
            <<"https">> -> #{transport => tls, tls_opts => [{verify, verify_none}]};
            _ -> #{transport => tcp}
        end,

    {ok, ConnPid} = gun:open(Host, Port, Opts),
    _ = gun:await_up(ConnPid),
    Headers = [{<<"accept">>, <<"application/json">>}],
    StreamRef = gun:get(ConnPid, FullPath, Headers),
    {response, nofin, 200, _RespHeaders} = gun:await(ConnPid, StreamRef),
    {ok, Body} = gun:await_body(ConnPid, StreamRef),
    gun:close(ConnPid),
    {ok, jsx:decode(Body)}.

deploy_options_contract() ->
    #{public_key := PubKey, private_key := _PrivateKey} =
        secrets:node_keypair(),
    damage_ae:contract_deploy(
        damage_ae:contract_path("LightningSwapOption"), [PubKey]
    ).
