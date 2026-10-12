%%% Jurisdiction-aware transaction valuation + accountant review workpapers.
%%% NOT a determination of tax residence, taxable income, tax liability or filing.
-module(damage_tax_report).
-export([
    build/5, build/6, build/7,
    fy_bounds/2,
    required_prices/2,
    required_prices/3,
    required_prices/5,
    to_csv/1,
    export_private/2
]).

-spec fy_bounds(integer(), integer()) -> {integer(), integer()}.
fy_bounds(EndYear, StdUtcOffsetMinutes) when
    is_integer(EndYear),
    EndYear > 1970,
    is_integer(StdUtcOffsetMinutes),
    StdUtcOffsetMinutes >= 0,
    StdUtcOffsetMinutes =< 840
->
    Start = unix({{EndYear - 1, 7, 1}, {0, 0, 0}}) - StdUtcOffsetMinutes * 60,
    End = unix({{EndYear, 7, 1}, {0, 0, 0}}) - StdUtcOffsetMinutes * 60,
    {Start, End}.

required_prices(Events, EndYear) ->
    required_prices(Events, EndYear, 600).

required_prices(Events, EndYear, OffsetMinutes) ->
    {Start, End} = fy_bounds(EndYear, OffsetMinutes),
    lists:usort([
        damage_tax_prices:quote_key(E)
     || E <- Events,
        in_range(E, Start, End),
        maps:get(<<"kind">>, E, <<>>) =/= <<"allocation">>
    ]).

%%% Jurisdiction-aware price keys, which contain fiat currency for non-AUD
%%% profiles. Legacy Australian keys retain their two-element shape.
required_prices(Events, Region, EndYear, OffsetMinutes, StartMonth) ->
    case damage_tax_regions:bounds(Region, EndYear, OffsetMinutes, StartMonth) of
        {ok, {Start, End}} ->
            Currency = damage_tax_regions:currency(Region),
            {ok,
                lists:usort([
                    damage_tax_prices:quote_key(E, Currency)
                 || E <- Events,
                    in_range(E, Start, End),
                    maps:get(<<"kind">>, E, <<>>) =/= <<"allocation">>
                ])};
        Error ->
            Error
    end.

%%% Quotes: #{ {<<"BTC">>, HourUtc} => PriceQuote } or #{ EventId => PriceQuote }.
%%% Decisions: #{ EventId => #{<<"category">> => <<"ordinary_income">>,
%%%                             <<"reviewer">> => <<"auditor-id">>,
%%%                             <<"approved">> => true }}.
%%% Classifications are independently reviewed; directions never imply deductibility.
-spec build(integer(), integer(), [map()], map(), map()) -> {ok, map()} | {error, term()}.
build(FYEndYear, OffsetMinutes, AllEvents, Quotes, Decisions) ->
    build(<<"AU">>, FYEndYear, OffsetMinutes, AllEvents, Quotes, Decisions).

build(Region, FYEndYear, OffsetMinutes, AllEvents, Quotes, Decisions) ->
    case damage_tax_regions:lookup(Region) of
        {ok, Profile} ->
            build(
                Region,
                FYEndYear,
                OffsetMinutes,
                maps:get(<<"start_month">>, Profile),
                AllEvents,
                Quotes,
                Decisions
            );
        Error ->
            Error
    end.

%% A report is bound to its period, fiat currency and jurisdiction in the
%% content-addressed manifest. Never reuse AUD figures as a foreign fiat value.
-spec build(binary(), integer(), integer(), integer(), [map()], map(), map()) ->
    {ok, map()} | {error, term()}.
build(Region, FYEndYear, OffsetMinutes, StartMonth, AllEvents, Quotes, Decisions) when
    is_list(AllEvents), is_map(Quotes), is_map(Decisions)
