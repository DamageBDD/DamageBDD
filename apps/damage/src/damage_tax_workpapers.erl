%%% Accountant-review supporting CSV, never an official filing payload.
-module(damage_tax_workpapers).
-export([to_csv/1, filename/1]).

filename(Region) ->
    case damage_tax_regions:valid(Region) of
        true -> <<"tax-", Region/binary, "-workpaper.csv">>;
        false -> <<"tax-workpaper.csv">>
    end.

to_csv(#{<<"manifest">> := #{<<"entries">> := Entries} = Manifest}) ->
    Region = maps:get(<<"jurisdiction">>, Manifest, <<"AU">>),
    Currency = maps:get(<<"currency">>, Manifest, <<"AUD">>),
    Fields = fields(Region),
    Header = [<<"jurisdiction">>, <<"currency">>, <<"workpaper_status">> |
              [Label || {Label, _Key} <- Fields]],
    Rows = [[Region, Currency, <<"DRAFT_REVIEW_REQUIRED">> |
             [value(maps:get(Key, E, null)) || {_Label, Key} <- Fields]] || E <- Entries],
    iolist_to_binary([csv_row(Header) | [csv_row(Row) || Row <- Rows]]).

%% Country-oriented reconciliation columns. The tax treatment and calculation
%% fields are deliberately unfilled until approved by an accountant.
fields(<<"US">>) ->
    [{<<"event_id">>, <<"id">>}, {<<"date_acquired_unix">>, <<"acquired_at">>},
     {<<"date_disposed_unix">>, <<"occurred_at">>},
     {<<"description_asset">>, <<"asset">>},
     {<<"quantity_atomic">>, <<"amount_atomic">>},
     {<<"gross_proceeds_usd_minor">>, <<"fiat_minor_units">>},
     {<<"cost_basis_usd_minor">>, <<"cost_base_minor_units">>},
     {<<"gain_loss_usd_minor">>, <<"cgt_raw_gain_loss_minor_units">>},
     {<<"cost_basis_reference">>, <<"cost_basis_reference">>} | common()];
fields(<<"IN">>) ->
    [{<<"event_id">>, <<"id">>},
     {<<"date_acquired_unix">>, <<"acquired_at">>},
     {<<"date_transferred_unix">>, <<"occurred_at">>},
     {<<"asset">>, <<"asset">>},
     {<<"consideration_inr_minor">>, <<"fiat_minor_units">>},
     {<<"acquisition_cost_inr_minor">>, <<"cost_base_minor_units">>},
     {<<"transaction_reference">>, <<"source_ref">>} | common()];
fields(<<"AE">>) ->
    [{<<"event_id">>, <<"id">>}, {<<"transaction_date_unix">>, <<"occurred_at">>},
     {<<"gross_amount_aed_minor">>, <<"fiat_minor_units">>},
     {<<"asset">>, <<"asset">>}, {<<"direction">>, <<"direction">>} | common()];
fields(<<"SG">>) ->
    [{<<"event_id">>, <<"id">>}, {<<"transaction_date_unix">>, <<"occurred_at">>},
     {<<"gross_amount_sgd_minor">>, <<"fiat_minor_units">>},
     {<<"asset">>, <<"asset">>}, {<<"direction">>, <<"direction">>} | common()];
fields(_) ->
    [{<<"event_id">>, <<"id">>}, {<<"occurred_at_unix">>, <<"occurred_at">>},
     {<<"acquired_at_unix">>, <<"acquired_at">>},
     {<<"asset">>, <<"asset">>}, {<<"amount_atomic">>, <<"amount_atomic">>},
     {<<"fiat_minor_units">>, <<"fiat_minor_units">>},
     {<<"cost_base_minor_units">>, <<"cost_base_minor_units">>},
     {<<"raw_gain_loss_minor_units">>, <<"cgt_raw_gain_loss_minor_units">>} | common()].

common() ->
    [{<<"classification">>, <<"category">>},
     {<<"source">>, <<"source">>}, {<<"source_ref">>, <<"source_ref">>},
     {<<"reviewer">>, <<"reviewer">>},
     {<<"price_evidence_sha256">>, <<"price_body_sha256">>},
     {<<"source_evidence_sha256">>, <<"snapshot_sha256">>},
     {<<"review_reasons">>, <<"review_reasons">>}].

value(null) -> <<>>;
value(V) when is_list(V) -> iolist_to_binary(lists:join(<<";">>, V));
value(V) -> V.

csv_row(Cells) -> [lists:join(<<",">>, [csv_cell(C) || C <- Cells]), <<"\r\n">>].
csv_cell(V) when is_integer(V) -> integer_to_binary(V);
csv_cell(V) when is_binary(V) ->
    Safe = case needs_csv_prefix(V) of
        true -> <<"'", V/binary>>;
        false -> V
    end,
    Esc = binary:replace(Safe, <<"\"">>, <<"\"\"">>, [global]),
    <<"\"", Esc/binary, "\"">>;
csv_cell(_) -> <<"\"\"">>.

%% Excel and similar software can interpret even whitespace-prefixed strings
%% as formulas after CSV import. Never export an executable user-supplied cell.
needs_csv_prefix(<<C, Rest/binary>>)
        when C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n ->
    needs_csv_prefix(Rest);
needs_csv_prefix(<<C, _/binary>>)
        when C =:= $=; C =:= $+; C =:= $-; C =:= $@ -> true;
needs_csv_prefix(_) -> false.
