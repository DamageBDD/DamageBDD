%% In-memory effects fixture. Only used when explicitly selected by EUnit.
-module(damage_invoice_test_backend).
-compile({no_auto_import,[get/1]}).
-export([reset/0, destroy/0, set/2, get/1, ready/0, load/0, save/1, close/0,
         put_pdf/2, get_pdf/1, render/1, seller/1, billing_clock/0,
         prepare_email/1, send/1]).
-define(T, damage_invoice_effects_fixture).
reset() ->
    ets:new(?T, [named_table, public, set]),
    D = #{version => 1, customers => #{}, plans => #{}, invoices => #{},
          admins => [], sequence => 0, audit => []},
    [set(K, V) || {K,V} <- [{data,D}, {ready,true}, {fail_save,false},
        {clock,{<<"2026-10-09">>,10}}, {render_mode,ok}, {send_mode,accepted},
        {prepare_mode,ok}, {sends,0}, {renders,0}]], ok.
destroy() -> ets:delete(?T), ok.
set(K,V) -> ets:insert(?T,{K,V}), ok.
get(K) -> ets:lookup_element(?T,K,2).
ready() -> get(ready).
load() -> {ok,get(data)}.
save(D) -> case get(fail_save) of true -> {error,injected_write_failure}; false -> set(data,D) end.
close() -> ok.
put_pdf(Id, PDF) -> set({pdf,Id},PDF).
get_pdf(Id) -> case ets:lookup(?T,{pdf,Id}) of [{_,PDF}] -> {ok,PDF}; [] -> {error,not_found} end.
billing_clock() -> get(clock).
seller(_) -> #{name => <<"Test supplier">>, abn => <<>>, email => <<"test@example.invalid">>,
    address => <<>>, gst_registered => false, payment_instructions => <<"TEST ONLY. DO NOT PAY.">>}.
render(I) ->
    ets:update_counter(?T,renders,1),
    case get(render_mode) of
        fail -> {error,injected_renderer_failure};
        _ -> {ok, <<"%PDF-1.4 TEST ONLY ",(maps:get(number,I))/binary>>}
    end.
prepare_email(I) ->
    case get(prepare_mode) of
        fail -> {error,injected_prepare_failure};
        block -> set(prepare_pid,self()), receive release -> {ok,I} end;
        _ -> {ok,I}
    end.
send(_) ->
    ets:update_counter(?T,sends,1),
    case get(send_mode) of
        accepted -> {ok,accepted};
        fail -> {error,smtp_outcome_unknown};
        block -> receive release -> {ok,accepted} end
    end.
