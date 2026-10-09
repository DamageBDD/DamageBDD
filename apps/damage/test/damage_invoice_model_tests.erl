-module(damage_invoice_model_tests).
-include_lib("eunit/include/eunit.hrl").

money_test() ->
    ?assertEqual(<<"0.00">>, damage_invoice_model:money(0)),
    ?assertEqual(<<"850.00">>, damage_invoice_model:money(85000)),
    ?assertEqual(<<"0.01">>, damage_invoice_model:money(1)).
integer_money_and_discount_test() ->
    {[_], 105, 11, 116} = damage_invoice_model:items([line(105,0,1000)]),
    {[_], 0, 0, 0} = damage_invoice_model:items([line(550000,550000,0)]),
    ?assertThrow({validation,_}, damage_invoice_model:items([line(10,11,0)])),
    ?assertThrow({validation,_}, damage_invoice_model:items([line(1.5,0,0)])),
    ?assertThrow({validation,_}, damage_invoice_model:items([line(-1,0,0)])).
month_end_anchor_test() ->
    P = #{cadence => <<"monthly">>, anchor_day => 31},
    ?assertEqual(<<"2026-02-28">>, damage_invoice_model:next_date(P,<<"2026-01-31">>)),
    ?assertEqual(<<"2026-03-31">>, damage_invoice_model:next_date(P,<<"2026-02-28">>)),
    ?assertEqual(<<"2028-02-29">>, damage_invoice_model:next_date(P,<<"2028-01-31">>)),
    ?assertEqual(<<"2027-01-31">>, damage_invoice_model:next_date(P,<<"2026-12-31">>)).
fortnight_test() ->
    P = #{cadence => <<"fortnightly">>},
    ?assertEqual(<<"2026-10-23">>, damage_invoice_model:next_date(P,<<"2026-10-09">>)),
    ?assertEqual(<<"2027-01-08">>, damage_invoice_model:next_date(P,<<"2026-12-25">>)).
validation_test() ->
    ?assertThrow({validation,_}, damage_invoice_model:date(<<"2026-+1-01">>)),
    ?assertThrow({validation,_}, damage_invoice_model:date(<<"2026-02-29">>)),
    ?assertThrow({validation,_}, damage_invoice_model:id(<<"../../secrets">>)),
    ?assertThrow({validation,_}, damage_invoice_model:json_keys(#{<<"node_admin">> => true}, [name])),
    ?assertThrow({validation,_}, damage_invoice_model:customer(
        #{<<"id">> => <<"a">>, <<"name">> => <<"A">>, <<"email">> => <<"a@example.invalid\r\nBcc: b@example.invalid">>}, #{})).
paused_seed_test() ->
    P = plan(),
    ?assertEqual(null, maps:get(next_date,P)),
    ?assertEqual(false,maps:get(enabled,P)),
    ?assertThrow({validation,_}, damage_invoice_model:plan(#{<<"enabled">> => true}, P)).
issued_snapshot_test() ->
    P = damage_invoice_model:plan(#{<<"start_date">> => <<"2026-10-09">>},plan()),
    C = damage_invoice_model:customer(#{<<"id">> => <<"test">>, <<"name">> => <<"Test">>,
        <<"email">> => <<"test@example.invalid">>, <<"enabled">> => true},#{}),
    D = damage_invoice_model:draft(P,C,<<"2026-10-09">>,1),
    I = damage_invoice_model:issue(D,#{gst_registered => false},<<"TEST-1">>,<<"2026-10-09">>),
    ?assertEqual(<<"2026-11-08">>, maps:get(period_end,I)),
    ?assertEqual(<<"2026-10-16">>, maps:get(due_on,I)),
    ?assertEqual(<<"INVOICE">>, maps:get(document_title,I)),
    ?assertThrow({validation,_}, damage_invoice_model:edit_draft(I,#{<<"notes">> => <<"changed">>})),
    ?assertThrow({validation,_}, damage_invoice_model:issue(D#{tax_minor => 1},#{gst_registered => false},<<"TEST-2">>,<<"2026-10-09">>)).
tex_escape_test() ->
    ?assertEqual(<<"\\textbackslash{}input\\{x\\} \\& \\% \\$ \\# \\_ \\textasciitilde{} \\textasciicircum{}">>,
        damage_invoice_pdf:tex(<<"\\input{x} & % $ # _ ~ ^">>)).
line(Unit,Discount,Tax) -> #{<<"description">> => <<"Test">>, <<"quantity">> => 1,
    <<"unit_price_minor">> => Unit, <<"discount_minor">> => Discount, <<"tax_bps">> => Tax}.
plan() -> damage_invoice_model:plan(#{<<"id">> => <<"p">>, <<"customer_id">> => <<"test">>,
    <<"name">> => <<"Retainer">>, <<"items">> => [line(85000,0,0)]},#{}).