->
    case damage_tax_regions:bounds(Region, FYEndYear, OffsetMinutes, StartMonth) of
        {ok, {Start, End}} ->
            Currency = damage_tax_regions:currency(Region),
            {ok, Profile} = damage_tax_regions:lookup(Region),
            Entries0 = [E || E <- AllEvents, in_range(E, Start, End)],
            Events = lists:sort(fun(A, B) -> sort_key(A) =< sort_key(B) end, Entries0),
            case unique_valid_events(Events) of
                ok ->
                    Entries = [evaluate(E, Quotes, Decisions, Currency) || E <- Events],
                    Review = [
                        #{
                            <<"event_id">> => maps:get(<<"id">>, E),
                            <<"reasons">> => maps:get(<<"review_reasons">>, E)
                        }
                     || E <- Entries, maps:get(<<"review_reasons">>, E) =/= []
                    ],
                    Leaves = [damage_tax_canonical:commitment(E) || E <- Entries],
                    EvidenceSet = lists:usort(
                        lists:flatten([
                            [
                                V
                             || V <- [
                                    maps:get(<<"snapshot_sha256">>, E, <<>>),
                                    maps:get(<<"price_archive_sha256">>, E, <<>>)
                                ],
                                V =/= <<>>
                            ]
                         || E <- Entries
                        ])
                    ),
                    Manifest = #{
                        <<"schema_version">> => 2,
                        <<"jurisdiction">> => Region,
                        <<"currency">> => Currency,
                        <<"minor_digits">> => damage_tax_regions:minor_digits(Region),
                        <<"tax_year_end">> => FYEndYear,
                        <<"period_start_month">> => StartMonth,
                        <<"period_start_day">> => damage_tax_regions:start_day(Region, StartMonth),
                        <<"start_utc">> => Start,
                        <<"end_utc_exclusive">> => End,
                        <<"standard_utc_offset_minutes">> => OffsetMinutes,
                        <<"ruleset">> => <<"damage_tax_workpaper_v2">>,
                        <<"workpaper">> => maps:get(<<"workpaper">>, Profile),
                        <<"accountant_review_required">> => true,
                        <<"entries">> => Entries,
                        <<"entry_merkle_root_sha256">> => merkle(Leaves),
                        <<"evidence_hashes">> => EvidenceSet,
                        <<"evidence_set_sha256">> => damage_tax_canonical:commitment(EvidenceSet),
                        <<"summary">> => summarize(Entries, Currency),
                        <<"review_required">> => Review
                    },
                    {ok, #{
                        <<"manifest">> => Manifest,
                        <<"manifest_sha256">> => damage_tax_canonical:commitment(Manifest),
                        <<"evidence_set_sha256">> => maps:get(<<"evidence_set_sha256">>, Manifest),
                        <<"attestable">> => Review =:= [] andalso Entries =/= [],
                        <<"generated_at">> => erlang:system_time(second)
                    }};
                Error ->
                    Error
            end;
        Error ->
            Error
    end;
build(_, _, _, _, _, _, _) ->
    {error, invalid_tax_report_parameters}.

