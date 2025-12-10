%%%-------------------------------------------------------------------
%%% damage_swap_option.erl
%%% Lightning Swap Option orchestrator
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
          payment_hash,
          bolt11,
          label,
          expiry_unix
         }).

-record(state, {
          contract_id,
          options_by_hash = #{}    %% PaymentHash -> #option{}
         }).

%% -------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------

-export([
    start_link/1,
    create_option/5,
    list_tracked/0,
    lookup_by_payment_hash/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%%%===================================================================
%%% Public API
%%%===================================================================

%% Start with known LightningSwapOption contract id (ct_...)
start_link(ContractId) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [ContractId], []).

%% Create a new swap option and corresponding CLN hold invoice
create_option(SatsAmount, DamageAmount, BuyerAk, SellerAk, OptionTtlSecs) ->
    gen_server:call(
      ?MODULE,
      {create_option, SatsAmount, DamageAmount, BuyerAk, SellerAk, OptionTtlSecs},
      ?AE_TIMEOUT).

%% List currently tracked options in memory
list_tracked() ->
    gen_server:call(?MODULE, list_tracked, ?AE_TIMEOUT).

%% Lookup an option by Lightning payment_hash
lookup_by_payment_hash(PaymentHash) ->
    gen_server:call(?MODULE, {lookup_by_payment_hash, PaymentHash}, ?AE_TIMEOUT).

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
  State = #state{contract_id = CtId, options_by_hash = Map0}
) ->
    try
        %% 1) Create Lightning hold invoice
        DescIo =
            io_lib:format(
              "damage-swap-option:~s:~B:~B",
              [BuyerAk, SatsAmount, DamageAmount]
            ),
        DescBin = unicode:characters_to_binary(lists:flatten(DescIo)),
        InvoiceExpiry = OptionTtlSecs,
        Cltv          = 144,

        %% Adjust to your actual cln:hold_invoice/4 signature
        Invoice = cln:hold_invoice(SatsAmount * 1000, DescBin, InvoiceExpiry, Cltv),

        PaymentHash = maps:get(payment_hash, Invoice),
        Bolt11      = maps:get(bolt11, Invoice),
        Label       = maps:get(label, Invoice, <<>>),

        Now    = erlang:system_time(second),
        Expiry = Now + OptionTtlSecs,

        %% 2) Register option on LightningSwapOption contract.
        %% We ignore the return for now; OptionId is local (monotonic).
        _ =
          damage_ae:contract_call(
            CtId,
            "contracts/LightningSwapOption.aes",
            "create_option",
            [BuyerAk, SellerAk, DamageAmount, SatsAmount, 0, Expiry, PaymentHash]
          ),

        OptionId = erlang:unique_integer([monotonic]),

        Opt = #option{
                id            = OptionId,
                buyer         = BuyerAk,
                seller        = SellerAk,
                sats_amount   = SatsAmount,
                damage_amount = DamageAmount,
                payment_hash  = PaymentHash,
                bolt11        = Bolt11,
                label         = Label,
                expiry_unix   = Expiry
              },

        Map1 = Map0#{PaymentHash => Opt},

        Reply =
          {ok, #{
            id           => OptionId,
            bolt11       => Bolt11,
            payment_hash => PaymentHash
          }},

        {reply, Reply, State#state{options_by_hash = Map1}}
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("create_option failed ~p:~p ~p",
                       [Class, Reason, Stack]),
            {reply, {error, Reason}, State}
    end;

handle_call(list_tracked, _From, State = #state{options_by_hash = Map}) ->
    {reply, maps:values(Map), State};

handle_call(
  {lookup_by_payment_hash, PaymentHash},
  _From,
  State = #state{options_by_hash = Map}
) ->
    case maps:get(PaymentHash, Map, undefined) of
        undefined -> {reply, not_found, State};
        Opt       -> {reply, {ok, Opt}, State}
    end;

handle_call(Other, _From, State) ->
    ?LOG_WARNING("damage_swap_option unknown call ~p", [Other]),
    {reply, {error, unknown_call}, State}.

%% -------------------------------------------------------------------
%% handle_cast
%% -------------------------------------------------------------------

handle_cast(_Msg, State) ->
    {noreply, State}.

%% -------------------------------------------------------------------
%% handle_info
%% -------------------------------------------------------------------

%% Lightning invoice was paid → mark exercised on-chain and
%% drop from in-memory map.
handle_info(
  {cln_event, invoice_paid, Invoice},
  State = #state{contract_id = CtId, options_by_hash = Map0}
) ->
    try
        PaymentHash = maps:get(payment_hash, Invoice),
        case maps:get(PaymentHash, Map0, undefined) of
            undefined ->
                %% Not ours
                {noreply, State};
            Opt = #option{id = OptionId} ->
                ?LOG_INFO("Invoice for swap option ~p paid; exercising", [OptionId]),
                _ =
                  damage_ae:contract_call(
                    CtId,
                    "contracts/LightningSwapOption.aes",
                    "mark_exercised",
                    [OptionId, PaymentHash]
                  ),
                %% optionally also trigger DAMAGE transfer here

                Map1 = maps:remove(PaymentHash, Map0),
                {noreply, State#state{options_by_hash = Map1}}
        end
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("invoice_paid handling failed ~p:~p ~p",
                       [Class, Reason, Stack]),
            {noreply, State}
    end;

handle_info(Info, State) ->
    ?LOG_DEBUG("damage_swap_option ignore info ~p", [Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    ?LOG_INFO("damage_swap_option terminating: ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% -------------------------------------------------------------------
%% Simple smoke test – run from the shell:
%%   1> damage_swap_option:test().
%% -------------------------------------------------------------------
test() ->
    io:format("Running damage_swap_option:test()...~n"),

    %% 1. Start server (or reuse running instance)
    ContractId = <<"ct_dummy_contract_id">>,
    case whereis(damage_swap_option) of
        undefined ->
            {ok, _} = start_link(ContractId),
            timer:sleep(50);
        _Pid ->
            ok
    end,

    %% 2. Create a test option
    Sats   = 1111,
    Damage = 2222,
    Buyer  = <<"ak_test_buyer">>,
    Seller = <<"ak_test_seller">>,
    TTL    = 60,

    io:format("Creating option...~n"),
    {ok, CreateRes} =
        create_option(Sats, Damage, Buyer, Seller, TTL),

    Id       = maps:get(id, CreateRes),
    PH       = maps:get(payment_hash, CreateRes),
    Bolt11   = maps:get(bolt11, CreateRes),

    io:format("Created option ID=~p~n", [Id]),
    io:format("PaymentHash=~p~n", [PH]),
    io:format("Bolt11=~p~n", [Bolt11]),

    %% 3. Lookup through API
    {ok, Opt} = lookup_by_payment_hash(PH),

    io:format("Lookup succeeded: ~p~n", [Opt]),

    %% 4. Validate fields
    true = (Opt#option.sats_amount   =:= Sats),
    true = (Opt#option.damage_amount =:= Damage),
    true = (Opt#option.buyer         =:= Buyer),
    true = (Opt#option.seller        =:= Seller),

    io:format("Field validation successful.~n"),

    %% 5. List tracked
    All = list_tracked(),
    io:format("Tracked count=~p~n", [length(All)]),

    io:format("damage_swap_option:test() OK.~n"),
    ok.
