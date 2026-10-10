%%% Optional ERM facade. Invoke after ECAI is on the Erlang code path.
%%% No mandatory ERM supervision or startup modification.
-module(erm_voice_loop).
-export([start/1, next/1, loop/2, pause/1, status/1, stop/1]).
start(Options) -> ecai_voice_live:start_link(Options).
next(Pid) -> ecai_voice_live:next(Pid).
loop(Pid, IntervalMs) -> ecai_voice_live:loop(Pid, IntervalMs).
pause(Pid) -> ecai_voice_live:pause(Pid).
status(Pid) -> ecai_voice_live:status(Pid).
stop(Pid) -> ecai_voice_live:stop(Pid).