unique_valid_events(Events) ->
    case lists:usort([maps:get(<<"tenant">>, E, undefined) || E <- Events]) of
        [] -> ok;
        [T] when is_binary(T), byte_size(T) > 0 -> unique_valid_events(Events, #{});
        _ -> {error, mixed_tax_tenants}
    end.
unique_valid_events([], _) ->
    ok;
unique_valid_events([E | Rest], Seen) ->
    case damage_tax_event:validate(E) of
        ok ->
            Id = maps:get(<<"id">>, E),
            case maps:is_key(Id, Seen) of
                true -> {error, {duplicate_event_in_report, Id}};
                false -> unique_valid_events(Rest, maps:put(Id, true, Seen))
            end;
        Error ->
            Error
    end.

evaluate(Event, Quotes, Decisions, Currency) ->
    Id = maps:get(<<"id">>, Event),
    Decision = maps:get(Id, Decisions, #{}),
    Category = maps:get(
        <<"category">>,
        Decision,
        maps:get(<<"default_classification">>, Event, <<"review">>)
    ),
    Allocation = maps:get(<<"kind">>, Event, undefined) =:= <<"allocation">>,
    Quote =
        case Allocation of
            true -> undefined;
            false -> choose_quote(Event, Quotes, Currency)
        end,
    Valued =
        case Quote of
            undefined -> {error, no_quote};
            Q -> damage_tax_prices:fiat_minor(Event, Q, Currency)
        end,
    Value =
        case Valued of
            {ok, V} -> V;
            _ -> null
        end,
    QuoteBody =
        case Quote of
            undefined -> <<>>;
            Q0 -> maps:get(<<"body_sha256">>, Q0, <<>>)
        end,
    QuoteArchived =
        case Quote of
            undefined -> <<>>;
            Q1 -> maps:get(<<"archive_sha256">>, Q1, <<>>)
        end,
    Reasons0 =
        case {Allocation, Valued} of
            {true, _} -> [];
            {false, {ok, _}} -> [];
            {false, _} -> [<<"missing_or_invalid_historical_fiat_price">>]
        end,
    Reasons1 =
        case {Quote, Allocation} of
            {undefined, _} ->
                Reasons0;
            {_, false} when QuoteBody =/= QuoteArchived ->
                [<<"price_http_evidence_not_archived">> | Reasons0];
            _ ->
                Reasons0
        end,
    Reasons2 =
        case Quote of
            undefined ->
                Reasons1;
            Q2 ->
                case
                    {
                        maps:get(<<"review_required">>, Q2, true),
                        maps:get(<<"coarse_price_approved">>, Decision, false)
                    }
                of
                    {true, true} -> Reasons1;
                    {true, _} -> [<<"coarse_price_requires_approval">> | Reasons1];
                    {false, _} -> Reasons1
                end
        end,
    Snapshot = maps:get(<<"snapshot_sha256">>, Event, <<>>),
    Reasons3 =
        case byte_size(Snapshot) of
            64 -> Reasons2;
            _ -> [<<"missing_original_source_snapshot">> | Reasons2]
        end,
    Reasons4 = classification_reasons(Category, Decision, Allocation, Reasons3, Currency),
    Direction = maps:get(<<"direction">>, Event),
    Reasons5 =
        case {Category, Direction} of
            {<<"ordinary_income">>, <<"out">>} ->
                [<<"income_direction_conflict_requires_adjustment">> | Reasons4];
            {<<"business_expense">>, <<"in">>} ->
                [<<"expense_direction_conflict_requires_adjustment">> | Reasons4];
            _ ->
                Reasons4
        end,
    CostBase = basis_minor(Decision, Currency),
    CGTMinor =
        case {Category, Value, CostBase} of
            {<<"cgt_disposal">>, V0, Cost} when is_integer(V0), is_integer(Cost), Cost >= 0 ->
                V0 - Cost;
            _ ->
                null
        end,
    #{
        <<"id">> => Id,
        <<"source">> => maps:get(<<"source">>, Event),
        <<"source_ref">> => maps:get(<<"source_ref">>, Event),
        <<"kind">> => maps:get(<<"kind">>, Event),
        <<"occurred_at">> => maps:get(<<"occurred_at">>, Event),
        <<"direction">> => maps:get(<<"direction">>, Event),
        <<"asset">> => maps:get(<<"asset">>, Event),
        <<"amount_atomic">> => maps:get(<<"amount_atomic">>, Event),
        <<"scale">> => maps:get(<<"scale">>, Event),
        <<"category">> => Category,
        <<"fiat_currency">> => Currency,
        <<"fiat_minor_units">> => Value,
        <<"cgt_raw_gain_loss_minor_units">> => CGTMinor,
        <<"cost_base_minor_units">> => CostBase,
        <<"aud_cents">> =>
            case Currency of
                <<"AUD">> -> Value;
                _ -> null
            end,
        <<"cgt_raw_gain_loss_cents">> =>
            case Currency of
                <<"AUD">> -> CGTMinor;
                _ -> null
            end,
        <<"cost_base_cents">> =>
            case Currency of
                <<"AUD">> -> CostBase;
                _ -> null
            end,
        <<"acquired_at">> => maps:get(<<"acquired_at">>, Decision, null),
        <<"cost_basis_reference">> => maps:get(<<"cost_basis_reference">>, Decision, <<>>),
        <<"reviewer">> => maps:get(<<"reviewer">>, Decision, <<>>),
        <<"classification_approved">> => maps:get(<<"approved">>, Decision, false),
        <<"price_provider">> => quote_field(Quote, <<"provider">>),
        <<"price_method">> => quote_field(Quote, <<"method">>),
        <<"price_request_url">> => quote_field(Quote, <<"request_url">>),
        <<"price_observed_at">> => quote_field(Quote, <<"observed_at">>),
        <<"price_precision_seconds">> => quote_field(Quote, <<"precision_seconds">>),
        <<"price_conversion_type">> => quote_field(Quote, <<"conversion_type">>),
        <<"price_at">> => quote_field(Quote, <<"at">>),
        <<"price_micro_fiat">> => quote_field(Quote, <<"price_micro_fiat">>),
        <<"price_micro_aud">> =>
            case Currency of
                <<"AUD">> -> quote_field(Quote, <<"price_micro_aud">>);
                _ -> null
            end,
        <<"price_body_sha256">> => QuoteBody,
        <<"price_archive_sha256">> => QuoteArchived,
        <<"snapshot_sha256">> => Snapshot,
        <<"source_sha256">> => maps:get(<<"source_sha256">>, Event),
        <<"review_reasons">> => lists:usort(Reasons5)
    }.

basis_minor(Decision, <<"AUD">>) ->
    maps:get(
        <<"cost_base_minor_units">>,
        Decision,
        maps:get(<<"cost_base_cents">>, Decision, null)
    );
basis_minor(Decision, _) ->
    maps:get(<<"cost_base_minor_units">>, Decision, null).

classification_reasons(<<"non_tax_event">>, _Decision, true, R, _Currency) ->
    R;
classification_reasons(_Category, _Decision, true, R, _Currency) ->
    [<<"nwc_allocation_is_not_independent_crypto_payment">> | R];
classification_reasons(<<"review">>, _Decision, false, R, _Currency) ->
    [<<"unclassified_tax_treatment">> | R];
classification_reasons(Category, Decision, false, R, Currency) ->
    Valid = lists:member(Category, [
        <<"ordinary_income">>,
        <<"business_expense">>,
        <<"cgt_disposal">>,
        <<"cost_basis_acquisition">>,
        <<"internal_transfer">>,
        <<"non_tax_event">>
    ]),
    R1 =
        case Valid of
            true -> R;
            false -> [<<"unknown_classification">> | R]
        end,
    Reviewed =
        maps:get(<<"approved">>, Decision, false) =:= true andalso
            nonempty(maps:get(<<"reviewer">>, Decision, <<>>)),
    R2 =
        case Reviewed of
            true -> R1;
            false -> [<<"classification_requires_reviewer_approval">> | R1]
        end,
    case Category of
        <<"cgt_disposal">> ->
            Cost = basis_minor(Decision, Currency),
            Acquired = maps:get(<<"acquired_at">>, Decision, undefined),
            Ref = maps:get(<<"cost_basis_reference">>, Decision, <<>>),
            case
                is_integer(Cost) andalso Cost >= 0 andalso
                    is_integer(Acquired) andalso Acquired > 0 andalso nonempty(Ref)
            of
                true -> R2;
                false -> [<<"cgt_lot_and_cost_base_review_required">> | R2]
            end;
        _ ->
            R2
    end.

choose_quote(Event, Quotes, Currency) ->
    Id = maps:get(<<"id">>, Event),
    maps:get(Id, Quotes, maps:get(damage_tax_prices:quote_key(Event, Currency), Quotes, undefined)).

quote_field(undefined, _) -> null;
quote_field(Quote, Key) -> maps:get(Key, Quote, null).

summarize(Entries, Currency) ->
    Base = #{
        <<"total_events">> => 0,
        <<"ordinary_income_minor">> => 0,
        <<"expense_candidates_minor">> => 0,
        <<"cgt_raw_gains_minor">> => 0,
        <<"cgt_raw_losses_minor">> => 0
    },
    Total = lists:foldl(
        fun(E, Acc) ->
            Category = maps:get(<<"category">>, E),
            Value = maps:get(<<"fiat_minor_units">>, E),
            CGT = maps:get(<<"cgt_raw_gain_loss_minor_units">>, E),
            A1 = Acc#{<<"total_events">> => maps:get(<<"total_events">>, Acc) + 1},
            A2 =
                case {Category, Value} of
                    {<<"ordinary_income">>, V} when is_integer(V) ->
                        sum(A1, <<"ordinary_income_minor">>, V);
                    {<<"business_expense">>, V} when is_integer(V) ->
                        sum(A1, <<"expense_candidates_minor">>, V);
                    _ ->
                        A1
                end,
            case CGT of
                C when is_integer(C), C >= 0 -> sum(A2, <<"cgt_raw_gains_minor">>, C);
                C when is_integer(C), C < 0 -> sum(A2, <<"cgt_raw_losses_minor">>, -C);
                _ -> A2
            end
        end,
        Base,
        Entries
    ),
    case Currency of
        <<"AUD">> ->
            Total#{
                <<"ordinary_income_cents">> => maps:get(<<"ordinary_income_minor">>, Total),
                <<"expense_candidates_cents">> => maps:get(<<"expense_candidates_minor">>, Total),
                <<"cgt_raw_gains_cents">> => maps:get(<<"cgt_raw_gains_minor">>, Total),
                <<"cgt_raw_losses_cents">> => maps:get(<<"cgt_raw_losses_minor">>, Total)
            };
        _ ->
            Total
    end.

