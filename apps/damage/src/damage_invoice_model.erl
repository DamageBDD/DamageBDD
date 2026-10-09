%% Pure enterprise billing validation and calendar arithmetic.
%% Money is integer minor units; quantities are positive integers.
-module(damage_invoice_model).
-license("Apache-2.0").
-export([customer/2, plan/2, items/1, date/1, add_days/2, next_date/2,
         draft/4, edit_draft/2, issue/4, money/1, id/1, text/3,
         revision/2, get/3, json_keys/2]).

get(K, M, Default) -> maps:get(atom_to_binary(K, utf8), M, Default).
json_keys(M, Keys) when is_map(M) ->
    Allowed = [atom_to_binary(K, utf8) || K <- Keys],
    check(lists:all(fun(K) -> lists:member(K, Allowed) end, maps:keys(M)),
          <<"Unknown or read-only field">>);
json_keys(_, _) -> invalid(<<"Expected a JSON object">>).

customer(M, Old) ->
    json_keys(M, [id, name, email, address, abn, enabled, revision]),
    C = #{id => id(get(id, M, maps:get(id, Old, <<>>))),
          name => text(get(name, M, maps:get(name, Old, <<>>)), 1, 200),
          email => text(get(email, M, maps:get(email, Old, <<>>)), 0, 254),
          address => text(get(address, M, maps:get(address, Old, <<>>)), 0, 2000),
          abn => text(get(abn, M, maps:get(abn, Old, <<>>)), 0, 40),
          enabled => boolean(get(enabled, M, maps:get(enabled, Old, false)))},
    Email = maps:get(email, C),
    check(re:run(maps:get(name, C), <<"[\\r\\n]">>, [{capture, none}]) =:= nomatch,
          <<"Customer name must be a single line">>),
    check(Email =:= <<>> orelse valid_email(Email), <<"Invalid billing email">>),
    check(not maps:get(enabled, C) orelse Email =/= <<>>, <<"Active customer needs an email">>),
    C#{revision => maps:get(revision, Old, 0) + 1}.

plan(M, Old) ->
    json_keys(M, [id, customer_id, name, cadence, start_date, enabled, auto_send,
                 currency, terms_days, items, notes, payment_profile, revision]),
    Start = nullable_date(get(start_date, M, maps:get(start_date, Old, null))),
    Cadence = enum(get(cadence, M, maps:get(cadence, Old, <<"monthly">>)),
                   [<<"monthly">>, <<"fortnightly">>]),
    Currency = enum(get(currency, M, maps:get(currency, Old, <<"AUD">>)),
                    [<<"AUD">>, <<"USD">>, <<"EUR">>, <<"GBP">>]),
    Count = maps:get(generated_count, Old, 0),
    check(Count =:= 0 orelse (Start =:= maps:get(start_date, Old) andalso
          Cadence =:= maps:get(cadence, Old) andalso
          get(customer_id, M, maps:get(customer_id, Old)) =:= maps:get(customer_id, Old)),
          <<"Create a new plan to change an invoiced plan's customer, start or cadence">>),
    RawItems = get(items, M, maps:get(items, Old, [])),
    {Lines, _, _, _} = items(RawItems),
    Enabled = boolean(get(enabled, M, maps:get(enabled, Old, false))),
    check(not Enabled orelse Start =/= null, <<"Choose a service commencement date before enabling">>),
    check(not Enabled orelse Lines =/= [], <<"Active plan needs line items">>),
    Anchor = case Start of null -> 1; _ -> {_, _, D} = date(Start), D end,
    #{id => id(get(id, M, maps:get(id, Old, <<>>))),
      customer_id => id(get(customer_id, M, maps:get(customer_id, Old, <<>>))),
      name => text(get(name, M, maps:get(name, Old, <<>>)), 1, 200),
      cadence => Cadence, start_date => Start,
      next_date => case Count of 0 -> Start; _ -> maps:get(next_date, Old) end,
      anchor_day => Anchor, generated_count => Count,
      enabled => Enabled, auto_send => boolean(get(auto_send, M, maps:get(auto_send, Old, false))),
      payment_profile => id(get(payment_profile, M, maps:get(payment_profile, Old, <<"default">>))),
      currency => Currency, terms_days => integer(get(terms_days, M, maps:get(terms_days, Old, 7)), 0, 90),
      items => Lines, notes => text(get(notes, M, maps:get(notes, Old, <<>>)), 0, 5000),
      revision => maps:get(revision, Old, 0) + 1}.

