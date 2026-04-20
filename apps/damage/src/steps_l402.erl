%% -------------------------------------------------------------------
%% steps_l402.erl - DamageBDD steps for L402 end-to-end testing
%% -------------------------------------------------------------------
-module(steps_l402).

-include_lib("kernel/include/logger.hrl").

-export([step/6]).

%% You may want to align these keys with your existing steps_http storage.
-define(CTX_HEADERS, response_headers).
-define(CTX_STATUS, response_status).
-define(CTX_BODY, response_body).

%% erlfmt:ignore-begin
-define(STEP_RESPONSE_STORE_L402_INVOICE, ["I store the L","402","invoice in", Variable]). %TODO fix parser
-define(STEP_RESPONSE_STORE_L402_INVOICE0, ["I store the L402 invoice in", Variable]).
-define(STEP_RESPONSE_STORE_L402_MACAROON, ["I store the L", "402", "macaroon in", Variable]).
-define(STEP_RESPONSE_STORE_L402_MACAROON0, ["I store the 402 macaroon in", Variable]).
%% erlfmt:ignore-end

%% -------------------------------------------------------------------
%% Step dispatcher
%% -------------------------------------------------------------------
step(
    _Config,
    Context0,
    <<"Then">>,
    _N,
    ["I store L402 challenge macaroon in", MacVar, "and invoice in", InvVar],
    _Body
) ->
    case l402_extract_from_context(Context0) of
        {ok, Mac, Invoice} ->
            maps:put(
                InvVar,
                Invoice,
                maps:put(MacVar, Mac, Context0)
            );
        {error, Why} ->
            maps:put(fail, fail_msg("Cannot extract L402 challenge: ~p", [Why]), Context0)
    end;
step(
    _Config,
    Context0,
    <<"When">>,
    _N,
    ["I pay the L402 invoice", InvoiceTpl, "via CLN and store preimage in", PreVar],
    _Body
) ->
    Invoice = resolve_var(Context0, InvoiceTpl),
    case cln_pay_invoice(Invoice) of
        {ok, PreimageHex} ->
            maps:put(PreVar, PreimageHex, Context0);
        {error, Why} ->
            maps:put(fail, fail_msg("CLN pay failed: ~p", [Why]), Context0)
    end;
step(
    _Config,
    Context0,
    <<"When">>,
    _N,
    ["I set L402 Authorization header using macaroon", MacTpl, "and preimage", PreTpl],
    _Body
) ->
    Mac = resolve_var(Context0, MacTpl),
    Pre = resolve_var(Context0, PreTpl),
    Auth = iolist_to_binary(["L402 ", Mac, ":", Pre]),
    set_header(Context0, <<"authorization">>, Auth);
%%------------------------------------------------------------------------------
%% THEN/AND: Store invoice from WWW-Authenticate: L402 ...
%% Example:
%%   And I store the L402 invoice in "invoice_bolt11"
%%------------------------------------------------------------------------------
step(
    _Config,
    Context,
    _,
    _N,
    ?STEP_RESPONSE_STORE_L402_INVOICE,
    _
) ->
    store_l402_field(invoice, Variable, Context);
step(
    _Config,
    Context,
    _,
    _N,
    ?STEP_RESPONSE_STORE_L402_INVOICE0,
    _
) ->
    store_l402_field(invoice, Variable, Context);
%%------------------------------------------------------------------------------
%% THEN/AND: Store macaroon from WWW-Authenticate: L402 ...
%% Example:
%%   And I store the L402 macaroon in "macaroon"
%%------------------------------------------------------------------------------
step(
    _Config,
    Context,
    _,
    _N,
    ?STEP_RESPONSE_STORE_L402_MACAROON,
    _
) ->
    store_l402_field(macaroon, Variable, Context);
step(
    _Config,
    Context,
    _,
    _N,
    ?STEP_RESPONSE_STORE_L402_MACAROON0,
    _
) ->
    store_l402_field(macaroon, Variable, Context).

store_l402_field(Field, Variable, Context) ->
    case maps:get(response, Context, undefined) of
        [{status_code, _}, {headers, Headers}, {body, _}] ->
            case get_header_value(<<"www-authenticate">>, Headers) of
                undefined ->
                    maps:put(
                        fail,
                        <<"www-authenticate header not found in response">>,
                        Context
                    );
                AuthHeader ->
                    case parse_l402_header(AuthHeader) of
                        #{Field := Value} ->
                            maps:put(list_to_atom(Variable), Value, Context);
                        Parsed ->
                            maps:put(
                                fail,
                                damage_utils:strf("L402 field ~p not found in header ~p", [
                                    Field, Parsed
                                ]),
                                Context
                            )
                    end
            end;
        Unexpected ->
            maps:put(
                fail,
                damage_utils:strf("Unexpected response format ~p", [Unexpected]),
                Context
            )
    end.

