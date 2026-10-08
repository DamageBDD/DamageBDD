%% Test-only deterministic backend. NEVER a production configuration.
-module(ecai_index_rewards_test_backend).
-export([fund/3, funding/2, decode/2, pay/2, reconcile/2]).
fund(_Cfg, Label, Amount) ->
    I = #{label => Label, bolt11 => <<"mock-funding">>, status => <<"unpaid">>,
        amount_msat => Amount, payment_hash => ecai_index_reward_ledger_tests:hash(Label)},
    persistent_term:put({?MODULE, invoice}, I), {ok, I}.
funding(_Cfg, _Label) ->
    I = persistent_term:get({?MODULE, invoice}),
    {ok, I#{status => <<"paid">>, amount_received_msat => maps:get(amount_msat, I)}}.
decode(_Cfg, _Invoice) -> {ok, persistent_term:get({?MODULE, decoded})}.
pay(Cfg, P) ->
    maps:get(test_pid, Cfg) ! {fake_payment_started, self(), P},
    receive {finish_payment, Result} -> Result after 5000 -> {error, fake_timeout} end.
reconcile(_Cfg, P) ->
    {ok, #{status => complete, payment_hash => maps:get(payment_hash, P),
           amount_msat => maps:get(amount_msat, P), amount_sent_msat => maps:get(amount_msat, P)+250,
           preimage => ecai_index_job_codec:id_hex(binary:copy(<<17>>, 32))}}.
