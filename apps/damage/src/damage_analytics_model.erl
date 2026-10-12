%%%-------------------------------------------------------------------
%%% Normalisation helpers for DamageBDD analytics.
%%%
%%% Keep chain-shape compatibility here so the cache/indexer, dashboard and
%%% ECAI projection all consume one canonical run model.
%%%-------------------------------------------------------------------
-module(damage_analytics_model).

-author("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").

-export([
    normalize_local_run/1,
    normalize_chain_spend/3,
    enrich_meta/2,
    merge_run/2,
    public_run/1,
    plausible_run_transaction/2,
    tx_hash/1,
    time_ms/1,
    status/1,
    failure_signature/1,
    is_cid/1
]).

-define(MAX_CANDIDATES, 22).
-define(MAX_RESULT_SUMMARY, 240).

%% ===================================================================
%% Local run records
%% ===================================================================

normalize_local_run(Run0) when is_map(Run0) ->
    ReportCid = text(get_any([report_hash, report_cid, <<"report_hash">>, <<"report_cid">>], Run0, <<>>)),
    FeatureCid = text(get_any([feature_hash, feature_cid, <<"feature_hash">>, <<"feature_cid">>], Run0, <<>>)),
    case is_cid(ReportCid) of
        false -> {error, missing_report_cid};
        true ->
            StartMs = time_ms(get_any([start_time, start_time_hires, <<"start_time">>, <<"start_time_hires">>], Run0, 0)),
            CompletedMs = time_ms(get_any([completed_at, end_time, end_time_hires,
                                           <<"completed_at">>, <<"end_time">>, <<"end_time_hires">>], Run0, 0)),
            Status = status(Run0),
            Result = result_summary(get_any([result, <<"result">>], Run0, <<>>)),
            Run1 = #{
                report_cid => ReportCid,
                feature_cid => FeatureCid,
                run_id => text(get_any([run_id, <<"run_id">>], Run0, <<>>)),
                account => ae_account(get_any([public_key, caller_id, <<"public_key">>, <<"caller_id">>], Run0, <<>>)),
                node => ae_account(get_any([node_public_key, <<"node_public_key">>], Run0, <<>>)),
                tx_hash => text(get_any([tx_hash, <<"tx_hash">>], Run0, <<>>)),
                status => Status,
                result_summary => Result,
                feature_title => text(get_any([feature_title, <<"feature_title">>], Run0, <<>>)),
                tags => normalize_tags(get_any([tags, <<"tags">>], Run0, [])),
                created_ms => first_positive([StartMs, CompletedMs]),
                completed_ms => first_positive([CompletedMs, StartMs]),
                duration_ms => duration_ms(get_any([execution_time, execution_time_hires,
                                                     <<"execution_time">>, <<"execution_time_hires">>], Run0, 0)),
                schedule_id => get_any([schedule_id, <<"schedule_id">>], Run0, false),
                cost_raw => number(get_any([cost, <<"cost">>], Run0, 0)),
                spend_raw => number(get_any([spend, <<"spend">>], Run0, 0)),
                release => get_any([release, <<"release">>], Run0, #{}),
                settlement_status => settlement_status(Run0),
                evidence => #{local => true, report_meta => true, chain_confirmed => false},
                source => local_run
            },
            {ok, finalize(Run1)}
    end;
normalize_local_run(_) ->
    {error, invalid_run}.

%% ===================================================================
%% AEMDW transaction normalisation
%% ===================================================================

normalize_chain_spend(Root, TokenContract0, TrustedContractScope)
    when is_map(Root), is_boolean(TrustedContractScope) ->
    TokenContract = text(TokenContract0),
    Candidates = tx_candidates(Root),
    Payment = payment_identity(Candidates),
    case decoded_spend(Candidates, Root, TokenContract, TrustedContractScope, Payment) of
        {ok, Run} -> {ok, finalize(Run)};
        not_found ->
            case calldata_spend(Candidates, Root, TokenContract, TrustedContractScope, Payment) of
                {ok, Run2} -> {ok, finalize(Run2)};
                not_found -> not_run
            end
    end;
normalize_chain_spend(_, _, _) ->
    not_run.

