%%% @doc
%%% ZJ: The tiny JSON parser
%%%
%%% This module exports four functions and accepts no options.
%%% @end

-module(zj).
-vsn("1.1.0").
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("MIT").

-export([encode/1,        decode/1,
         binary_encode/1, binary_decode/1]).

-export_type([value/0, bin_value/0]).

-type value()     :: string()
                   | number()
                   | true
                   | false
                   | undefined
                   | [value()]
                   | #{string() := value()}.


-type bin_value() :: binary()
                   | number()
                   | true
                   | false
                   | undefined
                   | [bin_value()]
                   | #{binary() := bin_value()}.



%%% Character constants

-define(BKSPC, 16#08).
-define(H_TAB, 16#09).
-define(NEW_L, 16#0A).
-define(FORMF, 16#0C).
-define(CAR_R, 16#0D).
-define(SPACE, 16#20).


%%% Interface Functions

-spec encode(term()) -> string().

%% @doc
%% Take any convertable Erlang term and convert it to a JSON string.
%%
%% As JSON can only satirically be referred to as "a serialization format", it is
%% almost impossible to map any interesting data between Erlang (or any other language)
%% and JSON. For example, tuples do not exist in JSON, so converting an Erlang tuple
%% turns it into a list (a JSON array). Atoms also do not exist, so atoms other than
%% the ternay logic values `true', `false' and `null' become strings (those three
%% remain as atoms, with the added detail that JSON `null' maps to Erlang
%% `undefined').
%%
%% Unless care is taken to pick types that JSON can accurately express (integers,
%% floats, strings, maps, lists, ternary logic atoms) it is not possible to guarantee
%% (or even reasonable to expect) that `Term == decode(encode(Term))' will be true.
%%
%% This function crashes when it fails. Things that will cause a crash are trying to
%% convert non-UTF-8 binaries to strings, use non-string values as object keys,
%% encode an unaligned bitstring, etc.
%%
%% Note that Erlang terms are converted as type primitives, meaning that compound
%% functional structures like GB-trees, dicts, sets, etc. will wind up having their
%% underlying structures converted as-is which is almost never what you want. It is
%% usually best to reduce compound values down to primitives (lists or maps) before
%% running encode.
%%
%% The only unsupported Erlang pritmitive is bitstrings. Care has NOT been taken to
%% ensure separation between actual binary data and binaries that are supposed to be
%% interpreted as strings. The same is true of deep list data: it just comes out raw
%% unless you flatten or convert it to a utf8 string with the unicode module.
%%
%% NOTE: If you need a serialization format that is less ambiguous and expresses more
%% types consider using BERT (language-independent implementations of Erlang external
%% binary format) instead: http://bert-rpc.org

encode(true)                   -> "true";
encode(false)                  -> "false";
encode(undefined)              -> "null";
encode([])                     -> "[]";
encode(T) when is_atom(T)      -> quote(atom_to_list(T));
encode(T) when is_float(T)     -> float_to_list(T);
encode(T) when is_integer(T)   -> integer_to_list(T);
encode(T) when is_pid(T)       -> quote(pid_to_list(T));
encode(T) when is_port(T)      -> quote(port_to_list(T));
encode(T) when is_function(T)  -> quote(erlang:fun_to_list(T));
encode(T) when is_reference(T) -> quote(ref_to_list(T));
encode(T)                      -> unicode:characters_to_list(encode_value(T)).


-spec decode(Stream) -> Result
    when Stream    :: unicode:chardata(),
         Result    :: {ok, value()}
                    | {error, Parsed, Remainder}
                    | {incomplete, Parsed, Remainder},
         Parsed    :: value(),
         Remainder :: unicode:chardata()
                    | unicode:external_chardata()
                    | binary().
%% @doc
%% Take any IO data acceptable to the unicode module and return a parsed data structure.
%% In the event of a parsing error whatever part of the structure could be successfully
%% parsed will be returned along with the remainder of the string. Note that the string
%% remainder may have been changed to a different form by unicode:characters_to_list/1.
%% If the unicode library itself runs into a problem performing the initial conversion
%% its error return (`error' or `incomplete') will be returned directly.

decode(Stream) ->
    case unicode:characters_to_list(Stream) of
        E when is_tuple(E) -> E;
        [16#FEFF | String] -> parse(seek(String));
        String             -> parse(seek(String))
    end.


-spec binary_encode(term()) -> binary().
%% @doc
%% A strict encoding routine that works very similarly to `encode/1' but with a few
%% differences:
%% ```
%%  - Lists and Strings are firmly separated:
%%     ALL lists are lists of discrete values, never strings.
%%     ALL binaries are always UTF-8 strings.
%%     An Erlang string or io_list will be encoded as JSON array.
%%  - This function generates a UTF-8 binary, not a list.
%%  - The burden is on the user to ensure that io_lists are collapsed to unicode
%%    binaries via `unicode:characters_to_binary/1' before passing in string values.
%%  - Erlang strings (lists) are still accepted as map/object keys.
%% '''
%%
%% NOTE:
%% Most cases are better served by `encode/1', as most code deals in strings and not
%% arrays of integer values.
%%
%% Using this function requires a little bit more work up front (because ununified
%% io_list() data will always be interpreted as a JSON array), but provides a way to
%% reliably generate lists or strings in an unambiguous way in the special case where
%% your code is generating both strings and lists of integer values that may overlap
%% with valid UTF-8 codepoint values.

binary_encode(true)                   -> <<"true">>;
binary_encode(false)                  -> <<"false">>;
binary_encode(undefined)              -> <<"null">>;
binary_encode(T) when is_atom(T)      -> <<"\"", (atom_to_binary(T, utf8))/binary, "\"">>;
binary_encode(T) when is_float(T)     -> float_to_binary(T);
binary_encode(T) when is_integer(T)   -> integer_to_binary(T);
binary_encode(T) when is_pid(T)       -> <<"\"", (list_to_binary(pid_to_list(T)))/binary, "\"">>;
binary_encode(T) when is_port(T)      -> <<"\"", (list_to_binary(port_to_list(T)))/binary, "\"">>;
binary_encode(T) when is_function(T)  -> <<"\"", (list_to_binary(erlang:fun_to_list(T)))/binary, "\"">>;
binary_encode(T) when is_reference(T) -> <<"\"", (list_to_binary(ref_to_list(T)))/binary, "\"">>;
binary_encode(T)                      -> unicode:characters_to_binary(b_encode_value(T)).


-spec binary_decode(Stream) -> Result
    when Stream    :: unicode:chardata(),
         Result    :: {ok, bin_value()}
                    | {error, Parsed, Remainder}
                    | {incomplete, Parsed, Remainder},
         Parsed    :: bin_value(),
         Remainder :: binary().
%% @doc
%% Almost identical in behavior to `decode/1' except this returns strings as binaries
%% and arrays of integers as Erlang lists (which may also be valid strings if the
%% values are valid UTF-8 codepoints).
%%
%% NOTE:
%% This function returns map keys as binaries

binary_decode(Stream) ->
    case b_decode(Stream) of
        {error, Part, Rest} -> {error, Part, unicode:characters_to_binary(Rest)};
        Result              -> Result
    end.



%%% Encoding Functions

encode_value(true)                   -> "true";
encode_value(false)                  -> "false";
encode_value(undefined)              -> "null";
encode_value(T) when is_atom(T)      -> quote(atom_to_list(T));
encode_value(T) when is_float(T)     -> float_to_list(T);
encode_value(T) when is_integer(T)   -> integer_to_list(T);
encode_value(T) when is_binary(T)    -> maybe_string(T);
encode_value(T) when is_list(T)      -> maybe_array(T);
encode_value(T) when is_map(T)       -> pack_object(T);
encode_value(T) when is_tuple(T)     -> pack_array(tuple_to_list(T));
encode_value(T) when is_pid(T)       -> quote(pid_to_list(T));
encode_value(T) when is_port(T)      -> quote(port_to_list(T));
encode_value(T) when is_function(T)  -> quote(erlang:fun_to_list(T));
encode_value(T) when is_reference(T) -> quote(ref_to_list(T)).


maybe_string(T) ->
    L = binary_to_list(T),
    true = io_lib:printable_unicode_list(L),
    quote(L).


maybe_array(T) ->
    case io_lib:printable_unicode_list(T) of
        true  -> quote(T);
        false -> pack_array(T)
    end.


quote(T) -> [$" | escape(T)].

escape([])        -> [$"];
escape([$\b | T]) -> [$\\, $b  | escape(T)];
escape([$\f | T]) -> [$\\, $f  | escape(T)];
escape([$\n | T]) -> [$\\, $n  | escape(T)];
escape([$\r | T]) -> [$\\, $r  | escape(T)];
escape([$\t | T]) -> [$\\, $t  | escape(T)];
escape([$\" | T]) -> [$\\, $"  | escape(T)];
escape([$\\ | T]) -> [$\\, $\\ | escape(T)];
escape([H | T])   -> [H | escape(T)].


pack_array([])        -> "[]";
pack_array([H | []])  -> [$[, encode_value(H), $]];
pack_array([H | T])   -> [$[, encode_value(H), $,, encode_array(T), $]].

encode_array([H | []]) -> encode_value(H);
encode_array([H | T])  -> [encode_value(H), $,, encode_array(T)].


pack_object(M) ->
    case maps:to_list(M) of
        [] ->
            "{}";
        [{K, V} | T] when is_list(K) ->
            true = io_lib:printable_unicode_list(K),
            Init = [$", K, $", $:, encode_value(V)],
            [${, lists:foldl(fun pack_object/2, Init, T), $}];
        [{K, V} | T] when is_binary(K) ->
            Key = unicode:characters_to_list(K),
            true = io_lib:printable_unicode_list(Key),
            Init = [$", Key, $", $:, encode_value(V)],
            [${, lists:foldl(fun pack_object/2, Init, T), $}];
        [{K, V} | T] when is_atom(K) ->
            Init = [$", atom_to_list(K), $", $:, encode_value(V)],
            [${, lists:foldl(fun pack_object/2, Init, T), $}]
    end.

pack_object({K, V}, L) when is_list(K) ->
    true = io_lib:printable_unicode_list(K),
    [$", K, $", $:, encode_value(V), $, | L];
pack_object({K, V}, L) when is_binary(K) ->
    Key = unicode:characters_to_list(K),
    true = io_lib:printable_unicode_list(Key),
    [$", Key, $", $:, encode_value(V), $, | L];
pack_object({K, V}, L) when is_float(K) ->
    Key = float_to_list(K),
    [$", Key, $", $:, encode_value(V), $, | L];
pack_object({K, V}, L) when is_integer(K) ->
    Key = integer_to_list(K),
    [$", Key, $", $:, encode_value(V), $, | L];
pack_object({K, V}, L) when is_atom(K) ->
    [$", atom_to_list(K), $", $:, encode_value(V), $, | L].


b_encode_value(true)                   -> <<"true">>;
b_encode_value(false)                  -> <<"false">>;
b_encode_value(undefined)              -> <<"null">>;
b_encode_value(T) when is_atom(T)      -> [$", atom_to_binary(T, utf8), $"];
b_encode_value(T) when is_float(T)     -> float_to_binary(T);
b_encode_value(T) when is_integer(T)   -> integer_to_binary(T);
b_encode_value(T) when is_binary(T)    -> [$", b_maybe_string(T), $"];
b_encode_value(T) when is_list(T)      -> b_pack_array(T);
b_encode_value(T) when is_map(T)       -> b_pack_object(T);
b_encode_value(T) when is_tuple(T)     -> b_pack_array(tuple_to_list(T));
b_encode_value(T) when is_pid(T)       -> [$", list_to_binary(pid_to_list(T)), $"];
b_encode_value(T) when is_port(T)      -> [$", list_to_binary(port_to_list(T)), $"];
b_encode_value(T) when is_function(T)  -> [$", list_to_binary(erlang:fun_to_list(T)), $"];
b_encode_value(T) when is_reference(T) -> [$", list_to_binary(ref_to_list(T)), $"].


b_maybe_string(T) ->
    S = unicode:characters_to_binary(T),
    true = is_binary(S),
    S.


b_pack_array([])       -> "[]";
b_pack_array([H | []]) -> [$[, b_encode_value(H), $]];
b_pack_array([H | T])  -> [$[, b_encode_value(H), $,, b_encode_array(T), $]].

b_encode_array([H | []]) -> b_encode_value(H);
b_encode_array([H | T])  -> [b_encode_value(H), $,, b_encode_array(T)].


b_pack_object(M) ->
    case maps:to_list(M) of
        [] ->
            "{}";
        [{K, V} | T] when is_list(K) ->
            true = io_lib:printable_unicode_list(K),
            Init = [$", K, $", $:, b_encode_value(V)],
            [${, lists:foldl(fun b_pack_object/2, Init, T), $}];
        [{K, V} | T] when is_binary(K) ->
            true = io_lib:printable_unicode_list(unicode:characters_to_list(K)),
            Init = [$", K, $", $:, b_encode_value(V)],
            [${, lists:foldl(fun b_pack_object/2, Init, T), $}];
        [{K, V} | T] when is_atom(K) ->
            Init = [$", atom_to_binary(K, utf8), $", $:, b_encode_value(V)],
            [${, lists:foldl(fun b_pack_object/2, Init, T), $}]
    end.

b_pack_object({K, V}, L) when is_list(K) ->
    true = io_lib:printable_unicode_list(K),
    [$", K, $", $:, b_encode_value(V), $, | L];
b_pack_object({K, V}, L) when is_binary(K) ->
    true = io_lib:printable_unicode_list(unicode:characters_to_list(K)),
    [$", K, $", $:, b_encode_value(V), $, | L];
b_pack_object({K, V}, L) when is_float(K) ->
    Key = float_to_list(K),
    [$", Key, $", $:, b_encode_value(V), $, | L];
b_pack_object({K, V}, L) when is_integer(K) ->
    Key = integer_to_list(K),
    [$", Key, $", $:, b_encode_value(V), $, | L];
b_pack_object({K, V}, L) when is_atom(K) ->
    [$", atom_to_list(K), $", $:, b_encode_value(V), $, | L].


%%% Decode Functions

-spec parse(Stream) -> Result
    when Stream    :: string(),
         Result    :: {ok, value()}
                    | {error, Extracted :: value(), Remaining :: string()}.
%% @private
%% The top-level dispatcher. This packages the top level value (or top-level error)
%% for return to the caller. A very similar function (value/1) is used for inner
%% values.

parse([${ | Rest]) ->
    case object(Rest) of
        {ok, Object, ""}   -> {ok, Object};
        {ok, Object, More} -> polish(Object, seek(More));
        Error              -> Error
    end;
parse([$[ | Rest]) ->
    case array(Rest) of
        {ok, Array, ""}   -> {ok, Array};
        {ok, Array, More} -> polish(Array, seek(More));
        Error             -> Error
    end;
parse([$" | Rest]) ->
    case string(Rest) of
        {ok, String, ""}   -> {ok, String};
        {ok, String, More} -> polish(String, seek(More));
        Error              -> Error
    end;
parse([I | Rest]) when I == $-; $0 =< I, I =< $9 ->
    case number_int(Rest, [I]) of
        {ok, Number, ""}   -> {ok, Number};
        {ok, Number, More} -> polish(Number, seek(More));
        Error              -> Error
    end;
parse("true" ++ More) ->
    polish(true, seek(More));
parse("false" ++ More) ->
    polish(false, seek(More));
parse("null" ++ More) ->
    polish(undefined, seek(More));
parse(Other) ->
    {error, [], Other}.


polish(Value, "")   -> {ok, Value};
polish(Value, More) -> {error, Value, More}.


value([${ | Rest])                               -> object(Rest);
value([$[ | Rest])                               -> array(Rest);
value([$" | Rest])                               -> string(Rest);
value([I | Rest]) when I == $-; $0 =< I, I =< $9 -> number_int(Rest, [I]);
value("true" ++ Rest)                            -> {ok, true, Rest};
value("false" ++ Rest)                           -> {ok, false, Rest};
value("null" ++  Rest)                           -> {ok, undefined, Rest};
value(_)                                         -> error.


object([$} | Rest]) -> {ok, #{}, Rest};
object(String)      -> object(seek(String), #{}).

object([$} | Rest], Map) ->
    {ok, Map, Rest};
object([$" | Rest], Map) ->
    case string(Rest) of
        {ok, Key, Remainder} -> object_value(seek(Remainder), Key, Map);
        {error, _, _}        -> {error, Map, Rest}
    end;
object(Rest, Map) ->
    {error, Map, Rest}.

object_value([$: | Rest], Key, Map) ->
    object_value_parse(seek(Rest), Key, Map);
object_value(Rest, Key, Map) ->
    {error, maps:put(Key, undefined, Map), Rest}.

object_value_parse(String, Key, Map) ->
    case value(String) of
        {ok, Value, Rest}    -> object_next(seek(Rest), maps:put(Key, Value, Map));
        {error, Value, Rest} -> {error, maps:put(Key, Value, Map), Rest};
        error                -> {error, Map, String}
    end.


object_next([$, | Rest], Map) -> object(seek(Rest), Map);
object_next([$} | Rest], Map) -> {ok, Map, seek(Rest)};
object_next(Rest, Map)        -> {error, Map, Rest}.


array([$] | Rest]) -> {ok, [], Rest};
array(String)      -> array(seek(String), []).

array([$] | Rest], List) ->
    {ok, lists:reverse(List), seek(Rest)};
array(String, List) ->
    case value(String) of
        {ok, Value, Rest}    -> array_next(seek(Rest), [Value | List]);
        {error, Value, Rest} -> {error, lists:reverse([Value | List]), Rest};
        error                -> {error, lists:reverse(List), String}
    end.

array_next([$, | Rest], List) -> array(seek(Rest), List);
array_next([$] | Rest], List) -> {ok, lists:reverse(List), seek(Rest)};
array_next(Rest, List)        -> {error, lists:reverse(List), Rest}.


string(Stream) -> string(Stream, "").

string([$" | Rest], String) ->
    {ok, lists:reverse(String), Rest};
string([$\\, $" | Rest], String) ->
    string(Rest, [$" | String]);
string([$\\, $\\ | Rest], String) ->
    string(Rest, [$\\ | String]);
string([$\\, $b | Rest], String) ->
    string(Rest, [?BKSPC | String]);
string([$\\, $t | Rest], String) ->
    string(Rest, [?H_TAB | String]);
string([$\\, $n | Rest], String) ->
    string(Rest, [?NEW_L | String]);
string([$\\, $f | Rest], String) ->
    string(Rest, [?FORMF | String]);
string([$\\, $r | Rest], String) ->
    string(Rest, [?CAR_R | String]);
string([$\\, $u, A, B, C, D | Rest], String)
    when (($0 =< A andalso A =< $9) or ($A =< A andalso A =< $F) or ($a =< A andalso A =< $f))
     and (($0 =< B andalso B =< $9) or ($A =< B andalso B =< $F) or ($a =< B andalso B =< $f))
     and (($0 =< C andalso C =< $9) or ($A =< C andalso C =< $F) or ($a =< C andalso C =< $f))
     and (($0 =< D andalso D =< $9) or ($A =< D andalso D =< $F) or ($a =< D andalso D =< $f)) ->
    Char = list_to_integer([A, B, C, D], 16),
    string(Rest, [Char | String]);
string(Stream = [$\\, $u | _], String) ->
    {error, String, Stream};
string([$\\, Char | Rest], String)
        when Char == 16#20;
             Char == 16#21;
             16#23 =< Char, Char =< 16#5B;
             16#5D =< Char, Char =< 16#10FFFF ->
    string(Rest, [$\\, Char | String]);
string([Char | Rest], String)
        when Char == 16#20;
             Char == 16#21;
             16#23 =< Char, Char =< 16#5B;
             16#5D =< Char, Char =< 16#10FFFF ->
    string(Rest, [Char | String]);
string(Rest, String) ->
    {error, lists:reverse(String), Rest}.


number_int([$. | Rest], String) ->
    number_float(Rest, [$. | String]);
number_int([$e, Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char, $+, $e, $0, $. | String]);
number_int([$E, Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char, $+, $e, $0, $. | String]);
number_int([$e, $+, Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char, $+, $e, $0, $. | String]);
number_int([$E, $+, Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char, $+, $e, $0, $. | String]);
number_int([$e, $-, Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char, $-, $e, $0, $. | String]);
number_int([$E, $-, Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char, $-, $e, $0, $. | String]);
number_int([Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_int(Rest, [Char | String]);
number_int(Rest, "-") ->
    {error, "", [$- | Rest]};
number_int(Rest, String) ->
    {ok, list_to_integer(lists:reverse(String)), seek(Rest)}.

number_float([Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float(Rest, [Char | String]);
number_float([$E, Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char, $+, $e | String]);
number_float([$e, Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char, $+, $e | String]);
number_float([$E, $+, Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char, $+, $e | String]);
number_float([$e, $+, Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char, $+, $e | String]);
number_float([$E, $-, Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char, $-, $e | String]);
number_float([$e, $-, Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char, $-, $e | String]);
number_float(Rest, String) ->
    Target = lists:reverse(String),
    try
        Number = list_to_float(Target),
        {ok, Number, seek(Rest)}
    catch
        error:badarg -> {error, "", Target ++ Rest}
    end.


number_float_exp([Char | Rest], String) when $0 =< Char, Char =< $9 ->
    number_float_exp(Rest, [Char | String]);
number_float_exp(Rest, String) ->
    Target = lists:reverse(String),
    try
        Number = list_to_float(Target),
        {ok, Number, seek(Rest)}
    catch
        error:badarg -> {error, "", Target ++ Rest}
    end.


seek([?H_TAB | Rest]) -> seek(Rest);
seek([?NEW_L | Rest]) -> seek(Rest);
seek([?CAR_R | Rest]) -> seek(Rest);
seek([?SPACE | Rest]) -> seek(Rest);
seek(String)          -> String.


b_decode(Stream) ->
    case unicode:characters_to_list(Stream) of
        E when is_tuple(E) -> E;
        [16#FEFF | String] -> binary_parse(seek(String));
        String             -> binary_parse(seek(String))
    end.

-spec binary_parse(Stream) -> Result
    when Stream    :: string(),
         Result    :: {ok, bin_value()}
                    | {error, Extracted :: bin_value(), Remaining :: binary()}.
%% @private
%% The top-level dispatcher. This packages the top level value (or top-level error)
%% for return to the caller. A very similar function (b_value/1) is used for inner
%% values.

binary_parse([${ | Rest]) ->
    case b_object(Rest) of
        {ok, Object, ""}   -> {ok, Object};
        {ok, Object, More} -> b_polish(Object, seek(More));
        Error              -> Error
    end;
binary_parse([$[ | Rest]) ->
    case b_array(Rest) of
        {ok, Array, ""}   -> {ok, Array};
        {ok, Array, More} -> b_polish(Array, seek(More));
        Error             -> Error
    end;
binary_parse([$" | Rest]) ->
    case string(Rest) of
        {ok, String, ""} ->
            case unicode:characters_to_binary(String) of
                E when is_tuple(E) -> E;
                Result             -> {ok, Result}
            end;
        {ok, String, More} ->
            case unicode:characters_to_binary(String) of
                E when is_tuple(E) -> E;
                Result             -> b_polish(Result, seek(More))
            end;
        Error ->
            Error
    end;
binary_parse([I | Rest]) when I == $-; $0 =< I, I =< $9 ->
    case number_int(Rest, [I]) of
        {ok, Number, ""}   -> {ok, Number};
        {ok, Number, More} -> b_polish(Number, seek(More));
        Error              -> Error
    end;
binary_parse("true" ++ More) ->
    b_polish(true, seek(More));
binary_parse("false" ++ More) ->
    b_polish(false, seek(More));
binary_parse("null" ++ More) ->
    b_polish(undefined, seek(More));
binary_parse(Other) ->
    {error, [], Other}.


b_polish(Value, "")   -> {ok, Value};
b_polish(Value, More) -> {error, Value, More}.


b_value([${ | Rest])                               -> b_object(Rest);
b_value([$[ | Rest])                               -> b_array(Rest);
b_value([$" | Rest])                               -> b_string(Rest);
b_value([I | Rest]) when I == $-; $0 =< I, I =< $9 -> number_int(Rest, [I]);
b_value("true" ++ Rest)                            -> {ok, true, Rest};
b_value("false" ++ Rest)                           -> {ok, false, Rest};
b_value("null" ++  Rest)                           -> {ok, undefined, Rest};
b_value(_)                                         -> error.


b_string(Stream) ->
    case string(Stream) of
        {ok, String, More} ->
            case unicode:characters_to_binary(String) of
                E when is_tuple(E) -> E;
                Result             -> {ok, Result, More}
            end;
        Error  -> Error
    end.


b_object([$} | Rest]) -> {ok, #{}, Rest};
b_object(String)      -> b_object(seek(String), #{}).

b_object([$} | Rest], Map) ->
    {ok, Map, Rest};
b_object([$" | Rest], Map) ->
    case string(Rest) of
        {ok, Key, Remainder} ->
            b_object_value(seek(Remainder), unicode:characters_to_binary(Key), Map);
        {error, _, _} ->
            {error, Map, Rest}
    end;
b_object(Rest, Map) ->
    {error, Map, Rest}.

b_object_value([$: | Rest], Key, Map) -> b_object_value_parse(seek(Rest), Key, Map);
b_object_value(Rest, Key, Map)        -> {error, maps:put(Key, undefined, Map), Rest}.

b_object_value_parse(String, Key, Map) ->
    case b_value(String) of
        {ok, Value, Rest}    -> b_object_next(seek(Rest), maps:put(Key, Value, Map));
        {error, Value, Rest} -> {error, maps:put(Key, Value, Map), Rest};
        error                -> {error, Map, String}
    end.


b_object_next([$, | Rest], Map) -> b_object(seek(Rest), Map);
b_object_next([$} | Rest], Map) -> {ok, Map, seek(Rest)};
b_object_next(Rest, Map)        -> {error, Map, Rest}.


b_array([$] | Rest]) -> {ok, [], Rest};
b_array(String)      -> b_array(seek(String), []).

b_array([$] | Rest], List) ->
    {ok, lists:reverse(List), seek(Rest)};
b_array(String, List) ->
    case b_value(String) of
        {ok, Value, Rest}    -> b_array_next(seek(Rest), [Value | List]);
        {error, Value, Rest} -> {error, lists:reverse([Value | List]), Rest};
        error                -> {error, lists:reverse(List), String}
    end.

b_array_next([$, | Rest], List) -> b_array(seek(Rest), List);
b_array_next([$] | Rest], List) -> {ok, lists:reverse(List), seek(Rest)};
b_array_next(Rest, List)        -> {error, lists:reverse(List), Rest}.
