-module(bop).
-behaviour(gen_server).

-author("Steven Joseph <steven@damagebdd.com>").
-copyright("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-include_lib("bop.hrl").

-export([start_link/0, init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2, code_change/3]).
-export([
         contract_call/4,
         contract_deploy/2,
         bop_keypair/0
]).


start_link() -> gen_server:start_link(?MODULE, [], []).

init([]) ->
    cln:register_listener(invoice_paid),
    {ok, #{}}.

handle_info({cln_event, invoice_paid, 
                 #{label := _Label,status := <<"paid">>,
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
                  }
} = Data, State) ->
    AudMilli = 155349870, % TODO implement price feed oracle
    ?LOG_INFO("bop: Invoice paid: ~p ~p~n", [PaymentHash, Data]),
    case gproc:lookup_local_name({bop_ws, PaymentHash}) of
        undefined -> 
            %?LOG_INFO("bop: Invoice response websocket not found.", []),
            ok;
        Pid ->
            Pid ! {invoice_paid, PaymentHash},
            ok
    end,
    Result = contract_call(
      "LightningProofRegistry",
      ?BOP_VAULT_CONTRACT,
      "register_payment",
      [
       PaymentHash,
       AmountReceivedMsat,
       AudMilli
      ]),
    {noreply, State};

handle_info(Info, State) ->
    ?LOG_INFO("bop: Invoice response websocket info ~p.", [Info]),
 {noreply, State}.
handle_call(_, _, State) -> {reply, ok, State}.
handle_cast(_, State) -> {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.

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
