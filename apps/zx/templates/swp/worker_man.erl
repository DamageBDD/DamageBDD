%%% @doc
%%% 〘*PROJECT NAME*〙: 〘*CAP SERVICE*〙 Worker Manager
%%% @end

-module(〘*PREFIX*〙_〘*SERVICE*〙_man).
-vsn("〘*VERSION*〙").
-behavior(gen_server).
〘*AUTHOR*〙
〘*COPYRIGHT*〙
〘*LICENSE*〙

%% Worker interface
-export([enroll/0]).
%% gen_server
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).
-include("$zx_include/zx_logger.hrl").


%%% Type and Record Definitions


-record(s,
        {〘*SERVICE*〙s = [] :: [pid()]}).


-type state() :: #s{}.



%%% Service Interface



%%% Worker Interface

-spec enroll() -> ok.
%% @doc
%% Workers register here after they initialize.

enroll() ->
    gen_server:cast(?MODULE, {enroll, self()}).



%%% gen_server

-spec start_link() -> Result
    when Result :: {ok, pid()}
                 | {error, Reason :: term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, none, []).


init(none) ->
    State = #s{},
    {ok, State}.


handle_call(Unexpected, From, State) ->
    ok = log(warning, "Unexpected call from ~tp: ~tp", [From, Unexpected]),
    {noreply, State}.


handle_cast({enroll, PID}, State) ->
    NewState = do_enroll(PID, State),
    {noreply, NewState};
handle_cast(Unexpected, State) ->
    ok = log(warning, "Unexpected cast: ~tp", [Unexpected]),
    {noreply, State}.


handle_info({'DOWN', Mon, process, PID, Reason}, State) ->
    NewState = handle_down(Mon, PID, Reason, State),
    {noreply, NewState};
handle_info(Unexpected, State) ->
    ok = log(warning, "Unexpected info: ~tp", [Unexpected]),
    {noreply, State}.


handle_down(Mon, PID, Reason, State = #s{〘*SERVICE*〙s = 〘*CAP SERVICE*〙s}) ->
    case lists:member(PID, 〘*CAP SERVICE*〙s) of
        true ->
            New〘*CAP SERVICE*〙s = lists:delete(PID, 〘*CAP SERVICE*〙s),
            State#s{〘*SERVICE*〙s = New〘*CAP SERVICE*〙s};
        false ->
            Unexpected = {'DOWN', Mon, process, PID, Reason},
            ok = log(warning, "Unexpected info: ~tp", [Unexpected]),
            State
    end.


code_change(_, State, _) ->
    {ok, State}.


terminate(_, _) ->
    ok.



%%% Doer Functions

-spec do_enroll(PID, State) -> NewState
    when PID      :: pid(),
         State    :: state(),
         NewState :: state().

do_enroll(PID, State = #s{〘*SERVICE*〙s = 〘*CAP SERVICE*〙s}) ->
    case lists:member(PID, 〘*CAP SERVICE*〙s) of
        false ->
            Mon = monitor(process, PID),
            ok = log(info, "Enroll: ~tp @ ~tp", [PID, Mon]),
            State#s{〘*SERVICE*〙s = [PID | 〘*CAP SERVICE*〙s]};
        true ->
            State
    end.