%% Internal line maps are accepted only on the trusted merge path above.
items(L) when is_list(L), length(L) =< 64 ->
    Lines = [line(I) || I <- L],
    Sub = lists:sum([maps:get(subtotal_minor, I) || I <- Lines]),
    Tax = lists:sum([maps:get(tax_minor, I) || I <- Lines]),
    check(Sub + Tax =< 1000000000000, <<"Invoice total exceeds limit">>),
    {Lines, Sub, Tax, Sub + Tax};
items(_) -> invalid(<<"Expected at most 64 line items">>).
line(#{description := _} = I) ->
    line(maps:from_list([{atom_to_binary(K, utf8), maps:get(K, I)} ||
        K <- [description, quantity, unit_price_minor, discount_minor, tax_bps]]));
line(M) ->
    json_keys(M, [description, quantity, unit_price_minor, discount_minor, tax_bps]),
    Description = text(get(description, M, <<>>), 1, 1500),
    Qty = integer(get(quantity, M, 1), 1, 10000),
    Unit = integer(get(unit_price_minor, M, 0), 0, 100000000),
    Discount = integer(get(discount_minor, M, 0), 0, Qty * Unit),
    Bps = integer(get(tax_bps, M, 0), 0, 10000),
    Sub = Qty * Unit - Discount,
    Tax = (Sub * Bps + 5000) div 10000,
    #{description => Description, quantity => Qty, unit_price_minor => Unit,
      discount_minor => Discount, tax_bps => Bps, subtotal_minor => Sub,
      tax_minor => Tax, total_minor => Sub + Tax}.

draft(P, C, Start, Now) ->
    check(Start =:= maps:get(next_date, P), <<"Period must match the plan's next service date">>),
    Next = next_date(P, Start),
    {Lines, Sub, Tax, Total} = items(maps:get(items, P)),
    Key = crypto:hash(sha256, term_to_binary({maps:get(id, P), Start})),
    Id = string:lowercase(binary:encode_hex(Key)),
    #{id => Id, plan_id => maps:get(id, P), customer => maps:without([enabled, revision], C),
      period_start => Start, period_end => add_days(Next, -1),
      payment_profile => maps:get(payment_profile, P, <<"default">>),
      title => maps:get(name, P), currency => maps:get(currency, P),
      terms_days => maps:get(terms_days, P), items => Lines, subtotal_minor => Sub,
      tax_minor => Tax, total_minor => Total, notes => maps:get(notes, P),
      status => <<"draft">>, number => null, revision => 1, created_at => Now,
      delivery => #{status => <<"not_sent">>, generation => 0}, audit => []}.

edit_draft(I, M) ->
    json_keys(M, [revision, items, notes, terms_days]),
    check(maps:get(status, I) =:= <<"draft">>, <<"Issued invoices are immutable">>),
    {Lines, Sub, Tax, Total} = items(get(items, M, maps:get(items, I))),
    I#{items => Lines, subtotal_minor => Sub, tax_minor => Tax, total_minor => Total,
       notes => text(get(notes, M, maps:get(notes, I)), 0, 5000),
       terms_days => integer(get(terms_days, M, maps:get(terms_days, I)), 0, 90)}.

