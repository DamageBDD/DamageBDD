-module(ecai_finding_adjudicator).

-export([adjudicate/1]).

-ifdef(TEST).
-export([
    existing_atom_allocation_claim/1,
    recommends_binary_to_atom/1
]).
-endif.

-spec adjudicate(map()) -> accept | {reject, map()}.
adjudicate(Finding) when is_map(Finding) ->
    case
        {
            existing_atom_allocation_claim(Finding),
            recommends_binary_to_atom(Finding)
        }
    of
        {true, _} ->
            {reject, #{
                class => invalid_security_premise,
                invariant =>
                    <<"binary_to_existing_atom/2 does not allocate new atoms">>,
                rule => existing_atom_allocation_claim
            }};
        {_, true} ->
            {reject, #{
                class => unsafe_remediation,
                invariant =>
                    <<"binary_to_atom/2 may allocate new atoms and must not replace binary_to_existing_atom/2 as an atom-exhaustion mitigation">>,
                rule => binary_to_atom_replacement
            }};
        _ ->
            accept
    end;
adjudicate(_) ->
    accept.

existing_atom_allocation_claim(Finding) ->
    MentionsExisting =
        contains_any(
            finding_text(
                Finding,
                [
                    <<"title">>,
                    <<"evidence">>,
                    <<"function">>,
                    <<"impact">>,
                    <<"remediation">>
                ]
            ),
            [
                <<"binary_to_existing_atom">>,
                <<"existing_module_atom">>
            ]
        ),
    ClaimsAllocationRisk =
        contains_any(
            finding_text(
                Finding,
                [<<"title">>, <<"evidence">>, <<"impact">>]
            ),
            [
                <<"atom table exhaustion">>,
                <<"atom-table exhaustion">>,
                <<"arbitrary atom injection">>,
                <<"creates arbitrary atoms">>,
                <<"create arbitrary atoms">>,
                <<"allocates new atoms">>,
                <<"allocate new atoms">>
            ]
        ),
    MentionsExisting andalso ClaimsAllocationRisk.

recommends_binary_to_atom(Finding) ->
    Remediation = finding_text(
        Finding,
        [<<"remediation">>, <<"proposed_patch">>]
    ),
    MentionsExisting =
        contains_any(
            finding_text(
                Finding,
                [<<"title">>, <<"evidence">>, <<"function">>]
            ),
            [<<"binary_to_existing_atom">>, <<"existing_module_atom">>]
        ),
    MentionsExisting andalso
        contains_any(
            Remediation,
            [
                <<"binary_to_atom(">>,
                <<"binary_to_atom/2">>
            ]
        ).

finding_text(Finding, Keys) ->
    Parts = [
        normalize_text(mget(Key, Finding, <<>>))
     || Key <- Keys
    ],
    iolist_to_binary(lists:join(<<"\n">>, Parts)).

normalize_text(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(
        string:lowercase(binary_to_list(Bin))
    );
normalize_text(List) when is_list(List) ->
    unicode:characters_to_binary(
        string:lowercase(List)
    );
normalize_text(Atom) when is_atom(Atom) ->
    normalize_text(atom_to_binary(Atom, utf8));
normalize_text(_) ->
    <<>>.

contains_any(Text, Needles) ->
    lists:any(
        fun(Needle) ->
            binary:match(Text, Needle) =/= nomatch
        end,
        Needles
    ).

mget(Key, Map, Default) when is_map(Map), is_binary(Key) ->
    case maps:find(Key, Map) of
        {ok, Value} ->
            Value;
        error ->
            try binary_to_existing_atom(Key, utf8) of
                AtomKey -> maps:get(AtomKey, Map, Default)
            catch
                error:badarg -> Default
            end
    end;
mget(_Key, _Map, Default) ->
    Default.