sum(M, K, V) -> maps:put(K, maps:get(K, M, 0) + V, M).

merkle([]) ->
    damage_tax_canonical:sha256_hex(<<"damage-tax-merkle-empty-v1">>);
merkle(Leaves) ->
    merkle_reduce([
        damage_tax_canonical:sha256_hex(
            [<<"damage-tax-merkle-leaf-v1:">>, Leaf]
        )
     || Leaf <- Leaves
    ]).
merkle_reduce([Root]) -> Root;
merkle_reduce(Leaves) -> merkle_reduce(pair(Leaves, [])).

pair([], Acc) -> lists:reverse(Acc);
pair([A], Acc) -> pair([], [node_hash(A, A) | Acc]);
pair([A, B | T], Acc) -> pair(T, [node_hash(A, B) | Acc]).
node_hash(A, B) ->
    damage_tax_canonical:sha256_hex([
        <<"damage-tax-merkle-node-v1:">>, A, <<":">>, B
    ]).

in_range(E, Start, End) ->
    Ts = maps:get(<<"occurred_at">>, E, 0),
    Ts >= Start andalso Ts < End.
sort_key(E) -> {maps:get(<<"occurred_at">>, E), maps:get(<<"id">>, E)}.
nonempty(B) -> is_binary(B) andalso byte_size(B) > 0.
unix(DT) ->
    calendar:datetime_to_gregorian_seconds(DT) -
        calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).

