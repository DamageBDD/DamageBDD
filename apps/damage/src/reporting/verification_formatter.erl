%% Progress is a strict projection. No context, bodies, arguments, stdout,
%% signatures, credentials or exception text cross this formatter boundary.
-module(verification_formatter).
-export([format/3]).
format(#{phase:=execute,sink:=Sink,job_id:=Id},step,{_,Line,_,_,_,Status}) ->
    case outcome(Status) of
        ignore -> ok;
        Result -> Sink ! {verification_progress,Id,#{line=>Line,state=>Result}},ok
    end;
format(_,_,_) -> ok.
outcome(success)->passed;
outcome({fail,_})->failed;
outcome(fail)->failed;
outcome(skip)->skipped;
outcome(notfound)->failed;
outcome(error)->failed;
outcome(_)->ignore.
