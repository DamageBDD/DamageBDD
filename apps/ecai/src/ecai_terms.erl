%%%-------------------------------------------------------------------
%%% ecai_terms.erl
%%%
%%% Canonical term pipeline shared by the in-memory and disk indexes.
%%%
%%% Version 1 intentionally preserves the existing Yelp term format:
%%%   field:token
%%%   pfx:field:prefix
%%%   sfx:field:reversed_suffix
%%%   ng:field:ngram
%%%
%%% The same pipeline also covers Wikipedia and deterministic IPFS records.
%%% Any behavior change that alters emitted terms requires a version bump.
%%%-------------------------------------------------------------------
-module(ecai_terms).

-export([
    version/0,
    terms_from_record/1,
    terms_from_query/2
]).

-define(P_MIN, 2).
-define(P_MAX, 8).
-define(CITY_P_MAX, 6).
-define(MAX_TEXT_TOKENS, 256).
-define(MAX_ABSTRACT_TOKENS, 120).

-spec version() -> binary().
version() ->
    <<"ecai-terms/v1">>.

-spec terms_from_record(map()) -> [binary()].
terms_from_record(Record) when is_map(Record) ->
    lists:usort(
        lists:append([
            token_field_terms(
                <<"name">>,
                field(Record, name, <<>>),
                #{prefix => true, suffix => true, prefix_max => ?P_MAX}
            ),
            token_field_terms(
                <<"title">>,
                field(Record, title, <<>>),
                #{prefix => true, suffix => true, prefix_max => ?P_MAX}
            ),
            token_field_terms(
                <<"heading">>,
                field(Record, heading, <<>>),
                #{prefix => true, suffix => false, prefix_max => ?P_MAX}
            ),
            scalar_field_terms(<<"cat">>, field(Record, category, <<>>)),
            token_field_terms(
                <<"city">>,
                field(Record, city, <<>>),
                #{prefix => true, suffix => false, prefix_max => ?CITY_P_MAX}
            ),
            tag_terms(field(Record, tags, [])),
            phone_terms(field(Record, phone, <<>>), true),
            token_field_terms(
                <<"text">>,
                field(Record, text, <<>>),
                #{prefix => false, suffix => false, cap => ?MAX_TEXT_TOKENS}
            ),
            token_field_terms(
                <<"abstract">>,
                field(Record, abstract, <<>>),
                #{prefix => false, suffix => false, cap => ?MAX_ABSTRACT_TOKENS}
            ),
            scalar_field_terms(<<"type">>, field(Record, type, <<>>)),
            scalar_field_terms(<<"language">>, field(Record, language, <<>>)),
            scalar_field_terms(
                <<"wikidata">>,
                field(Record, wikidata_id, <<>>)
            )
        ])
    );
terms_from_record(_Other) ->
    erlang:error(badarg).

-spec terms_from_query(map(), boolean()) -> [binary()].
terms_from_query(Query, PrefixDefault) when is_map(Query), is_boolean(PrefixDefault) ->
    Prefix = boolean_field(Query, prefix, PrefixDefault),
    Suffix = boolean_field(Query, suffix, false),
    InfixN = non_negative_integer_field(Query, infix_n, 0),
    lists:usort(
        lists:append([
            query_token_field(
                Query,
                name,
                <<"name">>,
                #{prefix => Prefix, suffix => Suffix, infix_n => InfixN}
            ),
            query_token_field(
                Query,
                title,
                <<"title">>,
                #{prefix => Prefix, suffix => Suffix, infix_n => InfixN}
            ),
            query_token_field(
                Query,
                heading,
                <<"heading">>,
                #{prefix => Prefix, suffix => false, infix_n => 0}
            ),
            query_scalar_field(Query, category, <<"cat">>),
            query_token_field(
                Query,
                city,
                <<"city">>,
                #{prefix => Prefix, suffix => false, prefix_max => ?CITY_P_MAX}
            ),
            query_tags(Query),
            query_phone(Query, Prefix),
            query_token_field(
                Query,
                text,
                <<"text">>,
                #{prefix => false, suffix => false, infix_n => 0}
            ),
            query_token_field(
                Query,
                abstract,
                <<"abstract">>,
                #{prefix => false, suffix => false, infix_n => 0}
            ),
            query_scalar_field(Query, type, <<"type">>),
            query_scalar_field(Query, language, <<"language">>),
            query_scalar_field(Query, wikidata_id, <<"wikidata">>)
        ])
    );
