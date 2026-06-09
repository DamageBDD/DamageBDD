-module(erm_pay_nwc).

-export([request/4]).

request(NwcUri, Method0, Params, Timeout) ->
    Method = method_bin(Method0),
    case code:ensure_loaded(damage_nwc_client) of
        {module, damage_nwc_client} ->
            call_damage_nwc(NwcUri, Method, Params, Timeout);
        _ ->
            {error, #{
                code => missing_adapter,
                message => <<"damage_nwc_client is not loaded">>
            }}
    end.

call_damage_nwc(NwcUri, Method, Params, Timeout) ->
    case erlang:function_exported(damage_nwc_client, request, 4) of
        true ->
            safe(fun() ->
                damage_nwc_client:request(NwcUri, Method, Params, Timeout)
            end);
        false ->
            call_specific(NwcUri, Method, Params, Timeout)
    end.

call_specific(NwcUri, <<"pay_invoice">>, Params, Timeout) ->
    case erlang:function_exported(damage_nwc_client, pay_invoice, 4) of
        true ->
            Invoice = map_get(<<"invoice">>, invoice, Params, undefined),
            Metadata = map_get(<<"metadata">>, metadata, Params, #{}),
            safe(fun() ->
                damage_nwc_client:pay_invoice(NwcUri, Invoice, Metadata, Timeout)
            end);
        false ->
            missing_request_fun(<<"pay_invoice">>)
    end;
call_specific(NwcUri, <<"get_balance">>, _Params, Timeout) ->
    case erlang:function_exported(damage_nwc_client, get_balance, 2) of
        true ->
            safe(fun() ->
                damage_nwc_client:get_balance(NwcUri, Timeout)
            end);
        false ->
            missing_request_fun(<<"get_balance">>)
    end;
call_specific(_NwcUri, Method, _Params, _Timeout) ->
    missing_request_fun(Method).

missing_request_fun(Method) ->
    {error, #{
        code => missing_adapter_function,
        method => Method,
        message => <<"Export damage_nwc_client:request/4 or a method-specific wrapper">>
    }}.

safe(Fun) ->
    try Fun() of
        Reply ->
            normalize(Reply)
    catch
        Class:Reason:Stacktrace ->
            {error, #{
                code => adapter_crash,
                class => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }}
    end.

normalize({ok, #{<<"error">> := null, <<"result">> := Result}}) ->
    {ok, Result};
normalize({ok, #{error := null, result := Result}}) ->
    {ok, Result};
normalize({ok, #{<<"error">> := Error}}) when Error =/= null ->
    {error, Error};
normalize({ok, #{error := Error}}) when Error =/= null ->
    {error, Error};
normalize({ok, Result}) ->
    {ok, Result};
normalize({error, _} = Error) ->
    Error;
normalize(Other) ->
    {ok, Other}.

method_bin(Method) when is_binary(Method) ->
    Method;
method_bin(Method) when is_atom(Method) ->
    atom_to_binary(Method, utf8);
method_bin(Method) when is_list(Method) ->
    unicode:characters_to_binary(Method).

map_get(BinKey, AtomKey, Map, Default) ->
    case maps:find(BinKey, Map) of
        {ok, V} ->
            V;
        error ->
            maps:get(AtomKey, Map, Default)
    end.
