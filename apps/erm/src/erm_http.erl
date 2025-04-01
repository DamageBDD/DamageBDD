-module(erm_http).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, is_authorized/2]).
-export([content_types_accepted/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").

-define(TRAILS_TAG, ["Erm"]).

trails() ->
    [
        trails:trail(
            "/erm/list_windows",
            erm_http,
            #{action => list_windows},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "List windows.",
                        produces => ["application/json"],
                        parameters => []
                    }
            }
        ),
        trails:trail(
            "/erm/apps/:app/[:action]",
            erm_http,
            #{action => app},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "List windows.",
                        produces => ["application/json"],
                        parameters => []
                    }
            }
        ),
        trails:trail(
            "/erm/volume/",
            erm_http,
            #{action => volume},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Volume control.",
                        produces => ["application/json"],
                        parameters => []
                    }
            }
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) -> {true, Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

to_json(Req, #{action := list_windows} = State) ->
    Windows = x11:list_windows(),
    {jsx:encode(Windows), Req, State};
to_json(Req, #{action := app} = State) ->
    case cowboy_req:binding(app, Req) of
        undefined ->
            {<<"app required">>, Req, State};
        App ->
            Func = cowboy_req:binding(function, Req, <<"show">>),
            AppModule = binary_to_atom(<<"erm_", App/binary>>),
            _Result = apply(AppModule, binary_to_atom(Func), []),
            {jsx:encode(#{status => "ok"}), Req, State}
    end.

from_json(_Req, State) -> {stop, <<"ok.">>, State}.