terms_from_query(_Query, _PrefixDefault) ->
    erlang:error(badarg).

%%%===================================================================
%%% Record fields
%%%===================================================================

token_field_terms(Field, Value, Opts) ->
    Cap = maps:get(cap, Opts, infinity),
    Tokens = capped_tokens(Value, Cap),
    PrefixMax = maps:get(prefix_max, Opts, ?P_MAX),
    Exact = [term_key(Field, Token) || Token <- Tokens],
    Prefix =
        case maps:get(prefix, Opts, false) of
            true ->
                [
                    term_pfx(Field, Part)
                 || Part <- prefixes_many(Tokens, ?P_MIN, PrefixMax)
                ];
            false ->
                []
        end,
    Suffix =
        case maps:get(suffix, Opts, false) of
            true ->
                [
                    term_sfx(Field, reverse_bin(Part))
                 || Part <- suffixes_many(Tokens, ?P_MIN, PrefixMax)
                ];
            false ->
                []
        end,
    Exact ++ Prefix ++ Suffix.

scalar_field_terms(Field, Value) ->
    case lower_scalar(Value) of
        <<>> -> [];
        Bin -> [term_key(Field, Bin)]
    end.

tag_terms(Value) ->
    [
        term_key(<<"tag">>, Tag)
     || Item <- tag_values(Value),
        Tag <- [lower_scalar(Item)],
        Tag =/= <<>>
    ].

phone_terms(Value, Prefix) ->
    case ecai_tokenizer:digits_only(Value) of
        <<>> ->
            [];
        Digits ->
            Exact = [term_key(<<"phone">>, Digits)],
            case Prefix of
                true ->
                    Exact ++
                        [
                            term_pfx(<<"phone">>, Part)
                         || Part <- pfx1(Digits, 3, 8)
                        ];
                false ->
                    Exact
            end
    end.

%%%===================================================================
%%% Query fields
%%%===================================================================

query_token_field(Query, Key, Field, Opts0) ->
    case find_field(Query, Key) of
        error ->
            [];
        {ok, Value} ->
            PrefixMax = maps:get(prefix_max, Opts0, ?P_MAX),
            Tokens = capped_tokens(Value, infinity),
            Exact = [term_key(Field, Token) || Token <- Tokens],
            Prefix =
                case maps:get(prefix, Opts0, false) of
                    true ->
                        [
                            term_pfx(Field, Part)
                         || Part <- prefixes_many(
                                Tokens,
                                ?P_MIN,
                                PrefixMax
                            )
                        ];
                    false ->
                        []
                end,
            Suffix =
                case maps:get(suffix, Opts0, false) of
                    true ->
                        [
                            term_sfx(Field, reverse_bin(Part))
                         || Part <- suffixes_many(
                                Tokens,
                                ?P_MIN,
                                PrefixMax
                            )
                        ];
                    false ->
                        []
                end,
            Ngrams =
                case maps:get(infix_n, Opts0, 0) of
                    N when is_integer(N), N > 0 ->
                        [term_ng(Field, Ng) || Ng <- ngrams_many(Tokens, N)];
                    _ ->
                        []
                end,
            Exact ++ Prefix ++ Suffix ++ Ngrams
    end.

query_scalar_field(Query, Key, Field) ->
    case find_field(Query, Key) of
        error -> [];
        {ok, Value} -> scalar_field_terms(Field, Value)
    end.

query_tags(Query) ->
    case find_field(Query, tags) of
        error -> [];
        {ok, Value} -> tag_terms(Value)
    end.

query_phone(Query, Prefix) ->
    case find_field(Query, phone) of
        error -> [];
        {ok, Value} -> phone_terms(Value, Prefix)
    end.

