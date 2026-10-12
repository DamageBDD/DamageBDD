%% Trusted template + escaped data. No user-supplied TeX or shell command.
-module(damage_invoice_pdf).
-license("Apache-2.0").
-export([render/1, latex/1, tex/1]).

render(Invoice) ->
    Root = damage_enterprise_invoices:cfg(temp_dir, "/tmp"),
    Dir = filename:join(
        Root, "damage-invoice-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16)))
    ),
    try
        ok = file:make_dir(Dir),
        ok = file:change_mode(Dir, 8#700),
        Invoice1 = prepare_logo(Invoice, Dir),
        Source = filename:join(Dir, "invoice.tex"),
        ok = file:write_file(Source, latex(Invoice1), [binary, exclusive]),
        ok = file:change_mode(Source, 8#600),
        Engine0 = damage_enterprise_invoices:cfg(pdf_engine, "pdflatex"),
        Engine =
            case filename:pathtype(Engine0) of
                absolute -> Engine0;
                _ -> os:find_executable(Engine0)
            end,
        true = is_list(Engine),
        %% argv form does not invoke a shell. Restrict TeX file access too.
        Port = open_port({spawn_executable, Engine}, [
            binary,
            exit_status,
            stderr_to_stdout,
            use_stdio,
            {cd, Dir},
            {env, [{"openin_any", "p"}, {"openout_any", "p"}]},
            {args, [
                "-no-shell-escape",
                "-interaction=nonstopmode",
                "-halt-on-error",
                "-output-directory=.",
                "invoice.tex"
            ]}
        ]),
        Deadline = erlang:monotonic_time(millisecond) + 45000,
        case wait(Port, Deadline) of
            ok ->
                case file:read_file(filename:join(Dir, "invoice.pdf")) of
                    {ok, <<"%PDF-", _/binary>> = PDF} when byte_size(PDF) =< 10485760 -> {ok, PDF};
                    _ -> {error, invalid_pdf_output}
                end;
            Error ->
                Error
        end
    catch
        _:_ -> {error, pdf_generation_failed}
    after
        cleanup(Dir)
    end.

prepare_logo(I, Dir) ->
    Seller = maps:get(seller, I),
    case maps:get(logo_path, Seller, <<>>) of
        <<>> ->
            I;
        <<"/static/", Rel/binary>> ->
            true = binary:match(Rel, <<"..">>) =:= nomatch,
            Root = filename:join(code:priv_dir(damage), "static"),
            Src = filename:join(Root, binary_to_list(Rel)),
            {ok, Bin} = file:read_file(Src),
            true = byte_size(Bin) =< 5242880,
            Ext0 = string:lowercase(filename:extension(Src)),
            Ext =
                case Ext0 of
                    ".jpeg" -> ".jpg";
                    ".jpg" -> ".jpg";
                    ".png" -> ".png";
                    ".pdf" -> ".pdf"
                end,
            Name = list_to_binary("seller-logo" ++ Ext),
            Target = filename:join(Dir, binary_to_list(Name)),
            ok = file:write_file(Target, Bin, [binary, exclusive]),
            I#{seller => Seller#{logo_pdf_name => Name}};
        _ ->
            error(invalid_invoice_logo_path)
    end.

labelled_line(_Label, <<>>) -> <<>>;
labelled_line(Label, Value) -> <<(tex(Label))/binary, ": ", (tex(Value))/binary, "\\\\\n">>.

wait(Port, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, _}} -> wait(Port, Deadline);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, _}} -> {error, pdf_compiler_failed}
    after Remaining ->
        port_close(Port),
        {error, pdf_compiler_timeout}
    end.
