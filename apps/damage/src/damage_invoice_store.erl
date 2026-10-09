%% One node-local billing authority. Root snapshot + encrypted PDF objects.
%% The gen_server is the sole root writer; its worker writes PDF objects.
%% Sync every mutation before acknowledging it.
-module(damage_invoice_store).
-license("Apache-2.0").
-include_lib("kernel/include/file.hrl").
-export([load/0, save/1, put_pdf/2, get_pdf/1, close/0]).
-define(TAB, damage_enterprise_invoice_store).

load() ->
    try
        {ok, New} = open(),
        %% Safe decoding must also work in a fresh VM before any CRUD call.
        {module, damage_invoice_model} = code:ensure_loaded(damage_invoice_model),
        case {New, dets:lookup(?TAB, root)} of
            {true, []} -> {ok, #{version => 1, customers => #{}, plans => #{}, invoices => #{},
                               admins => [], sequence => 0, audit => []}};
            {false, [{root, Enc}]} ->
                Plain = secrets:decrypt_bound(context(root), Enc),
                #{version := 1, customers := C, plans := P, invoices := I, admins := A,
                  sequence := Seq, audit := Audit} = Data = binary_to_term(Plain, [safe]),
                true = is_map(C) andalso is_map(P) andalso is_map(I) andalso is_list(A)
                    andalso is_integer(Seq) andalso Seq >= 0 andalso is_list(Audit),
                {ok, Data};
            _ -> {error, invoice_store_invalid}
        end
    catch _:_ -> {error, invoice_store_unavailable} end.

save(Data) -> write(root, term_to_binary(Data, [compressed, deterministic])).
put_pdf(Id, <<"%PDF-", _/binary>> = PDF) when byte_size(PDF) =< 10485760 ->
    write({pdf, Id}, PDF);
put_pdf(_, _) -> {error, invalid_invoice_pdf}.
get_pdf(Id) ->
    try
        case dets:lookup(?TAB, {pdf, Id}) of
            [{{pdf, Id}, Enc}] ->
                case secrets:decrypt_bound(context({pdf, Id}), Enc) of
                    <<"%PDF-", _/binary>> = PDF -> {ok, PDF};
                    _ -> {error, invoice_pdf_integrity}
                end;
            [] -> {error, not_found};
            _ -> {error, invoice_store_unavailable}
        end
    catch _:_ -> {error, invoice_store_unavailable} end.
write(Key, Plain) ->
    try
        Enc = secrets:encrypt_bound(context(Key), Plain),
        ok = dets:insert(?TAB, {Key, Enc}),
        ok = dets:sync(?TAB),
        ok
    catch _:_ -> {error, invoice_store_write_failed} end.
close() ->
    case dets:info(?TAB) of undefined -> ok; _ -> dets:close(?TAB) end.
context(root) -> #{purpose => <<"enterprise-invoice-state">>, version => 1};
context({pdf, Id}) -> #{purpose => <<"enterprise-invoice-pdf">>, invoice_id => Id, version => 1}.
open() ->
    case dets:info(?TAB) of
        undefined ->
            Config = application:get_env(damage, enterprise_invoices, []),
            Dir = filename:absname(proplists:get_value(data_dir, Config, "/var/lib/damage/invoices")),
            ok = filelib:ensure_dir(filename:join(Dir, "placeholder")),
            {ok, #file_info{type = directory}} = file:read_link_info(Dir),
            ok = file:change_mode(Dir, 8#700),
            Path = filename:join(Dir, "invoices.dets"),
            New = case file:read_link_info(Path) of
                {error, enoent} -> true;
                {ok, #file_info{type = regular}} -> false
            end,
            {ok, ?TAB} = dets:open_file(?TAB, [{file, Path}, {type, set}, {repair, false}]),
            ok = file:change_mode(Path, 8#600),
            {ok, New};
        _ -> {ok, false}
    end.
