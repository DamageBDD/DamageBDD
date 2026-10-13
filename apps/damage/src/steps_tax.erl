%% Offline tax evidence verification steps (no live CLN or market API).
-module(steps_tax).
-export([step/6, step_dry/6]).

-define(GIVEN_INVOICE, [
    "a settled CLN invoice of",
    Amount,
    "millisatoshis at Unix time",
    At
]).
-define(WHEN_NORMALISE, ["I normalise the settled invoice as tax evidence"]).
-define(THEN_UNCLASSIFIED, ["the tax event must require manual classification"]).
-define(THEN_AMOUNT, ["the tax event amount must be", Expected, "millisatoshis"]).
-define(THEN_HASHED, ["the tax event must have source provenance"]).

step_dry(Config, Context, Keyword, LineNo, Body, Args) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args).

step(_Config, Context, <<"Given">>, _Line, ?GIVEN_INVOICE, _Body) ->
    try
        AmountInt = list_to_integer(Amount),
        AtInt = list_to_integer(At),
        true = AmountInt > 0 andalso AtInt > 0,
        Hash = damage_tax_canonical:sha256_hex([Amount, <<":">>, At]),
        Invoice = #{
            status => paid,
            amount_received_msat => AmountInt,
            payment_hash => Hash,
            paid_at => AtInt
        },
        Context#{tax_test_invoice => Invoice}
    catch
        _:_ -> Context#{fail => <<"invalid offline tax invoice fixture">>}
    end;
step(_Config, Context, <<"When">>, _Line, ?WHEN_NORMALISE, _Body) ->
    Tenant = maps:get(public_key, Context, <<"test_tenant">>),
    case maps:get(tax_test_invoice, Context, undefined) of
        undefined ->
            Context#{fail => <<"no tax invoice fixture">>};
        Invoice ->
            case damage_tax_event:from_cln_invoice(Tenant, Invoice) of
                {ok, [Event]} ->
                    Context#{tax_test_event => Event};
                Other ->
                    Context#{
                        fail =>
                            iolist_to_binary(io_lib:format("tax normalisation failed: ~p", [Other]))
                    }
            end
    end;
step(_Config, Context, _Keyword, _Line, ?THEN_UNCLASSIFIED, _Body) ->
    assert(
        Context,
        fun(E) ->
            maps:get(<<"default_classification">>, E) =:= <<"review">>
        end,
        <<"tax event was classified without approval">>
    );
step(_Config, Context, _Keyword, _Line, ?THEN_AMOUNT, _Body) ->
    assert(
        Context,
        fun(E) ->
            maps:get(<<"amount_atomic">>, E) =:= list_to_integer(Expected)
        end,
        <<"wrong tax event amount">>
    );
step(_Config, Context, _Keyword, _Line, ?THEN_HASHED, _Body) ->
    assert(
        Context,
        fun(E) ->
            byte_size(maps:get(<<"source_sha256">>, E)) =:= 64
        end,
        <<"missing source hash">>
    ).

assert(Context, Fun, Fail) ->
    case maps:get(tax_test_event, Context, undefined) of
        E when is_map(E) ->
            try
                case Fun(E) of
                    true -> Context;
                    false -> Context#{fail => Fail}
                end
            catch
                _:_ -> Context#{fail => Fail}
            end;
        _ ->
            Context#{fail => <<"tax event has not been normalised">>}
    end.
