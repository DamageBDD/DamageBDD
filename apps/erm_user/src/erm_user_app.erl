-module(erm_user_app).
-behaviour(application).
-export([start/2, stop/1]).
start(_Type, _Args) ->
    try erm_user_config:prepare() of
        ok -> erm_user_sup:start_link();
        {error, _} = Error -> Error
    catch
        _:_ -> {error, userspace_initialization_failed}
    end.
stop(_State) -> ok.