decoded_spend([Candidate | Rest], Root, TokenContract, Trusted, Payment) ->
    Args = args_of(Candidate),
    case decoded_spend_candidate(Candidate, Args, Root, TokenContract, Trusted, Payment) of
        {ok, _} = Ok -> Ok;
        not_found -> decoded_spend(Rest, Root, TokenContract, Trusted, Payment)
    end;
decoded_spend([], _Root, _TokenContract, _Trusted, _Payment) ->
    not_found.

decoded_spend_candidate(Candidate, Args, Root, TokenContract, Trusted, Payment) ->
    case Args of
        [Node0, Amount0, Feature0, Report0 | _] ->
            Feature = text(Feature0),
            Report = text(Report0),
            ObservedContract = observed_contract(Candidate, tx_candidates(Root)),
            Method = method_name(Candidate),
            ContractOk = (ObservedContract =:= <<>>) orelse (ObservedContract =:= TokenContract),
            ScopeOk = Method =:= <<"spend">> orelse Trusted orelse ObservedContract =:= TokenContract,
            Node = ae_account(Node0),
            case ContractOk andalso ScopeOk andalso is_cid(Feature) andalso is_cid(Report) andalso Node =/= <<>> of
                true ->
                    Candidates = tx_candidates(Root),
                    PayingFor = maps:get(paying_for, Payment, false),
                    Account = spend_caller(Candidate, Candidates, TokenContract, PayingFor),
                    {ok, #{
                        report_cid => Report,
                        feature_cid => Feature,
                        account => Account,
                        node => Node,
                        payer => maps:get(payer, Payment, <<>>),
                        paying_for => PayingFor,
                        tx_hash => tx_hash(Root),
                        amount_raw => text(Amount0),
                        created_ms => transaction_timestamp(Root),
                        completed_ms => transaction_timestamp(Root),
                        duration_ms => 0,
                        status => unknown,
                        result_summary => <<>>,
                        feature_title => <<>>,
                        tags => [],
                        settlement_status => chain_confirmed,
                        evidence => #{local => false, report_meta => false, chain_confirmed => true,
                                      spend => decoded_arguments},
                        source => chain
                    }};
                false -> not_found
            end;
        _ -> not_found
    end.

calldata_spend([Candidate | Rest], Root, TokenContract, Trusted, Payment) ->
    Method = method_name(Candidate),
    ObservedContract = observed_contract(Candidate, tx_candidates(Root)),
    MethodOk = Method =:= <<>> orelse Method =:= <<"spend">>,
    ContractOk = (ObservedContract =:= TokenContract) orelse (ObservedContract =:= <<>> andalso Trusted),
    case MethodOk andalso ContractOk of
        true ->
            case cids_from_call_data(get_any([call_data, <<"call_data">>], Candidate, <<>>)) of
                [Feature, Report] ->
                    Candidates = tx_candidates(Root),
                    PayingFor = maps:get(paying_for, Payment, false),
                    {ok, #{
                        report_cid => Report,
                        feature_cid => Feature,
                        account => spend_caller(Candidate, Candidates, TokenContract, PayingFor),
                        node => <<>>,
                        payer => maps:get(payer, Payment, <<>>),
                        paying_for => PayingFor,
                        tx_hash => tx_hash(Root),
                        amount_raw => <<>>,
                        created_ms => transaction_timestamp(Root),
                        completed_ms => transaction_timestamp(Root),
                        duration_ms => 0,
                        status => unknown,
                        result_summary => <<>>,
                        feature_title => <<>>,
                        tags => [],
                        settlement_status => chain_confirmed,
                        evidence => #{local => false, report_meta => false, chain_confirmed => true,
                                      spend => token_calldata},
                        source => chain
                    }};
                _ -> calldata_spend(Rest, Root, TokenContract, Trusted, Payment)
            end;
        false -> calldata_spend(Rest, Root, TokenContract, Trusted, Payment)
    end;
calldata_spend([], _Root, _TokenContract, _Trusted, _Payment) ->
    not_found.

