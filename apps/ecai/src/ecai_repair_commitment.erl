-module(ecai_repair_commitment).

%% Binds a repair capsule to the native ECAI point-mapping API when one is
%% available. The SHA-256 commitment remains the portable verification floor.
-export([create/1, verify/2]).

-spec create(binary()) -> map().
create(CapsuleId) when is_binary(CapsuleId) ->
    Base = #{scheme => <<"sha256">>, digest => CapsuleId},
    case native_commitment(CapsuleId) of
        {ok, Module, Function, PointBin} ->
            Base#{
                native => #{
                    module => Module,
                    function => Function,
                    encoding => <<"erlang-term-base64">>,
                    point => PointBin
                }
            };
        unavailable ->
            Base
    end.

-spec verify(binary(), map()) -> ok | {error, term()}.
verify(CapsuleId, #{digest := CapsuleId} = Commitment) ->
    case maps:get(native, Commitment, undefined) of
        undefined ->
            ok;
        #{module := Module, function := Function, point := Expected} ->
            case call_native(Module, Function, CapsuleId) of
                {ok, Expected} -> ok;
                {ok, Actual} -> {error, {native_commitment_mismatch, Expected, Actual}};
                unavailable -> ok
            end;
        _ ->
            {error, invalid_native_commitment}
    end;
verify(CapsuleId, #{digest := Other}) ->
    {error, {commitment_digest_mismatch, CapsuleId, Other}};
verify(_CapsuleId, _Commitment) ->
    {error, invalid_commitment}.

native_commitment(CapsuleId) ->
    Candidates = [
        {ecai, hash_to_point},
        {ecai, hash_to_curve},
        {ecai, map_to_point},
        {ecai, knowledge_point}
    ],
    native_commitment(Candidates, CapsuleId).

native_commitment([{Module, Function} | Rest], CapsuleId) ->
    case call_native(Module, Function, CapsuleId) of
        {ok, PointBin} -> {ok, Module, Function, PointBin};
        unavailable -> native_commitment(Rest, CapsuleId)
    end;
native_commitment([], _CapsuleId) ->
    unavailable.

call_native(Module, Function, CapsuleId) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, Function, 1) of
                true ->
                    try
                        case apply(Module, Function, [CapsuleId]) of
                            {error, _} -> unavailable;
                            Point -> {ok, base64:encode(term_to_binary(Point, [compressed]))}
                        end
                    catch
                        _:_ -> unavailable
                    end;
                false ->
                    unavailable
            end;
        _ ->
            unavailable
    end.
