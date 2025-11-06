%%% @doc
%%% 〘*PROJECT NAME*〙
%%% @end

-module(〘*APP MOD*〙).
-vsn("〘*VERSION*〙").
-behavior(application).
〘*AUTHOR*〙
〘*COPYRIGHT*〙
〘*LICENSE*〙

-export([start/2, stop/1]).


-spec start(normal, Args :: term()) -> {ok, pid()}.
%% @private
%% Called by OTP to kick things off. This is for the use of the "application" part of
%% OTP, not to be called by user code.
%%
%% NOTE:
%%   The commented out second argument would come from ebin/〘*APP MOD*〙.app's 'mod'
%%   section, which is difficult to define dynamically so is not used by default
%%   here (if you need this, you already know how to change it).
%%
%%   Optional runtime arguments passed in at start time can be obtained by calling
%%   zx_daemon:argv/0 anywhere in the body of the program.
%%
%% See: http://erlang.org/doc/apps/kernel/application.html

start(normal, _Args) ->
    〘*PREFIX*〙_sup:start_link().


-spec stop(term()) -> ok.
%% @private
%% Similar to start/2 above, this is to be called by the "application" part of OTP,
%% not client code. Causes a (hopefully graceful) shutdown of the application.

stop(_State) ->
    ok.
