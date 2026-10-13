%%% @doc
%%% 〘*PROJECT NAME*〙: 〘*MODULE*〙
%%%
%%% This module is currently named `〘*MODULE*〙', but you may want to change that.
%%% Remember that changing the name in `-module()' below requires renaming
%%% this file, and it is recommended to run `zx update .app` in the main
%%% project directory to make sure the ebin/〘*MODULE*〙.app file stays in
%%% sync with the project whenever you add, remove or rename a module.
%%% @end

-module(〘*MODULE*〙).
-vsn("〘*VERSION*〙").
〘*AUTHOR*〙
〘*COPYRIGHT*〙
〘*LICENSE*〙

-export([hello/0]).


-spec hello() -> ok.

hello() ->
    io:format("~p (~p) says \"Hello!\"~n", [self(), ?MODULE]).