issue(I, Seller, Number, Today) ->
    check(maps:get(total_minor, I) > 0, <<"Cannot issue an empty or zero-value invoice">>),
    check(valid_email(maps:get(email, maps:get(customer, I))), <<"Customer email is required">>),
    Registered = maps:get(gst_registered, Seller, false),
    check(Registered orelse maps:get(tax_minor, I) =:= 0, <<"Tax requires configured GST registration">>),
    I#{seller => Seller, number => Number, issued_on => Today,
       due_on => add_days(Today, maps:get(terms_days, I)),
       document_title => case Registered of true -> <<"TAX INVOICE">>; false -> <<"INVOICE">> end,
       status => <<"issuing">>}.

revision(M, Old) ->
    case get(revision, M, undefined) =:= maps:get(revision, Old) of
        true -> ok;
        false -> throw({conflict, <<"Record changed; refresh before saving">>})
    end.

id(B) when is_binary(B) ->
    check(re:run(B, <<"^[a-z0-9][a-z0-9_-]{0,63}$">>, [{capture, none}]) =:= match,
          <<"ID must be 1-64 lowercase letters, digits, underscores or hyphens">>), B;
id(_) -> invalid(<<"Invalid ID">>).
text(B, Min, Max) when is_binary(B) ->
    check(byte_size(B) >= Min andalso byte_size(B) =< Max, <<"Text field length is invalid">>),
    check(is_binary(unicode:characters_to_binary(B)), <<"Text must be UTF-8">>),
    check(re:run(B, <<"[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]">>, [{capture, none}]) =:= nomatch,
          <<"Control characters are not allowed">>), B;
text(_, _, _) -> invalid(<<"Text field must be a string">>).
valid_email(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 254 ->
    re:run(B, <<"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,63}$">>,
           [{capture, none}]) =:= match;
valid_email(_) -> false.
integer(V, Min, Max) when is_integer(V), V >= Min, V =< Max -> V;
integer(_, _, _) -> invalid(<<"Integer field is outside its allowed range">>).
boolean(true) -> true;
boolean(false) -> false;
boolean(_) -> invalid(<<"Expected a boolean">>).
enum(V, Allowed) -> check(lists:member(V, Allowed), <<"Unsupported value">>), V.
nullable_date(null) -> null;
nullable_date(<<>>) -> null;
nullable_date(B) -> _ = date(B), B.
date(<<Y:4/binary, "-", M:2/binary, "-", D:2/binary>>) ->
    check(re:run(<<Y/binary, M/binary, D/binary>>, <<"^[0-9]{8}$">>, [{capture, none}]) =:= match,
          <<"Date must contain decimal digits only">>),
    try {binary_to_integer(Y), binary_to_integer(M), binary_to_integer(D)} of
        {Yi, Mi, Di} = DT when Yi >= 2000, Yi =< 2199 ->
            check(calendar:valid_date(DT), <<"Invalid calendar date">>), {Yi, Mi, Di};
        _ -> invalid(<<"Date year must be between 2000 and 2199">>)
    catch error:_ -> invalid(<<"Invalid date">>) end;
date(_) -> invalid(<<"Date must be YYYY-MM-DD">>).
add_days(B, N) -> format_date(calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(date(B)) + N)).
next_date(#{cadence := <<"fortnightly">>}, B) -> add_days(B, 14);
next_date(#{cadence := <<"monthly">>, anchor_day := Anchor}, B) ->
    {Y, M, _} = date(B),
    {Ny, Nm} = case M of 12 -> {Y + 1, 1}; _ -> {Y, M + 1} end,
    format_date({Ny, Nm, min(Anchor, calendar:last_day_of_the_month(Ny, Nm))}).
format_date({Y, M, D}) -> iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B", [Y, M, D])).
money(N) when is_integer(N), N >= 0 -> iolist_to_binary(io_lib:format("~B.~2..0B", [N div 100, N rem 100])).
check(true, _) -> ok;
check(false, Message) -> invalid(Message).
invalid(Message) -> throw({validation, Message}).
