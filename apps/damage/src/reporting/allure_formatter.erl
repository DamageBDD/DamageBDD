-module(allure_formatter).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([start_test/2, end_test/3, step/3, attach/3, generate_report/1]).

-record(test, {name, status}).
-record(step, {name, status}).
-record(state, {tests = [], steps = []}).

start_test(Name, _Description) ->
  State = #state{},
  TimestampStr = datestring:format("Y-m-d", erlang:localtime()),
  Test = #test{name = Name, status = "running"},
  State = #state{tests = [Test | State#state.tests]},
  {State, TimestampStr}.


end_test({State, TimestampStr}, Name, Status) ->
  Test = #test{name = Name, status = Status},
  NewState = State#state{tests = [Test | tl(State#state.tests)]},
  {NewState, TimestampStr}.


step({State, TimestampStr}, Name, Status) ->
  Step = #step{name = Name, status = Status},
  NewState = State#state{steps = [Step | State#state.steps]},
  {NewState, TimestampStr}.


attach({State, TimestampStr}, _AttachmentType, _File) -> {State, TimestampStr}.

generate_report(State) ->
  Header = "<allure>",
  Footer = "</allure>",
  TestsXml = generate_tests_xml(State#state.tests),
  StepsXml = generate_steps_xml(State#state.steps),
  Report = Header ++ TestsXml ++ StepsXml ++ Footer,
  Report.


generate_tests_xml(Tests) ->
  lists:foldl(
    fun
      (Test, Acc) ->
        TestXml =
          io_lib:format(
            "<test name=\"~s\" status=\"~s\"/>\n",
            [Test#test.name, Test#test.status]
          ),
        Acc ++ TestXml
    end,
    "",
    Tests
  ).


generate_steps_xml(Steps) ->
  lists:foldl(
    fun
      (Step, Acc) ->
        StepXml =
          io_lib:format(
            "<step name=\"~s\" status=\"~s\"/>\n",
            [Step#step.name, Step#step.status]
          ),
        Acc ++ StepXml
    end,
    "",
    Steps
  ).
