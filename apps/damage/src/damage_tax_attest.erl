%%% On-chain immutable proof: no private receipts, addresses or raw reports on-chain.
%%% The proof binds hashes, not tax correctness. Account owner must authorise signing.
-module(damage_tax_attest).
-export([verify_bundle/1, prepare/1, submit/3]).

-spec verify_bundle(map()) -> ok | {error, term()}.
verify_bundle(#{<<"manifest">> := Manifest,
                <<"manifest_sha256">> := Hash,
                <<"attestable">> := true}) ->
    Actual = damage_tax_canonical:commitment(Manifest),
    Evidence = maps:get(<<"evidence_hashes">>, Manifest, []),
    EvidenceHash = damage_tax_canonical:commitment(Evidence),
    case {Hash =:= Actual,
          EvidenceHash =:= maps:get(<<"evidence_set_sha256">>, Manifest, undefined),
          maps:get(<<"review_required">>, Manifest, undefined) =:= [],
          Evidence =/= [],
          evidence_present(Evidence)} of
        {true, true, true, true, true} -> ok;
        _ -> {error, unverified_or_incomplete_tax_bundle}
    end;
verify_bundle(_) -> {error, unapproved_tax_report}.

-spec prepare(map()) -> {ok, map()} | {error, term()}.
prepare(Report) ->
    case verify_bundle(Report) of
        ok ->
            Manifest = maps:get(<<"manifest">>, Report),
            Year = maps:get(<<"tax_year_end">>, Manifest),
            {ok, #{<<"period">> => <<"AU-FY-", (integer_to_binary(Year))/binary>>,
                   <<"manifest_sha256">> => maps:get(<<"manifest_sha256">>, Report),
                   <<"evidence_set_sha256">> => maps:get(<<"evidence_set_sha256">>, Report),
                   <<"ruleset">> => maps:get(<<"ruleset">>, Manifest)}};
        Error -> Error
    end.

-spec submit(map(), binary(), map()) -> {ok, map()} | {error, term()}.
submit(KeyPair, ContractId, Report) when is_map(KeyPair), is_binary(ContractId) ->
    Key = maps:get(private_key, KeyPair, undefined),
    KeyPresent = is_binary(Key) andalso byte_size(Key) > 0 andalso
        is_binary(maps:get(public_key, KeyPair, undefined)),
    case {KeyPresent, prepare(Report)} of
        {true, {ok, Proof}} ->
            Args = [binary_to_list(maps:get(<<"period">>, Proof)),
                    binary_to_list(maps:get(<<"manifest_sha256">>, Proof)),
                    binary_to_list(maps:get(<<"evidence_set_sha256">>, Proof)),
                    binary_to_list(maps:get(<<"ruleset">>, Proof))],
            Path = damage_ae:contract_path(damage, "contracts/tax_evidence_anchor.aes"),
            case damage_ae:contract_call(KeyPair, ContractId, Path, "commit", Args) of
                #{"return_type" := "ok", "tx_hash" := TxHash} ->
                    {ok, Proof#{<<"tx_hash">> => damage_tax_event:to_binary(TxHash),
                                <<"status">> => <<"submitted_check_chain_confirmation">>}};
                Other -> {error, {anchor_submission_failed, Other}}
            end;
        {false, _} -> {error, signing_key_required};
        {_, Error} -> Error
    end;
submit(_, _, _) -> {error, invalid_anchor_request}.

evidence_present(Evidence) ->
    case whereis(damage_tax_store) of
        undefined -> false;
        _ -> lists:all(fun(SHA) -> damage_tax_store:evidence_exists(SHA) end, Evidence)
    end.
