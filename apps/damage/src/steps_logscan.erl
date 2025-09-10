%% BDD step bindings for file tailing & journald querying (step/6 interface)
-module(steps_logscan).
-behaviour(steps).

-author("Steven Joseph <steven@stevenjoseph.in>").
-include_lib("kernel/include/logger.hrl").

-export([step/6]).

%% Context keys
-define(K_FILE_OFFSETS, logscan_file_offsets).
-define(K_JOURNAL_CURSORS, logscan_journal_cursors).
-define(K_LAST_LINES, logscan_last_lines).
-define(K_LAST_MATCHES, logscan_last_matches).

%% ------------------------------------------------------------
%% When: tail file since last check (with or without patterns)
%% ------------------------------------------------------------

step(_Cfg, Context, <<"When">>, _N,
     ["I tail the log file", File, "since last check matching:"],
     Doc) ->
    Pats     = log_utils:compile_patterns(Doc),
    Offsets0 = maps:get(?K_FILE_OFFSETS, Context, #{}),
    State0   = maps:get(File, Offsets0, #{}),
    {State1, Lines, Matches} = log_utils:tail_file(File, State0, Pats),
    Context#{ ?K_FILE_OFFSETS => Offsets0#{ File => State1 }
            , ?K_LAST_LINES   => Lines
            , ?K_LAST_MATCHES => Matches };

step(_Cfg, Context, <<"When">>, _N,
     ["I tail the log file", File, "since last check"],
     _Doc) ->
    Offsets0 = maps:get(?K_FILE_OFFSETS, Context, #{}),
    State0   = maps:get(File, Offsets0, #{}),
    {State1, Lines, Matches} = log_utils:tail_file(File, State0, []),
    Context#{ ?K_FILE_OFFSETS => Offsets0#{ File => State1 }
            , ?K_LAST_LINES   => Lines
            , ?K_LAST_MATCHES => Matches };

%% ------------------------------------------------------------
%% When: query journald with cursor over a time window
%% ------------------------------------------------------------

step(_Cfg, Context, <<"When">>, _N,
     ["I query journald for", Selector, "over the last", MinutesStr, "minutes matching:"],
     Doc) ->
    Pats     = log_utils:compile_patterns(Doc),
    Minutes  = list_to_integer(MinutesStr),
    Cursors0 = maps:get(?K_JOURNAL_CURSORS, Context, #{}),
    Cur0     = maps:get(Selector, Cursors0, undefined),
    {Cur1, Lines, Matches} = log_utils:query_journald(Selector, Minutes, Cur0, Pats),
    Context#{ ?K_JOURNAL_CURSORS => Cursors0#{ Selector => Cur1 }
            , ?K_LAST_LINES      => Lines
            , ?K_LAST_MATCHES    => Matches };

%% ------------------------------------------------------------
%% Then: negative/positive assertions on last collected lines
%% ------------------------------------------------------------

step(_Cfg, Context, <<"Then">>, _N,
     ["the logs must NOT contain any line matching:"],
     Doc) ->
    Pats  = log_utils:compile_patterns(Doc),
    Lines = maps:get(?K_LAST_LINES, Context, []),
    case log_utils:match_lines(Lines, Pats) of
        [] -> Context;
        Ms ->
            ?LOG_DEBUG("logscan found forbidden matches: ~p", [Ms]),
            maps:put(fail, "Forbidden patterns present in logs", Context)
    end;

step(_Cfg, Context, <<"Then">>, _N,
     ["the logs must contain at least one line matching:"],
     Doc) ->
    Pats  = log_utils:compile_patterns(Doc),
    Lines = maps:get(?K_LAST_LINES, Context, []),
    case log_utils:match_lines(Lines, Pats) of
        [] ->
            ?LOG_DEBUG("logscan expected patterns not found. patterns=~p", [Pats]),
            maps:put(fail, "Expected patterns not found in logs", Context);
        Ms ->
            Context#{ ?K_LAST_MATCHES => Ms }
    end;

%% ------------------------------------------------------------
%% Fallback
%% ------------------------------------------------------------

step(_Cfg, Context, _Phase, _N, _Tokens, _Doc) ->
    Context.