plausible_run_transaction(Root, TokenContract0) when is_map(Root) ->
    TokenContract = text(TokenContract0),
    Candidates = tx_candidates(Root),
    HasDecoded = lists:any(fun(Candidate) ->
        Args = args_of(Candidate),
        case Args of
            [_Node, _Amount, Feature, Report | _] ->
                is_cid(text(Feature)) andalso is_cid(text(Report)) andalso
                    begin
                        C = contract_of(Candidate),
                        C =:= <<>> orelse C =:= TokenContract
                    end;
            _ -> false
        end
    end, Candidates),
    HasSpend = lists:any(fun(C) ->
        method_name(C) =:= <<"spend">> andalso
            (contract_of(C) =:= <<>> orelse contract_of(C) =:= TokenContract)
    end, Candidates),
    Wrapped = lists:any(fun is_wrapped/1, Candidates),
    TokenMention = lists:any(fun(C) -> contract_of(C) =:= TokenContract end, Candidates),
    Kinds = [lower(text(get_any([type, tx_type, kind, <<"type">>, <<"tx_type">>, <<"kind">>], C, <<>>)))
             || C <- Candidates],
    InterestingKind = lists:any(fun(K) ->
        regex(K, <<"(?:contract.?call|paying.?for|ga.?meta|internalcontractcall)">>)
    end, Kinds),
    HasDecoded orelse HasSpend orelse Wrapped orelse TokenMention orelse InterestingKind orelse
        lists:all(fun(K) -> K =:= <<>> end, Kinds);
plausible_run_transaction(_, _) -> false.

%% ===================================================================
%% run.meta enrichment and merging
%% ===================================================================

