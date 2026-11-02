-module(ecai_eval_worker).
-behaviour(gen_server).
-export([start_link/3, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
start_link(Parent, Token, Work) -> gen_server:start_link(?MODULE, {Parent, Token, Work}, []).
init(S) ->
    process_flag(max_heap_size, #{size => 16000000, kill => true, error_logger => false}),
    self() ! execute, {ok, S}.
handle_call(_, _, S) -> {reply, {error, unsupported}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(execute, {Parent, Token, Work} = S) ->
    Start = erlang:monotonic_time(millisecond),
    Result = try execute(Work) catch
        throw:{eval_error, Why} -> #{<<"state">> => <<"error">>, <<"reason">> => ecai_eval_util:bin(Why)};
        _:_ -> #{<<"state">> => <<"error">>, <<"reason">> => <<"evaluator_exception">>}
    end,
    Parent ! {eval_result, self(), Token, Result#{<<"latency_ms">> => erlang:monotonic_time(millisecond)-Start}},
    {stop, normal, S};
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.
execute(#{suite := Suite, 'case' := Case, target := Target, config := Config, node_policy := Node}) ->
    {Messages, Ids} = ecai_eval_knowledge:prompt(Case, Suite, Config),
    Base = #{<<"messages">> => Messages, <<"retrieved_ids">> => Ids,
             <<"effective_config">> => Config, <<"execution_policy">> => Node},
    case ecai_eval_provider:call(Target, Messages, Config, Node) of
        {ok, Text, Meta} ->
            Grade = ecai_eval_grader:grade(Case, Text, Suite),
            Base#{<<"state">> => <<"done">>, <<"response">> => Text,
                  <<"provider_meta">> => Meta, <<"grade">> => Grade};
        {error, Why} -> Base#{<<"state">> => <<"error">>, <<"reason">> => ecai_eval_util:bin(Why)}
    end.
