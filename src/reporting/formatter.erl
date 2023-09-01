-module(formatter).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export(
  [
    start_test/2,
    end_test/3,
    step/3,
    attach/3,
    generate_report/1,
    add_formatter/2
  ]
).

-record(state, {formatters = [], test_state = []}).

start_test(Name, Description) ->
  State = #state{},
  {
    State,
    fun
      (Formatter) -> allure_formatter:start_test(Formatter, Name, Description)
    end
  }.


end_test({State, TestFn}, Name, Status) ->
  NewTestState =
    lists:map(
      fun (Fn) -> Fn(end_test, Name, Status) end,
      State#state.test_state
    ),
  NewState = State#state{test_state = NewTestState},
  {NewState, TestFn}.


step({State, TestFn}, Name, Status) ->
  NewTestState =
    lists:map(fun (Fn) -> Fn(step, Name, Status) end, State#state.test_state),
  NewState = State#state{test_state = NewTestState},
  {NewState, TestFn}.


attach({State, TestFn}, AttachmentType, File) ->
  NewTestState =
    lists:map(
      fun (Fn) -> Fn(attach, AttachmentType, File) end,
      State#state.test_state
    ),
  NewState = State#state{test_state = NewTestState},
  {NewState, TestFn}.


generate_report({State, _TestFn}) ->
  Formatters = State#state.formatters,
  lists:foreach(
    fun (Formatter) -> allure_log_formatter:generate_report(Formatter) end,
    Formatters
  ).


add_formatter({State, TestFn}, Formatter) ->
  NewFormatters = [Formatter | State#state.formatters],
  NewState = State#state{formatters = NewFormatters},
  {NewState, TestFn}.