%%%===================================================================
%%% Canonical helpers
%%%===================================================================

field(Map, Key, Default) ->
    case find_field(Map, Key) of
        {ok, Value} -> Value;
        error -> Default
    end.

find_field(Map, Key) ->
    case maps:find(Key, Map) of
        {ok, _Value} = Found ->
            Found;
        error ->
            maps:find(atom_to_binary(Key, utf8), Map)
    end.

boolean_field(Map, Key, Default) ->
    case field(Map, Key, Default) of
        true -> true;
        false -> false;
        _Other -> Default
    end.

non_negative_integer_field(Map, Key, Default) ->
    case field(Map, Key, Default) of
        Value when is_integer(Value), Value >= 0 -> Value;
        _Other -> Default
    end.

capped_tokens(Value, infinity) ->
    ecai_tokenizer:tokens(Value);
capped_tokens(Value, Cap) when is_integer(Cap), Cap >= 0 ->
    lists:sublist(ecai_tokenizer:tokens(Value), Cap).

lower_scalar(undefined) ->
    <<>>;
lower_scalar(null) ->
    <<>>;
lower_scalar(Value) when
    is_binary(Value);
    is_list(Value);
    is_atom(Value);
    is_integer(Value);
    is_float(Value)
->
    ecai_tokenizer:lower_ascii(Value);
lower_scalar(_Other) ->
    <<>>.

tag_values([]) ->
    [];
tag_values(Value) when is_binary(Value); is_atom(Value); is_integer(Value) ->
    [Value];
tag_values([Head | _] = Value) when is_integer(Head) ->
    %% A flat character list is one tag, not a list of numeric tags.
    [Value];
tag_values(Value) when is_list(Value) ->
    Value;
tag_values(_Other) ->
    [].

term_key(Namespace, Token0) ->
    Token = binary:copy(Token0),
    <<Namespace/binary, $:, Token/binary>>.

term_pfx(Namespace, Prefix0) ->
    Prefix = binary:copy(Prefix0),
    <<"pfx:", Namespace/binary, $:, Prefix/binary>>.

term_sfx(Field, Suffix0) ->
    Suffix = binary:copy(Suffix0),
    <<"sfx:", Field/binary, $:, Suffix/binary>>.

term_ng(Field, Ngram0) ->
    Ngram = binary:copy(Ngram0),
    <<"ng:", Field/binary, $:, Ngram/binary>>.

prefixes_many(Tokens, Min, Max) ->
    lists:usort(lists:append([pfx1(Token, Min, Max) || Token <- Tokens])).

suffixes_many(Tokens, Min, Max) ->
    lists:usort(lists:append([suffixes(Token, Min, Max) || Token <- Tokens])).

ngrams_many(_Tokens, 0) ->
    [];
ngrams_many(Tokens, N) when is_integer(N), N > 0 ->
    lists:usort(lists:append([ngrams(Token, N) || Token <- Tokens])).

pfx1(Bin, Min, Max) ->
    Length = byte_size(Bin),
    To = erlang:min(Max, Length),
    lengths(Min, To, fun(N) -> binary:part(Bin, 0, N) end).

suffixes(Bin, Min, Max) ->
    Length = byte_size(Bin),
    To = erlang:min(Max, Length),
    lengths(Min, To, fun(N) -> binary:part(Bin, Length - N, N) end).

ngrams(Bin, N) ->
    Length = byte_size(Bin),
    case Length < N of
        true -> [];
        false -> [binary:part(Bin, I, N) || I <- lists:seq(0, Length - N)]
    end.

lengths(Min, Max, _Fun) when Min > Max ->
    [];
lengths(Min, Max, Fun) ->
    [Fun(N) || N <- lists:seq(Min, Max)].

%% Version 1 preserves the historical byte-reversal behavior used by the
%% existing Yelp index. Changing this to code-point reversal requires v2.
reverse_bin(Bin) ->
    list_to_binary(lists:reverse(binary:bin_to_list(Bin))).
