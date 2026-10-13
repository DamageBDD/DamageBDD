%% Thin production adapters. The test suite substitutes only these effects.
-module(damage_invoice_backend).
-license("Apache-2.0").
-export([
    ready/0,
    load/0,
    save/1,
    close/0,
    put_pdf/2,
    get_pdf/1,
    billing_clock/0,
    seller/1,
    render/1,
    prepare_email/1,
    send/1,
    settlement_nft/1,
    email_bodies/1
]).
ready() -> secrets:ready().
load() -> damage_invoice_store:load().
save(D) -> damage_invoice_store:save(D).
close() -> damage_invoice_store:close().
put_pdf(Id, PDF) -> damage_invoice_store:put_pdf(Id, PDF).
get_pdf(Id) -> damage_invoice_store:get_pdf(Id).
render(I) -> damage_invoice_pdf:render(I).
send(Mail) -> damage_utils:send_prepared_email(Mail).
settlement_nft(I) -> damage_invoice_settlement_nft:mint(I).

billing_clock() ->
    DT =
        case damage_enterprise_invoices:cfg(clock, node_local) of
            node_local -> calendar:local_time();
            utc -> calendar:universal_time()
        end,
    {{Y, M, D}, {Hour, _, _}} = DT,
    {iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B", [Y, M, D])), Hour}.

seller(I) ->
    S = damage_enterprise_invoices:cfg(seller, []),
    Profile = maps:get(payment_profile, I, <<"default">>),
    Profiles = damage_enterprise_invoices:cfg(payment_profiles, []),
    Instructions0 =
        case Profile of
            <<"default">> -> proplists:get_value(payment_instructions, S, <<>>);
            _ -> proplists:get_value(Profile, Profiles, <<>>)
        end,
    Instructions = damage_invoice_model:text(to_bin(Instructions0), 1, 5000),
    case maps:get(billing_settings, I, undefined) of
        #{seller := SellerSettings} ->
            damage_invoice_model:seller_snapshot(SellerSettings, Instructions);
        _ ->
            %% Compatibility for callers that issue without the persisted settings snapshot.
            Registered = proplists:get_value(gst_registered, S, false),
            true = is_boolean(Registered),
            Name = damage_invoice_model:text(to_bin(proplists:get_value(name, S, <<>>)), 1, 200),
            RegId = damage_invoice_model:text(to_bin(proplists:get_value(abn, S, <<>>)), 0, 100),
            true = not Registered orelse RegId =/= <<>>,
            #{
                name => Name,
                legal_name => Name,
                email => damage_invoice_model:text(
                    to_bin(proplists:get_value(email, S, <<>>)), 1, 254
                ),
                address => damage_invoice_model:text(
                    to_bin(proplists:get_value(address, S, <<>>)), 0, 2000
                ),
                logo_path => <<>>,
                country_code => <<"AU">>,
                tax_registered => Registered,
                tax_name => <<"GST">>,
                tax_registration_label => <<"ABN">>,
                tax_registration_id => RegId,
                default_tax_bps => 0,
                invoice_title => <<"TAX INVOICE">>,
                abn => RegId,
                gst_registered => Registered,
                payment_instructions => Instructions
            }
    end.

prepare_email(I) ->
    try
        Id = maps:get(id, I),
        Number = maps:get(number, I),
        {ok, PDF} = get_pdf(Id),
        true =
            string:lowercase(binary:encode_hex(crypto:hash(sha256, PDF))) =:=
                maps:get(pdf_sha256, I),
        {Text, Html} = email_bodies(I),
        Customer = maps:get(customer, I),
        Hostname = to_bin(application:get_env(damage, smtp_hostname, <<>>)),
        true = re:run(Hostname, <<"^[A-Za-z0-9.-]+$">>, [{capture, none}]) =:= match,
        Generation = integer_to_binary(maps:get(generation, maps:get(delivery, I))),
        MessageId = <<"<invoice-", Id/binary, "-", Generation/binary, "@", Hostname/binary, ">">>,
        SellerName = maps:get(name, maps:get(seller, I), <<"DamageBDD">>),
        Subject = <<SellerName/binary, " invoice ", Number/binary>>,
        damage_utils:prepare_email(
            {maps:get(name, Customer), maps:get(email, Customer)},
            Subject,
            Text,
            Html,
            [
                {message_id, MessageId},
                {attachments, [{<<Number/binary, ".pdf">>, <<"application/pdf">>, PDF}]}
            ]
        )
    catch
        _:_ -> {error, email_preparation_failed}
    end.

email_bodies(I) ->
    Number = maps:get(number, I),
    C = maps:get(customer, I),
    Seller = maps:get(seller, I),
    Total = damage_invoice_model:money(maps:get(total_minor, I)),
    Values = [
        <<"Hello ">>,
        maps:get(name, C),
        <<",\n\nPlease find invoice ">>,
        Number,
        <<" attached.\n\nService: ">>,
        maps:get(title, I),
        <<"\nService period: ">>,
        maps:get(period_start, I),
        <<" to ">>,
        maps:get(period_end, I),
        <<"\nTotal: ">>,
        maps:get(currency, I),
        <<" ">>,
        Total,
        <<"\nDue date: ">>,
        maps:get(due_on, I),
        <<"\nPayment reference: ">>,
        Number,
        <<"\n\n">>,
        maps:get(payment_instructions, Seller),
        <<"\n\n">>,
        maps:get(notes, I),
        <<"\n\nThank you,\n">>,
        maps:get(name, Seller),
        <<"\n">>,
        maps:get(email, Seller),
        <<"\n">>
    ],
    Text = iolist_to_binary(Values),
    Escaped = html(Text),
    Html =
        <<"<!doctype html><html><body><div style=\"font-family:Arial,sans-serif;max-width:680px;line-height:1.6;white-space:pre-wrap\">",
            Escaped/binary, "</div></body></html>">>,
    {Text, Html}.
html(B) ->
    iolist_to_binary([
        case C of
            $& -> <<"&amp;">>;
            $< -> <<"&lt;">>;
            $> -> <<"&gt;">>;
            $" -> <<"&quot;">>;
            $' -> <<"&#39;">>;
            _ -> <<C/utf8>>
        end
     || <<C/utf8>> <= B
    ]).
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
