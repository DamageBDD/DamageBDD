-module(bop).
-behaviour(gen_server).
-behaviour(poolboy_worker).

-author("Steven Joseph <steven@damagebdd.com>").
-copyright("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-include_lib("bop.hrl").

-export([start_link/0, start_link/1,init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-export([
         contract_call/4,
         contract_deploy/2,
         bop_keypair/0,
         get_total/1,
         get_total/0,
         get_goal/1,
         get_goal/0,
         get_deadline/1,
         get_deadline/0,
         deploy_goal_contract/0,
         msats_to_aud/2
]).
-export([test/0]).


start_link() -> 
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
start_link([]) -> gen_server:start_link(?MODULE, [], []).
init([]) ->
    process_flag(trap_exit, true),
    cln:register_listener(invoice_paid),
    Rate = case price_feed:get_price() of
               {ok, Rate0} -> Rate0;
               _ -> 161539
           end,
case ets:info(bop_goal_cache) of
    undefined ->
        ets:new(bop_goal_cache, [named_table, public, {read_concurrency, true}, {write_concurrency, true}]);
    _ ->
        ok
end,

    {ok, #{total_msats => null, goal_msats => null, goal_deadline => null, rate => Rate}}.

get_cached(Key) ->
    case ets:lookup(bop_goal_cache, Key) of
        [{_, Value}] -> {ok, Value};
        [] -> not_found
    end.

put_cached(Key, Value) ->
    ets:insert(bop_goal_cache, {Key, Value}).


-spec msats_to_aud(non_neg_integer(), float()) -> float().
msats_to_aud(Msats, BtcAudRate) ->
    (Msats / 100000000000.0) * BtcAudRate.


handle_info({cln_event, invoice_paid, 
                 #{label := Label, status := <<"paid">>,
                   description := _Description,
                   payment_hash := PaymentHash,
                   expires_at := _Expiry,
                   bolt11 := _PaymentRequest,
                   created_index := _CreatedIndex,
                   amount_msat := _AmountMsat,
                   updated_index := _UpdatedIndex,
                   payment_preimage := _PaymentPreimage,
                   pay_index := _PayIndex,
                   amount_received_msat := AmountReceivedMsat,
                   paid_at := _PaidAt
                  }} = Data,
            #{rate := Rate} = State) ->
    case Label of
        << "bop:", _/binary >> ->
            AudMilli = ceil(msats_to_aud(AmountReceivedMsat, Rate) * 1000),
            ?LOG_INFO("bop: Invoice paid: ~p ~p ~p audm ~p~n", [Label, PaymentHash, Data, AudMilli]),
            case gproc:lookup_local_name({bop_ws, PaymentHash}) of
                undefined -> ok;
                Pid ->
                    Pid ! {invoice_paid, PaymentHash},
                    ok
            end,
            case catch contract_call(
                "LightningProofRegistry",
                ?BOP_VAULT_CONTRACT,
                "register_payment",
                [
                 PaymentHash,
                 AmountReceivedMsat,
                 AudMilli
                ]) of
                #{"error_code" := "already_known", "reason" := "Invalid tx"} ->
                    {noreply, State};
                Result ->
                    ets:delete(bop_goal_cache, {?BOP_VAULT_CONTRACT, total_msats}),
                    ?LOG_INFO("bop: Invoice recorded: ~p ~n", [Result]),
                    {noreply, State#{total_msats => null}}
            end;
        _Other ->
            % Not a bop invoice, ignore it
            {noreply, State}
    end;

handle_info(Info, State) ->
    ?LOG_DEBUG("bop:handle_info ~p.", [Info]),
    {noreply, State}.
handle_call({get_goal, GoalId}, _From, State) ->
    case get_cached({GoalId, goal_msats}) of
        {ok, Cached} ->
            {reply, Cached, State};
        not_found ->
            #{"return_value" := GoalMsats} = bop:contract_call(
              "LightningProofRegistry",
              GoalId,
              "get_goal_aud",
              []),
            put_cached({GoalId, goal_msats}, GoalMsats),
            {reply, GoalMsats, State}
    end;

handle_call({get_total, GoalId}, _From, State) ->
    case get_cached({GoalId, total_msats}) of
        {ok, Cached} ->
            {reply, Cached, State};
        not_found ->
            #{"return_value" := TotalMSats} = bop:contract_call(
              "LightningProofRegistry",
              GoalId,
              "get_total_msats",
              []),
            put_cached({GoalId, total_msats}, TotalMSats),
            {reply, TotalMSats, State}
    end;
handle_call({get_deadline, GoalId}, _From, State) ->
    case get_cached({GoalId, goal_deadline}) of
        {ok, Cached} ->
            {reply, Cached, State};
        not_found ->
            #{"return_value" := Deadline} = bop:contract_call(
              "LightningProofRegistry",
              GoalId,
              "get_deadline",
              []),
            put_cached({GoalId, goal_deadline}, Deadline),
            {reply, Deadline, State}
    end;


handle_call(Info, _, State) -> 
    ?LOG_INFO("Unhandled call ~p ~p", [Info, State]),
{reply, not_implemented, State}.
handle_cast(_, State) -> {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.

get_deadline() ->
    get_deadline(?BOP_VAULT_CONTRACT).
get_deadline(GoalContractId) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(Worker, {get_deadline, GoalContractId})
        end
    ).
get_total() ->
    get_total(?BOP_VAULT_CONTRACT).
get_total(GoalContractId) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(Worker, {get_total, GoalContractId})
        end
    ).
get_goal() ->
    get_goal(?BOP_VAULT_CONTRACT).
get_goal(GoalContractId) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(Worker, {get_goal, GoalContractId})
        end
    ).
contract_call(Contract0, ContractAddress, Func, Args)->
    Contract= filename:join(["apps/bop/contracts", Contract0 ++ ".aes"]),
    Res = damage_ae:contract_call(bop_keypair(), ContractAddress,Contract, Func, Args),
    Res.
contract_deploy(Contract0, Args) ->
    Contract= filename:join(["apps/bop/contracts", Contract0 ++ ".aes"]),
    Res = damage_ae:contract_deploy(bop_keypair(), Contract,  Args),
    Res.

bop_keypair() ->
    Path = application:get_env(bop, keystore, "bop.key"),
    secrets:keypair(Path).
deploy_goal_contract() ->
    Deadline =  date_util:now_to_seconds(os:timestamp()) +   date_util:days_to_seconds(60),
    GoalAud = 500,
    RecepientLnAddr = "coordinator@bitcoinonly.party",
    bop:contract_deploy("LightningProofRegistry", [RecepientLnAddr, GoalAud, Deadline]) .
test() ->
    _Result = contract_call(
      "LightningProofRegistry",
      ?BOP_VAULT_CONTRACT,
      "register_payment",
      [
       "044327dfbc984e4c9cee5b8492544990e20189bab7e01c579bf9f635e951be12",
       1000,
       100000
      ]).