%%% Spreadsheet-safe CSV; only report entries, never raw secret-bearing RPCs.
-spec to_csv(map()) -> binary().
to_csv(#{<<"manifest">> := #{<<"entries">> := Entries} = Manifest}) ->
    Currency = maps:get(<<"currency">>, Manifest, <<"AUD">>),
    Region = maps:get(<<"jurisdiction">>, Manifest, <<"AU">>),
    Keys = [
        <<"id">>,
        <<"occurred_at">>,
        <<"source">>,
        <<"source_ref">>,
        <<"kind">>,
        <<"direction">>,
        <<"asset">>,
        <<"amount_atomic">>,
        <<"scale">>,
        <<"category">>,
        <<"fiat_minor_units">>,
        <<"cgt_raw_gain_loss_minor_units">>,
        <<"cost_base_minor_units">>,
        <<"acquired_at">>,
        <<"cost_basis_reference">>,
        <<"reviewer">>,
        <<"price_provider">>,
        <<"price_body_sha256">>,
        <<"review_reasons">>
    ],
    Header = [<<"jurisdiction">>, <<"fiat_currency">> | [csv_header(K) || K <- Keys]],
    Rows = [
        [Region, Currency | [csv_value(K, maps:get(K, E, null)) || K <- Keys]]
     || E <- Entries
    ],
    iolist_to_binary([csv_row(Header) | [csv_row(Row) || Row <- Rows]]).

csv_header(<<"id">>) -> <<"event_id">>;
csv_header(Key) -> Key.

csv_value(<<"review_reasons">>, Values) when is_list(Values) ->
    iolist_to_binary(lists:join(<<";">>, Values));
csv_value(_, Value) ->
    Value.

csv_row(Cells) -> [lists:join(<<",">>, [csv_cell(C) || C <- Cells]), <<"\r\n">>].
csv_cell(null) ->
    <<"\"\"">>;
csv_cell(V) when is_integer(V) -> integer_to_binary(V);
csv_cell(V) when is_binary(V) ->
    %% Prevent Excel/Calc formula execution from attacker-controlled text.
    Safe =
        case needs_csv_prefix(V) of
            true -> <<"'", V/binary>>;
            false -> V
        end,
    Escaped = binary:replace(Safe, <<"\"">>, <<"\"\"">>, [global]),
    <<"\"", Escaped/binary, "\"">>;
csv_cell(_) ->
    <<"\"\"">>.

%% Excel and similar software can interpret even whitespace-prefixed strings
%% as formulas after CSV import. Never export an executable user-supplied cell.
needs_csv_prefix(<<C, Rest/binary>>) when
    C =:= $\s; C =:= $\t; C =:= $\r; C =:= $\n
->
    needs_csv_prefix(Rest);
needs_csv_prefix(<<C, _/binary>>) when
    C =:= $=; C =:= $+; C =:= $-; C =:= $@
->
    true;
needs_csv_prefix(_) ->
    false.

%%% Private export; don't put CSV, manifest or evidence into public IPFS.
-spec export_private(map(), string()) -> ok | {error, term()}.
export_private(Report, Directory) ->
    Manifest = maps:get(<<"manifest">>, Report),
    Hash = maps:get(<<"manifest_sha256">>, Report),
    JsonPath = filename:join(Directory, "tax-manifest.json"),
    CsvPath = filename:join(Directory, "tax-transactions.csv"),
    HashPath = filename:join(Directory, "tax-manifest.sha256"),
    case filelib:ensure_dir(JsonPath) of
        ok ->
            case file:change_mode(Directory, 8#700) of
                ok ->
                    write_private([
                        {JsonPath, damage_tax_canonical:encode(Manifest)},
                        {CsvPath, to_csv(Report)},
                        {HashPath, <<Hash/binary, "  tax-manifest.json\n">>}
                    ]);
                Error ->
                    {error, {report_directory_permissions, Error}}
            end;
        Error ->
            Error
    end.

write_private([]) ->
    ok;
write_private([{Path, Data} | Rest]) ->
    case file:open(Path, [write, binary]) of
        {ok, Io} ->
            Chmod = file:change_mode(Path, 8#600),
            W =
                case Chmod of
                    ok -> file:write(Io, Data);
                    ModeError -> ModeError
                end,
            R =
                case W of
                    ok -> file:sync(Io);
                    WriteError -> WriteError
                end,
            _ = file:close(Io),
            case R of
                ok -> write_private(Rest);
                SaveError -> {error, {report_write_failed, Path, SaveError}}
            end;
        OpenError ->
            {error, {report_open_failed, Path, OpenError}}
    end.