get_header_value(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {Name, Value} ->
            Value;
        false ->
            undefined
    end.

parse_l402_header(Value) when is_list(Value) ->
    parse_l402_header(list_to_binary(Value));
parse_l402_header(<<"L402 ", Rest/binary>>) ->
    parse_l402_kv_pairs(Rest);
parse_l402_header(Rest) when is_binary(Rest) ->
    parse_l402_kv_pairs(Rest).

parse_l402_kv_pairs(Bin) ->
    Parts = [trim_ws(P) || P <- binary:split(Bin, <<",">>, [global])],
    lists:foldl(fun parse_l402_part/2, #{}, Parts).

parse_l402_part(Part, Acc) ->
    case binary:split(Part, <<"=">>) of
        [Key, RawValue] ->
            Key0 = trim_ws(Key),
            Value0 = trim_quotes(trim_ws(RawValue)),
            maps:put(binary_to_existing_atom_safe(Key0), Value0, Acc);
        _ ->
            Acc
    end.

trim_ws(B) when is_binary(B) ->
    list_to_binary(string:trim(binary_to_list(B), both, " \t\r\n"));
trim_ws(L) when is_list(L) ->
    list_to_binary(string:trim(L, both, " \t\r\n")).

trim_quotes(Bin0) ->
    Bin = trim_ws(Bin0),
    case Bin of
        <<"\"", Rest/binary>> when byte_size(Rest) > 0 ->
            case Rest of
                <<Inner:(byte_size(Rest) - 1)/binary, "\"">> -> Inner;
                _ -> Rest
            end;
        _ ->
            Bin
    end.

binary_to_existing_atom_safe(<<"invoice">>) -> invoice;
binary_to_existing_atom_safe(<<"macaroon">>) -> macaroon;
binary_to_existing_atom_safe(Other) -> Other.
%% -------------------------------------------------------------------
%% Extract L402 WWW-Authenticate challenge from last response
%% -------------------------------------------------------------------
l402_extract_from_context(Context) ->
    Status = maps:get(?CTX_STATUS, Context, undefined),
    Headers0 = maps:get(?CTX_HEADERS, Context, #{}),
    Headers = normalize_headers(Headers0),
    case Status of
        402 ->
            case maps:get(<<"www-authenticate">>, Headers, undefined) of
                undefined ->
                    {error, no_www_authenticate};
                Val ->
                    l402_parse_www_authenticate(Val)
            end;
        _ ->
            {error, {unexpected_status, Status}}
    end.

normalize_headers(H) when is_map(H) ->
    %% Ensure all header keys are lowercase binaries
    maps:from_list([{lower_bin(K), to_bin(V)} || {K, V} <- maps:to_list(H)]);
normalize_headers(L) when is_list(L) ->
    %% Sometimes headers are stored as proplist
    maps:from_list([{lower_bin(K), to_bin(V)} || {K, V} <- L]);
normalize_headers(_) ->
    #{}.

lower_bin(B) when is_binary(B) -> string:lowercase(B);
lower_bin(L) when is_list(L) -> string:lowercase(list_to_binary(L));
lower_bin(A) when is_atom(A) -> string:lowercase(atom_to_binary(A, utf8)).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

%% Parse: L402 macaroon="...", invoice="..."
l402_parse_www_authenticate(Val0) ->
    Val = trim(to_bin(Val0)),
    case Val of
        <<"L402 ", Rest/binary>> ->
            Mac = l402_kv(Rest, <<"macaroon">>),
            Inv = l402_kv(Rest, <<"invoice">>),
            case {Mac, Inv} of
                {undefined, _} -> {error, no_macaroon};
                {_, undefined} -> {error, no_invoice};
                _ -> {ok, Mac, Inv}
            end;
        _ ->
            {error, not_l402}
    end.

l402_kv(Rest, Key) ->
    %% Very small parser that finds: key="...".
    %% Works even with additional params and commas.
    Pat = iolist_to_binary([Key, <<"=\"">>]),
    case binary:match(Rest, Pat) of
        nomatch ->
            undefined;
        {Pos, _Len} ->
            Start = Pos + byte_size(Pat),
            case binary:match(Rest, <<"\"">>, [{scope, {Start, byte_size(Rest) - Start}}]) of
                nomatch ->
                    undefined;
                {EndPos, _} ->
                    binary:part(Rest, Start, EndPos - Start)
            end
    end.

trim(B) ->
    trim_right(trim_left(B)).

trim_left(B) ->
    case B of
        <<C, Rest/binary>> when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
            trim_left(Rest);
        _ ->
            B
    end.

trim_right(B) ->
    case B of
        <<>> ->
            <<>>;
        _ ->
            Last = binary:last(B),
            case Last of
                C when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
                    trim_right(binary:part(B, 0, byte_size(B) - 1));
                _ ->
                    B
            end
    end.

%% -------------------------------------------------------------------
%% Set header for subsequent HTTP steps
%% -------------------------------------------------------------------
set_header(Context0, HeaderName, Value) ->
    %% Many DamageBDD http steps store request headers in context.
    %% Common patterns:
    %%  - request_headers => #{<<"k">> => <<"v">>}
    %%  - headers => #{...}
    %%
    %% We write both to be safe; your steps_http can just pick one.
    H0 = maps:get(request_headers, Context0, #{}),
    H1 = maps:put(lower_bin(HeaderName), Value, normalize_headers(H0)),
    maps:put(
        headers,
        H1,
        maps:put(request_headers, H1, Context0)
    ).

%% -------------------------------------------------------------------
%% Resolve template variables like "{{var}}"
%% -------------------------------------------------------------------
resolve_var(Context, Bin0) ->
    Bin = to_bin(Bin0),
    case Bin of
        <<"{{", Inner/binary>> ->
            case binary:split(Inner, <<"}}">>, [global]) of
                [Var, _Rest] ->
                    maps:get(
                        binary_to_list(Var),
                        Context,
                        maps:get(Var, Context, Bin)
                    );
                _ ->
                    Bin
            end;
        _ ->
            Bin
    end.

%% -------------------------------------------------------------------
%% Pay invoice via CLN and return preimage hex
%% -------------------------------------------------------------------
cln_pay_invoice(Bolt11) when is_binary(Bolt11) ->
    %% We try common function names to avoid coupling.
    %% Pin this to your actual cln.erl export once confirmed.
    try_call_pay(Bolt11, [
        {cln, pay_invoice, 1},
        {cln, pay, 1},
        {cln, pay_bolt11, 1},
        %% maybe needs options
        {cln, pay_invoice, 2}
    ]).

try_call_pay(_Bolt11, []) ->
    {error, no_cln_pay_function};
try_call_pay(Bolt11, [{M, F, 1} | Rest]) ->
    case erlang:function_exported(M, F, 1) of
        true ->
            try
                Res = apply(M, F, [Bolt11]),
                extract_preimage_hex(Res)
            catch
                _:E ->
                    {error, {pay_failed, {M, F, 1}, E}}
            end;
        false ->
            try_call_pay(Bolt11, Rest)
    end;
try_call_pay(Bolt11, [{M, F, 2} | Rest]) ->
    case erlang:function_exported(M, F, 2) of
        true ->
            try
                %% Empty opts map by default
                Res = apply(M, F, [Bolt11, #{}]),
                extract_preimage_hex(Res)
            catch
                _:E ->
                    {error, {pay_failed, {M, F, 2}, E}}
            end;
        false ->
            try_call_pay(Bolt11, Rest)
    end.

extract_preimage_hex({ok, Map}) when is_map(Map) ->
    extract_preimage_hex(Map);
extract_preimage_hex(Map) when is_map(Map) ->
    %% Common keys: preimage, payment_preimage, <<"preimage">>, <<"payment_preimage">>
    case
        pick_first(Map, [
            preimage, payment_preimage, <<"preimage">>, <<"payment_preimage">>
        ])
    of
        undefined ->
            %% Some CLN pay responses put it nested under "payment"
            case maps:get(payment, Map, maps:get(<<"payment">>, Map, undefined)) of
                P when is_map(P) ->
                    case
                        pick_first(P, [
                            preimage, payment_preimage, <<"preimage">>, <<"payment_preimage">>
                        ])
                    of
                        undefined -> {error, no_preimage_in_response};
                        V -> {ok, normalize_preimage(V)}
                    end;
                _ ->
                    {error, no_preimage_in_response}
            end;
        V ->
            {ok, normalize_preimage(V)}
    end;
extract_preimage_hex(Other) ->
    {error, {unexpected_pay_result, Other}}.

pick_first(Map, [K | Ks]) ->
    case maps:get(K, Map, undefined) of
        undefined -> pick_first(Map, Ks);
        V -> V
    end;
pick_first(_Map, []) ->
    undefined.

normalize_preimage(V) ->
    %% Expect hex string for L402 Authorization header.
    %% If binary is 32 bytes, encode to hex.
    Bin = to_bin(V),
    case byte_size(Bin) of
        32 ->
            binary:encode_hex(Bin);
        _ ->
            %% assume already hex
            string:lowercase(Bin)
    end.

fail_msg(Fmt, Args) ->
    iolist_to_binary(io_lib:format(Fmt, Args)).