enrich_meta(Run0, Meta) when is_map(Run0), is_map(Meta) ->
    MetaStatus = status(Meta),
    MetaAccount = ae_account(get_any([public_key, <<"public_key">>], Meta, <<>>)),
    MetaNode = ae_account(get_any([node_public_key, <<"node_public_key">>], Meta, <<>>)),
    ChainAccount = ae_account(maps:get(account, Run0, <<>>)),
    Created = first_positive([
        time_ms(get_any([start_time_hires, <<"start_time_hires">>], Meta, 0)),
        time_ms(get_any([completed_at, <<"completed_at">>], Meta, 0)),
        maps:get(created_ms, Run0, 0)
    ]),
    Completed = first_positive([
        time_ms(get_any([completed_at, <<"completed_at">>], Meta, 0)),
        time_ms(get_any([end_time_hires, <<"end_time_hires">>], Meta, 0)),
        maps:get(completed_ms, Run0, 0),
        Created
    ]),
    Evidence0 = maps:get(evidence, Run0, #{}),
    Run1 = Run0#{
        run_id => prefer_text(text(get_any([run_id, <<"run_id">>], Meta, <<>>)), maps:get(run_id, Run0, <<>>)),
        feature_title => prefer_text(text(get_any([feature_title, <<"feature_title">>], Meta, <<>>)), maps:get(feature_title, Run0, <<>>)),
        tags => prefer_list(normalize_tags(get_any([tags, <<"tags">>], Meta, [])), maps:get(tags, Run0, [])),
        status => prefer_status(MetaStatus, maps:get(status, Run0, unknown)),
        result_summary => prefer_text(result_summary(get_any([result, <<"result">>], Meta, <<>>)), maps:get(result_summary, Run0, <<>>)),
        account => prefer_text(ChainAccount, MetaAccount),
        reported_account => MetaAccount,
        account_mismatch => (ChainAccount =/= <<>> andalso MetaAccount =/= <<>> andalso ChainAccount =/= MetaAccount),
        node => prefer_text(maps:get(node, Run0, <<>>), MetaNode),
        created_ms => Created,
        completed_ms => Completed,
        duration_ms => prefer_number(duration_ms(get_any([execution_time_hires, <<"execution_time_hires">>], Meta, 0)), maps:get(duration_ms, Run0, 0)),
        release => get_any([release, <<"release">>], Meta, maps:get(release, Run0, #{})),
        evidence => maps:merge(Evidence0, #{report_meta => true})
    },
    finalize(Run1);
enrich_meta(Run, _) -> Run.

merge_run(Old, New) when is_map(Old), is_map(New) ->
    Keys = lists:usort(maps:keys(Old) ++ maps:keys(New)),
    Merged0 = lists:foldl(fun(Key, Acc) ->
        OV = maps:get(Key, Old, undefined),
        NV = maps:get(Key, New, undefined),
        maps:put(Key, merge_value(Key, OV, NV), Acc)
    end, #{}, Keys),
    finalize(Merged0);
merge_run(_Old, New) -> finalize(New).

merge_value(evidence, O, N) when is_map(O), is_map(N) -> maps:merge(O, N);
merge_value(ecai, O, N) when is_map(O), is_map(N) -> maps:merge(O, N);
merge_value(status, O, unknown) when O =/= undefined -> O;
merge_value(status, _O, N) -> N;
merge_value(tags, O, N) when is_list(N), N =:= [] -> O;
merge_value(_Key, O, undefined) -> O;
merge_value(_Key, O, <<>>) when O =/= undefined, O =/= <<>> -> O;
merge_value(_Key, O, 0) when is_number(O), O > 0 -> O;
merge_value(_Key, _O, N) -> N.

public_run(Run) when is_map(Run) ->
    Ecai = maps:get(ecai, Run, #{}),
    #{
        run_id => maps:get(run_id, Run, <<>>),
        report_cid => maps:get(report_cid, Run, <<>>),
        feature_cid => maps:get(feature_cid, Run, <<>>),
        feature_title => maps:get(feature_title, Run, <<>>),
        status => atom_bin(maps:get(status, Run, unknown)),
        account => maps:get(account, Run, <<>>),
        node => maps:get(node, Run, <<>>),
        payer => maps:get(payer, Run, <<>>),
        tx_hash => maps:get(tx_hash, Run, <<>>),
        created_ms => maps:get(created_ms, Run, 0),
        completed_ms => maps:get(completed_ms, Run, 0),
        duration_ms => maps:get(duration_ms, Run, 0),
        result_summary => maps:get(result_summary, Run, <<>>),
        failure_signature => maps:get(failure_signature, Run, <<>>),
        settlement_status => atom_bin(maps:get(settlement_status, Run, unknown)),
        chain_confirmed => maps:get(chain_confirmed, maps:get(evidence, Run, #{}), false),
        evidence_loaded => report_evidence_loaded(maps:get(evidence, Run, #{})),
        ecai => maps:with([status, search_indexed, relation_count, curve_feature_count,
                           geometry_status, geometry_fingerprint], Ecai)
    };
public_run(_) -> #{}.

%% ===================================================================
%% Derived identities
%% ===================================================================

failure_signature(Run) when is_map(Run) ->
    case maps:get(status, Run, unknown) of
        failed ->
            Basis = iolist_to_binary([
                maps:get(feature_cid, Run, <<>>), 0,
                lower(maps:get(feature_title, Run, <<>>)), 0,
                lower(maps:get(result_summary, Run, <<>>))
            ]),
            Hex = lower(binary:encode_hex(crypto:hash(sha256, Basis))),
            <<Short:16/binary, _/binary>> = Hex,
            Short;
        _ -> <<>>
    end;
failure_signature(_) -> <<>>.

report_evidence_loaded(Evidence) when is_map(Evidence) ->
    maps:get(report_meta, Evidence, false) orelse maps:get(legacy_report, Evidence, false);
report_evidence_loaded(_) -> false.

finalize(Run0) ->
    Run1 = Run0#{
        report_cid => text(maps:get(report_cid, Run0, <<>>)),
        feature_cid => text(maps:get(feature_cid, Run0, <<>>)),
        account => ae_account(maps:get(account, Run0, <<>>)),
        node => ae_account(maps:get(node, Run0, <<>>)),
        payer => ae_account(maps:get(payer, Run0, <<>>)),
        tx_hash => text(maps:get(tx_hash, Run0, <<>>)),
        status => normalize_status(maps:get(status, Run0, unknown)),
        result_summary => result_summary(maps:get(result_summary, Run0, <<>>)),
        tags => normalize_tags(maps:get(tags, Run0, [])),
        created_ms => integer_value(maps:get(created_ms, Run0, 0)),
        completed_ms => integer_value(maps:get(completed_ms, Run0, maps:get(created_ms, Run0, 0))),
        duration_ms => integer_value(maps:get(duration_ms, Run0, 0))
    },
    Run1#{failure_signature => failure_signature(Run1)}.

%% ===================================================================
%% Shape helpers
%% ===================================================================

tx_hash(Root) when is_map(Root) ->
    first_text([
        get_any([hash, tx_hash, call_tx_hash, <<"hash">>, <<"tx_hash">>, <<"call_tx_hash">>], X, <<>>)
     || X <- tx_candidates(Root)
    ], <<"th_">>);
tx_hash(_) -> <<>>.

tx_candidates(Root) -> tx_candidates([Root], #{}, [], 0).

tx_candidates(_Pending, _Seen, Acc, Count) when Count >= ?MAX_CANDIDATES -> lists:reverse(Acc);
tx_candidates([], _Seen, Acc, _Count) -> lists:reverse(Acc);
tx_candidates([X | Rest], Seen, Acc, Count) when is_map(X) ->
    H = erlang:phash2(X),
    case maps:is_key(H, Seen) of
        true -> tx_candidates(Rest, Seen, Acc, Count);
        false ->
            Nested = [V || K <- [payload, tx, transaction, inner_tx, internal_tx, call_info, call,
                                  <<"payload">>, <<"tx">>, <<"transaction">>, <<"inner_tx">>,
                                  <<"internal_tx">>, <<"call_info">>, <<"call">>],
                           V <- [maps:get(K, X, undefined)], is_map(V)],
            tx_candidates(Rest ++ Nested, Seen#{H => true}, [X | Acc], Count + 1)
    end;
tx_candidates([_ | Rest], Seen, Acc, Count) -> tx_candidates(Rest, Seen, Acc, Count).

args_of(Map) when is_map(Map) ->
    case first_list([maps:get(K, Map, undefined) || K <- [arguments, args, decoded_args,
                                                          <<"arguments">>, <<"args">>, <<"decoded_args">>]]) of
        undefined -> [];
        Values -> [value_of(V) || V <- Values]
    end;
args_of(_) -> [].

value_of(Map) when is_map(Map) -> get_any([value, <<"value">>], Map, Map);
value_of([_Type, Value]) -> Value;
value_of(Value) -> Value.

method_name(Map) ->
    Name0 = text(get_any([function, function_name, func, entrypoint, call_name,
                          <<"function">>, <<"function_name">>, <<"func">>, <<"entrypoint">>,
                          <<"call_name">>], Map, <<>>)),
    case binary:split(Name0, <<".">>, [global]) of
        [] -> <<>>;
        Parts -> lists:last(Parts)
    end.

contract_of(Map) ->
    text(get_any([contract_id, contract, recipient_id, <<"contract_id">>, <<"contract">>,
                  <<"recipient_id">>], Map, <<>>)).

observed_contract(Candidate, Candidates) ->
    case contract_of(Candidate) of
        <<>> -> first_nonempty([contract_of(C) || C <- Candidates]);
        C -> C
    end.

transaction_timestamp(Root) ->
    first_positive([
        time_ms(get_any([micro_time, block_time, time, created_at,
                         <<"micro_time">>, <<"block_time">>, <<"time">>, <<"created_at">>], X, 0))
     || X <- tx_candidates(Root)
    ]).

caller_of(Candidates) ->
    first_nonempty([
        ae_account(get_any([caller_id, sender_id, account_id, origin,
                            <<"caller_id">>, <<"sender_id">>, <<"account_id">>, <<"origin">>], X, <<>>))
     || X <- Candidates
    ]).

is_wrapped(X) ->
    Kind = lower(text(get_any([type, tx_type, kind, <<"type">>, <<"tx_type">>, <<"kind">>], X, <<>>))),
    regex(Kind, <<"(?:paying.?for|ga.?meta)">>).

is_paying_for(X) ->
    Kind = lower(text(get_any([type, tx_type, kind, <<"type">>, <<"tx_type">>, <<"kind">>], X, <<>>))),
    regex(Kind, <<"paying.?for">>).

payment_identity(Candidates) ->
    case lists:any(fun is_paying_for/1, Candidates) of
        false -> #{paying_for => false, payer => <<>>};
        true ->
            Payer = first_nonempty([
                ae_account(get_any([payer_id, fee_payer_id, payer,
                                    <<"payer_id">>, <<"fee_payer_id">>, <<"payer">>], X, <<>>))
             || X <- Candidates, is_paying_for(X)
            ]),
            #{paying_for => true, payer => Payer}
    end.

spend_caller(Spend, Candidates, TokenContract, PayingFor) ->
    Eligible = [X || X <- [Spend | Candidates], not is_paying_for(X),
                     (X =:= Spend orelse method_name(X) =:= <<"spend">> orelse
                      (contract_of(X) =:= TokenContract andalso
                       regex(lower(text(get_any([type, tx_type, <<"type">>, <<"tx_type">>], X, <<>>))),
                             <<"contract.?call">>)))],
    case caller_of(Eligible) of
        <<>> when PayingFor -> <<>>;
        <<>> -> caller_of(Candidates);
        Account -> Account
    end.

cids_from_call_data(Value0) ->
    Value = text(Value0),
    case Value of
        <<"cb_", Enc/binary>> ->
            try
                Decoded = base64:decode(Enc),
                Pattern = <<"(Qm[1-9A-HJ-NP-Za-km-z]{44}|bafy[a-zA-Z2-7]{20,120})">>,
                Matches = case re:run(Decoded, Pattern, [global, {capture, [1], binary}]) of
                    {match, Caps} -> [Cid || [Cid] <- Caps, is_cid(Cid)];
                    nomatch -> []
                end,
                case lists:usort(Matches) of
                    [A, B] when A =/= B -> [A, B];
                    _ -> []
                end
            catch _:_ -> [] end;
        _ -> []
    end.

%% ===================================================================
%% Status/time/text helpers
%% ===================================================================

status(Map) when is_map(Map) ->
    Declared = lower(text(get_any([status, <<"status">>], Map, <<>>))),
    Result = lower(text(get_any([result, <<"result">>], Map, <<>>))),
    case Declared of
        <<"passed">> -> passed;
        <<"success">> -> passed;
        <<"failed">> -> failed;
        <<"fail">> -> failed;
        <<"error">> -> failed;
        _ ->
            case Result of
                <<>> -> unknown;
                <<"unknown">> -> unknown;
                <<"success">> -> passed;
                <<"passed">> -> passed;
                _ -> failed
            end
    end;
status(_) -> unknown.

normalize_status(passed) -> passed;
normalize_status(failed) -> failed;
normalize_status(unknown) -> unknown;
normalize_status(B) when is_binary(B) ->
    case lower(B) of
        <<"passed">> -> passed;
        <<"success">> -> passed;
        <<"failed">> -> failed;
        <<"fail">> -> failed;
        <<"error">> -> failed;
        _ -> unknown
    end;
normalize_status(_) -> unknown.

prefer_status(unknown, Existing) -> normalize_status(Existing);
prefer_status(New, _Existing) -> normalize_status(New).

settlement_status(Map) ->
    S = lower(text(get_any([settlement_status, <<"settlement_status">>], Map, <<>>))),
    case S of
        <<"confirmed">> -> chain_confirmed;
        <<"pending">> -> pending_chain;
        _ -> pending_chain
    end.

time_ms(undefined) -> 0;
time_ms(null) -> 0;
time_ms(V) when is_binary(V) ->
    try time_ms(binary_to_float(V)) catch _:_ ->
        try time_ms(binary_to_integer(V)) catch _:_ -> 0 end
    end;
time_ms(V) when is_list(V) -> time_ms(unicode:characters_to_binary(V));
time_ms(V) when is_integer(V); is_float(V) ->
    N = float(V),
    if
        N >= 1.0e14 -> trunc(N / 1000);
        N >= 1.0e11 -> trunc(N);
        N >= 1.0e9 -> trunc(N * 1000);
        true -> 0
    end;
time_ms(_) -> 0.

duration_ms(V) when is_binary(V) ->
    try duration_ms(binary_to_float(V)) catch _:_ ->
        try duration_ms(binary_to_integer(V)) catch _:_ -> 0 end
    end;
duration_ms(V) when is_list(V) -> duration_ms(unicode:characters_to_binary(V));
duration_ms(V) when is_integer(V); is_float(V) ->
    N = float(V),
    if
        N =< 0 -> 0;
        N < 1000000 -> trunc(N * 1000);
        true -> trunc(N)
    end;
duration_ms(_) -> 0.

is_cid(V0) ->
    V = text(V0),
    regex(V, <<"^(?:Qm[1-9A-HJ-NP-Za-km-z]{44}|bafy[a-zA-Z2-7]{20,})$">>).

ae_account(V0) ->
    V = text(V0),
    case regex(V, <<"^ak_[1-9A-HJ-NP-Za-km-z]{20,70}$">>) of
        true -> V;
        false -> <<>>
    end.

normalize_tags(Tags) when is_list(Tags) ->
    lists:usort([T || Raw <- Tags,
                      T <- [lower(text(Raw))],
                      regex(T, <<"^@[A-Za-z0-9_.:-]+$">>)]);
normalize_tags(_) -> [].

result_summary(V) ->
    Bin0 = case V of
        B when is_binary(B) -> B;
        L when is_list(L) -> unicode:characters_to_binary(L);
        undefined -> <<>>;
        null -> <<>>;
        _ -> iolist_to_binary(io_lib:format("~p", [V]))
    end,
    Bin = binary:replace(binary:replace(Bin0, <<"\r">>, <<" ">>, [global]), <<"\n">>, <<" ">>, [global]),
    case byte_size(Bin) =< ?MAX_RESULT_SUMMARY of
        true -> Bin;
        false -> <<(binary:part(Bin, 0, ?MAX_RESULT_SUMMARY))/binary, "…">>
    end.

get_any([K | Rest], Map, Default) when is_map(Map) ->
    case maps:find(K, Map) of
        {ok, V} -> V;
        error -> get_any(Rest, Map, Default)
    end;
get_any([], _Map, Default) -> Default.

first_list([V | _]) when is_list(V) -> V;
first_list([_ | Rest]) -> first_list(Rest);
first_list([]) -> undefined.

first_nonempty([V | Rest]) ->
    case text(V) of <<>> -> first_nonempty(Rest); B -> B end;
first_nonempty([]) -> <<>>.

first_text([V | Rest], Prefix) ->
    B = text(V),
    case binary:match(B, Prefix) of
        {0, _} -> B;
        _ -> first_text(Rest, Prefix)
    end;
first_text([], _Prefix) -> <<>>.

first_positive([V | Rest]) when is_integer(V), V > 0 -> V;
first_positive([_ | Rest]) -> first_positive(Rest);
first_positive([]) -> 0.

prefer_text(A, B) -> case text(A) of <<>> -> text(B); V -> V end.
prefer_list([], B) -> B;
prefer_list(A, _B) -> A.
prefer_number(A, B) when is_number(A), A > 0 -> integer_value(A);
prefer_number(_A, B) -> integer_value(B).

number(V) when is_integer(V); is_float(V) -> V;
number(V) when is_binary(V) ->
    try binary_to_integer(V) catch _:_ ->
        try binary_to_float(V) catch _:_ -> 0 end
    end;
number(_) -> 0.

integer_value(V) when is_integer(V) -> V;
integer_value(V) when is_float(V) -> trunc(V);
integer_value(V) when is_binary(V) ->
    try binary_to_integer(V) catch _:_ -> 0 end;
integer_value(_) -> 0.

text(undefined) -> <<>>;
text(null) -> <<>>;
text(B) when is_binary(B) -> B;
text(A) when is_atom(A) -> atom_to_binary(A, utf8);
text(L) when is_list(L) -> unicode:characters_to_binary(L);
text(I) when is_integer(I) -> integer_to_binary(I);
text(F) when is_float(F) -> float_to_binary(F, [short]);
text(V) -> iolist_to_binary(io_lib:format("~p", [V])).

lower(B) when is_binary(B) -> list_to_binary(string:lowercase(binary_to_list(B)));
lower(V) -> lower(text(V)).

regex(Bin, Pattern) when is_binary(Bin), is_binary(Pattern) ->
    re:run(Bin, Pattern, [{capture, none}]) =:= match.

atom_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
atom_bin(B) when is_binary(B) -> B;
atom_bin(V) -> text(V).
