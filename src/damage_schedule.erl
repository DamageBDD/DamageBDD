-module(damage_schedule).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2]).
-export([execute_bdd/1]).
-export([do_schedule/3]).
-export([do_schedule/5]).
-export([do_schedule/6]).
-export([load_schedules/0]).

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
  {
    [
      {{<<"text">>, <<"html">>, '*'}, to_html},
      {{<<"application">>, <<"json">>, []}, to_json},
      {{<<"text">>, <<"plain">>, '*'}, to_text}
    ],
    Req,
    State
  }.

content_types_accepted(Req, State) ->
  {
    [
      {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
      {{<<"application">>, <<"json">>, '*'}, from_json}
    ],
    Req,
    State
  }.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

execute_bdd(_JobId) -> ok.

do_schedule(JobId, daily, every, Hour, Minute, AMPM) ->
  Job = {{once, {Hour, Minute, AMPM}}, {damage_schedule, execute_bdd, [JobId]}},
  erlcron:cron(Job).


do_schedule(JobId, once, Hour, Minute, Second) when is_integer(Second) ->
  Job =
    {{once, {Hour, Minute, Second}}, {damage_schedule, execute_bdd, [JobId]}},
  erlcron:cron(Job);

do_schedule(JobId, once, Hour, Minute, AMPM) when is_atom(AMPM) ->
  Job = {{once, {Hour, Minute, AMPM}}, {damage_schedule, execute_bdd, [JobId]}},
  erlcron:cron(Job).


do_schedule(JobId, once, Seconds) when is_integer(Seconds) ->
  Job = {{once, Seconds}, {damage_schedule, execute_bdd, [JobId]}},
  erlcron:cron(Job).


binary_spec_to_term_spec([], Acc) -> Acc;

binary_spec_to_term_spec([Spec | Rest], Acc) ->
  Term =
    case catch binary_to_integer(Spec) of
      {'EXIT', _} -> binary_to_atom(Spec);
      Int -> Int
    end,
  binary_spec_to_term_spec(Rest, Acc ++ [Term]).


from_text(Req, State) ->
  #{account := Account} = cowboy_req:match_qs([account], Req),
  {ok, Body, _} = cowboy_req:read_body(Req),
  CronJobs = binary_spec_to_term_spec(cowboy_req:path_info(Req), []),
  logger:debug("Cron Spec: ~p", [CronJobs]),
  {ok, #{<<"Hash">> := Hash}} =
    damage_ipfs:add({data, Body, <<"Scheduledjob">>}),
  Args = [Hash] ++ CronJobs,
  logger:info("do_schedule: ~p", [Args]),
  CronJob = apply(?MODULE, do_schedule, Args),
  logger:debug("Cron Job: ~p", [CronJob]),
  {ok, true} = save_schedule(Account, CronJob),
  %damage_accounts:update_schedules(Account, Hash, CronJob),
  Resp = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>}), Req),
  {stop, cowboy_req:reply(201, Resp), State}.


from_json(Req, State) -> from_text(Req, State).

from_html(Req, State) -> from_text(Req, State).

to_html(Req, State) -> to_json(Req, State).

to_text(Req, State) -> to_json(Req, State).

to_json(Req, State) ->
  #{account := Account} = cowboy_req:match_qs([account], Req),
  Body = jsx:encode(#{schedules => load_schedule(Account)}),
  {Body, Req, State}.


save_schedule(Account, Schedule) ->
  logger:debug("Save Job: ~p", [Schedule]),
  {ok, true} =
    damage_riak:put(<<"Schedules">>, Account, term_to_binary(Schedule)).


load_schedule(Account) ->
  Obj = damage_riak:get(<<"Schedules">>, Account),
  Schedules = riakc_obj:get_contents(Obj),
  binary_to_term(Schedules).


load_schedules() ->
  [load_schedule(Account) || Account <- damage_riak:list_keys(<<"Schedules">>)],
  ok.