cleanup(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            [file:delete(filename:join(Dir, F)) || F <- Files],
            file:del_dir(Dir),
            ok;
        _ ->
            ok
    end.

latex(I) ->
    Seller = maps:get(seller, I),
    C = maps:get(customer, I),
    Number = maps:get(number, I),
    SellerName = maps:get(name, Seller),
    LegalName = maps:get(legal_name, Seller, SellerName),
    TaxRegistered = maps:get(tax_registered, Seller, maps:get(gst_registered, Seller, false)),
    TaxName = maps:get(tax_name, Seller, <<"Tax">>),
    SellerTaxLine = labelled_line(
        maps:get(tax_registration_label, Seller, <<"Tax ID">>),
        maps:get(tax_registration_id, Seller, maps:get(abn, Seller, <<>>))
    ),
    CustomerTaxLabel = maps:get(
        tax_id_label,
        C,
        case maps:get(country_code, C, <<"AU">>) of
            <<"AU">> -> <<"ABN">>;
            _ -> <<"Tax ID">>
        end
    ),
    CustomerTaxLine = labelled_line(CustomerTaxLabel, maps:get(tax_id, C, maps:get(abn, C, <<>>))),
    LogoBlock =
        case maps:get(logo_pdf_name, Seller, <<>>) of
            <<>> ->
                <<>>;
            LogoName ->
                <<"\\includegraphics[height=1.25cm,keepaspectratio]{", LogoName/binary,
                    "}\\\\[0.35em]\n">>
        end,
    LegalLine =
        case LegalName =:= SellerName of
            true -> <<>>;
            false -> labelled_line(<<"Legal name">>, LegalName)
        end,
    Data = #{
        <<"document_title">> => tex(maps:get(document_title, I)),
        <<"number">> => tex(Number),
        <<"issued_on">> => tex(maps:get(issued_on, I)),
        <<"due_on">> => tex(maps:get(due_on, I)),
        <<"currency">> => tex(maps:get(currency, I)),
        <<"logo_block">> => LogoBlock,
        <<"seller_name">> => tex(SellerName),
        <<"seller_legal_line">> => LegalLine,
        <<"seller_tax_line">> => SellerTaxLine,
        <<"seller_country_line">> => labelled_line(
            <<"Country">>, maps:get(country_code, Seller, <<>>)
        ),
        <<"seller_email">> => tex(maps:get(email, Seller)),
        <<"seller_address">> => tex(maps:get(address, Seller)),
        <<"customer_name">> => tex(maps:get(name, C)),
        <<"customer_tax_line">> => CustomerTaxLine,
        <<"customer_country_line">> => labelled_line(
            <<"Country">>, maps:get(country_code, C, <<>>)
        ),
        <<"customer_email">> => tex(maps:get(email, C)),
        <<"customer_address">> => tex(maps:get(address, C)),
        <<"engagement">> => tex(maps:get(title, I)),
        <<"period_start">> => tex(maps:get(period_start, I)),
        <<"period_end">> => tex(maps:get(period_end, I)),
        <<"notes">> => tex(maps:get(notes, I)),
        <<"subtotal">> => damage_invoice_model:money(maps:get(subtotal_minor, I)),
        <<"tax">> => damage_invoice_model:money(maps:get(tax_minor, I)),
        <<"total">> => damage_invoice_model:money(maps:get(total_minor, I)),
        <<"tax_label">> =>
            case TaxRegistered of
                true -> tex(TaxName);
                false -> <<"Tax (none charged)">>
            end,
        <<"payment_instructions">> => tex(maps:get(payment_instructions, Seller)),
        <<"rows">> => iolist_to_binary([row(Line) || Line <- maps:get(items, I)])
    },
    Priv =
        case damage_enterprise_invoices:cfg(template_dir, undefined) of
            undefined -> filename:join([code:priv_dir(damage), "templates", "invoices"]);
            P -> P
        end,
    {ok, Template} = file:read_file(filename:join(Priv, "enterprise.tex.mustache")),
    %% Single-pass interpolation: placeholder-looking customer text is never
    %% evaluated a second time, and every dynamic field is already TeX-escaped.
    Parts = re:split(Template, <<"(\\{\\{[a-z_]+\\}\\})">>, [{return, binary}]),
    iolist_to_binary([part(P, Data) || P <- Parts]).
part(<<"{{", Rest/binary>> = P, Data) ->
    case binary:split(Rest, <<"}}">>) of
        [Key, <<>>] -> maps:get(Key, Data, P);
        _ -> P
    end;
part(P, _) ->
    P.
row(I) ->
    Description = tex(maps:get(description, I)),
    Discount =
        case maps:get(discount_minor, I) of
            0 -> <<>>;
            V -> [<<" \\newline{} {\\small Discount: ">>, damage_invoice_model:money(V), <<"}">>]
        end,
    [
        Description,
        Discount,
        <<" & ">>,
        integer_to_binary(maps:get(quantity, I)),
        <<" & ">>,
        damage_invoice_model:money(maps:get(unit_price_minor, I)),
        <<" & ">>,
        damage_invoice_model:money(maps:get(subtotal_minor, I)),
        <<" \\\\ \\hline\n">>
    ].
tex(B) when is_binary(B) ->
    iolist_to_binary([escape(C) || <<C/utf8>> <= B]).
escape($\\) -> <<"\\textbackslash{}">>;
escape(${) -> <<"\\{">>;
escape($}) -> <<"\\}">>;
escape($&) -> <<"\\&">>;
escape($%) -> <<"\\%">>;
escape($$) -> <<"\\$">>;
escape($#) -> <<"\\#">>;
escape($_) -> <<"\\_">>;
escape($~) -> <<"\\textasciitilde{}">>;
escape($^) -> <<"\\textasciicircum{}">>;
escape($\n) -> <<"\\newline{}">>;
escape($\r) -> <<>>;
escape($\t) -> <<" ">>;
escape(C) -> <<C/utf8>>.
