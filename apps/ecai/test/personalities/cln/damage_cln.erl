%% Test-only scripted RPC. Compile ONLY into the isolated CLN-test beam directory.
-module(damage_cln).
-export([script/1, exhausted/0, calls/0, getinfo/0,
         list_invoices_by_label/1, create_invoice/4]).
script(Steps) -> put(cln_steps, Steps), put(cln_calls, []), ok.
exhausted() -> get(cln_steps) =:= [].
calls() -> lists:reverse(get(cln_calls)).
getinfo() -> run(getinfo, []).
list_invoices_by_label(Label) -> run(list_invoices_by_label, [Label]).
create_invoice(Amount, Description, Expiry, Label) ->
    run(create_invoice, [Amount, Description, Expiry, Label]).
run(Fun, Args) ->
    put(cln_calls, [{Fun, Args} | get(cln_calls)]),
    case get(cln_steps) of
        [{Fun, Reply} | Rest] ->
            put(cln_steps, Rest),
            case Reply of {raise, Why} -> exit(Why); _ -> Reply end;
        Other -> error({unexpected_cln_call, Fun, Args, Other})
    end.
