%% File: yaml_yamerl.erl
%% YAML emitter aligned with yamerl "simple mode" terms.
%% Scalars allowed: binary() | integer() | float() | true | false | undefined.
%% Keys: binary().
%% Collections: maps, proplists([{binary(), V}]), lists (sequences).
%% Returns UTF-8 binary with trailing "\n".

-module(yaml_simple).
-include_lib("kernel/include/logger.hrl").
-export([encode/1, encode_iolist/1]).
-export([test/0]).

-define(IND, 2).

encode(Term) ->
    iolist_to_binary(encode_iolist(Term)).

encode_iolist(Term) ->
    emit(Term, 0).

%% -------- emit --------
emit(#{}, I) ->
    [indent(I), "{}\n"];
emit(Map, I) when is_map(Map) ->
    [emit_kv(K, V, I) || {K, V} <- maps:to_list(Map)];
emit(List, I) when is_list(List) ->
    case is_string_list(List) of
        % treat as scalar
        true ->
            [indent(I), scalar_string(List), "\n"];
        false ->
            case maybe_proplist(List) of
                {maplike, KVs} ->
                    [emit_kv(K, V, I) || {K, V} <- KVs];
                sequence ->
                    case List of
                        [] -> [indent(I), "[]\n"];
                        _ -> [emit_seq_item(V, I) || V <- List]
                    end
            end
    end;
emit(Bin, I) when is_binary(Bin) -> [indent(I), scalar_binary(Bin), "\n"];
emit(Int, I) when is_integer(Int) -> [indent(I), integer_to_list(Int), "\n"];
emit(Flt, I) when is_float(Flt) -> [indent(I), io_lib:format("~.16g", [Flt]), "\n"];
emit(true, I) ->
    [indent(I), "true\n"];
emit(false, I) ->
    [indent(I), "false\n"];
emit(undefined, I) ->
    [indent(I), "null\n"];
emit(null, I) ->
    [indent(I), "null\n"];
emit(_, _I) ->
    throw({error, unsupported_term}).

emit_kv(K, V, I) when is_binary(K) ->
    emit_kv_keyrender(key_scalar_binary(K), V, I);
emit_kv(K, V, I) when is_list(K) ->
    case is_string_list(K) of
        true -> emit_kv_keyrender(key_scalar_string(K), V, I);
        false -> throw({error, key_must_be_binary_or_string})
    end;
emit_kv(_, _, _) ->
    throw({error, key_must_be_binary_or_string}).

emit_kv_keyrender(K1, V, I) ->
    case is_complex(V) of
        true -> [indent(I), K1, ":\n", emit(V, I + 1)];
        false -> [indent(I), K1, ": ", scalar_or_simple(V), "\n"]
    end.

emit_seq_item(V, I) ->
    case is_complex(V) of
        true -> [indent(I), "- ", $\n, emit(V, I + 1)];
        false -> [indent(I), "- ", scalar_or_simple(V), "\n"]
    end.

%% -------- shapes --------
is_complex(V) when is_map(V) -> true;
is_complex(V) when is_list(V) ->
    case is_string_list(V) of
        % list-as-string is a scalar
        true ->
            false;
        false ->
            case maybe_proplist(V) of
                {maplike, _} -> true;
                sequence -> true
            end
    end;
is_complex(_) ->
    false.

maybe_proplist([]) ->
    sequence;
maybe_proplist(L) when is_list(L) ->
    case
        lists:all(
            fun(E) ->
                case E of
                    {K, _} when is_binary(K) -> true;
                    {K, _} when is_list(K) -> is_string_list(K);
                    _ -> false
                end
            end,
            L
        )
    of
        true -> {maplike, L};
        false -> sequence
    end.

%% -------- scalar helpers --------
scalar_or_simple(B) when is_binary(B) -> scalar_binary(B);
scalar_or_simple(S) when is_list(S) ->
    case is_string_list(S) of
        true -> scalar_string(S);
        false -> throw({error, {unsupported_scalar, S}})
    end;
scalar_or_simple(I) when is_integer(I) -> integer_to_list(I);
scalar_or_simple(F) when is_float(F) -> io_lib:format("~.16g", [F]);
scalar_or_simple(true) ->
    "true";
scalar_or_simple(false) ->
    "false";
scalar_or_simple(undefined) ->
    "null";
scalar_or_simple(null) ->
    "null";
scalar_or_simple(O) ->
    throw({error, {unsupported_scalar, O}}).

%% binaries
scalar_binary(Bin) ->
    Str = to_utf8_list(Bin),
    case plain_ok(Str) of
        true -> Str;
        false -> dquote(Str)
    end.
key_scalar_binary(Bin) -> scalar_binary(Bin).

to_utf8_list(Bin) ->
    case unicode:characters_to_list(Bin, utf8) of
        L when is_list(L) -> L;
        _ -> throw({error, non_utf8_binary})
    end.

%% strings (already list of codepoints)
scalar_string(Str) ->
    case plain_ok(Str) of
        true -> Str;
        false -> dquote(Str)
    end.
key_scalar_string(Str) -> scalar_string(Str).

%% list-of-int “string” detector (NOT in guards)
is_string_list([]) ->
    true;
is_string_list(L) when is_list(L) ->
    lists:all(fun(C) -> is_integer(C) end, L).

dquote(Str) -> [$", escape_dq(Str), $"].
escape_dq(Str) -> lists:flatten([esc(C) || C <- Str]).
esc($\\) -> "\\\\";
esc($") -> "\\\"";
esc($\n) -> "\\n";
esc($\r) -> "\\r";
esc($\t) -> "\\t";
esc(C) when C < 32 -> io_lib:format("\\u~4.16.0B", [C]);
esc(C) -> C.

%% conservative plain-scalar policy
plain_ok(Str) ->
    Str =/= [] andalso single_line(Str) andalso
        lists:all(fun plain_char/1, Str) andalso
        not starts_bad(hd(Str)) andalso
        not ends_bad(lists:last(Str)) andalso
        not reserved(Str).

single_line(Str) ->
    not lists:any(fun(C) -> C =:= $\n orelse C =:= $\r end, Str).
plain_char(C) ->
    C >= 32 andalso C =/= $: andalso C =/= $# andalso C =/= $, andalso
        C =/= $[ andalso C =/= $] andalso C =/= ${ andalso C =/= $} andalso
        C =/= $| andalso C =/= $> andalso C =/= $' andalso C =/= $" andalso
        C =/= $% andalso C =/= $@ andalso C =/= $` andalso C =/= $?.
starts_bad(C) -> lists:member(C, "-?:@&*!#|>'\"%`{[") orelse C =:= $~.
ends_bad(C) -> C =:= $:.
reserved(Str) ->
    Lower = string:lowercase(Str),
    lists:member(Lower, [
        "y",
        "yes",
        "n",
        "no",
        "true",
        "false",
        "on",
        "off",
        "null",
        "~",
        "nan",
        "inf",
        "infinity",
        "-inf",
        "-infinity"
    ]).

indent(I) when I =< 0 -> [];
indent(I) -> lists:duplicate(I * ?IND, $\s).

test() ->
    TL = [
        {"refund_address", "mohjSavDdQYHRYXcS3uS6ttaHP8amyvX78"},
        {"customer_type", "Individual"},
        {"full_name", "John Doe"},
        {"date_of_birth", "1980-01-01"},
        {"address", "123 Main Street, Sydney, NSW"},
        {"identification_verification", null},
        {"document_type", "Passport"},
        {"document_number", "A1234567"},
        {"email", "john.doe@damagebdd.com"},
        {"phone", "0412345678"}
    ],
    io:format("~s", [encode(TL)]),
    PL = [
        {"refund_address", "mohjSaVDdQYHRYXc3Su56ttaHP8amvyx78"},
        {"customer_type", "Individual"},
        {"full_name", "John Doe"},
        {"date_of_birth", "1980-01-01"},
        {"address", "123 Main Street, Sydney, NSW"},
        {"identification_verification", null},
        {"document_type", "Passport"},
        {"document_number", "A1234567"},
        {"email", "john.doe@damagebdd.com"},
        {"phone", "0412345678"}
    ],
    io:format("~s", [encode(PL)]),
    io:format("~s", [encode(PL)]),
    %% Scalars
    io:format("Scalar (bin):~n~s~n", [encode(<<"hello">>)]),
    io:format("Scalar (int):~n~s~n", [encode(42)]),
    io:format("Scalar (float):~n~s~n", [encode(3.14159)]),
    io:format("Scalar (true):~n~s~n", [encode(true)]),
    io:format("Scalar (false):~n~s~n", [encode(false)]),
    io:format("Scalar (undefined):~n~s~n", [encode(undefined)]),
    io:format("Scalar (null):~n~s~n", [encode(undefined)]),

    %% Sequence
    Seq = [<<"one">>, <<"two">>, <<"three">>],
    io:format("Sequence:~n~s~n", [encode(Seq)]),

    %% Map
    Map = #{
        <<"name">> => <<"Steven">>,
        <<"age">> => 42,
        <<"pi">> => 3.1415,
        <<"alive">> => true,
        <<"skills">> => [<<"Erlang">>, <<"BDD">>, <<"Bitcoin">>]
    },
    io:format("Map:~n~s~n", [encode(Map)]),

    %% Proplist
    Prop = [
        {<<"username">>, <<"damagepool">>},
        {<<"active">>, true},
        {<<"projects">>, [<<"DamageBDD">>, <<"ECAI">>]}
    ],
    io:format("Proplist:~n~s~n", [encode(Prop)]),

    %% Nested
    Nested = #{
        <<"outer">> => #{
            <<"inner">> => [
                {<<"key1">>, <<"val1">>},
                {<<"key2">>, 99}
            ]
        }
    },
    io:format("Nested:~n~s~n", [encode(Nested)]),

    ok.
