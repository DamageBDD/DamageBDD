-module(bop_http).

-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2, is_authorized/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("bop.hrl").

-define(TRAILS_TAG, ["BoP Api"]).

trails() ->
    [
        trails:trail(
            "/version/",
            bop_http,
            #{action => version},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Form to execute a test on this BoP server.",
                        produces => ["text/html"]
                    }
            }
        )
].
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

is_authorized(Req, #{action := version} = State) ->
    {true, Req, State}.
init(Req, Opts) -> {cowboy_rest, Req, Opts}.

to_html(Req, #{action := version} = State) ->
    to_json(Req, State).
to_json(Req, #{action := version} = State) ->
    {ok, CommitHash} = file:read_file("commit_hash.txt"),
    {ok, Version} = file:read_file("VERSION"),
    #{public_key := PubKey, private_key := _NodePrivateKey} = secrets:node_keypair(),
    {
        jsx:encode(#{
            commit_hash => CommitHash, version => Version, public_key => list_to_binary(PubKey)
        }),
        Req,
        State
    }.
to_text(Req, State) -> {<<"REST Hello World as text!">>, Req, State}.

from_html(Req0, State) ->
    {ok, _Body, Req} = cowboy_req:read_body(Req0),
    ?LOG_DEBUG("Req ~p.", [Req]),
    _UserAgent = cowboy_req:header(<<"user-agent">>, Req0, ""),
            {
                stop,
                        cowboy_req:set_resp_body("BoP", cowboy_req:reply(200, Req0)),
                State
            }.

from_json(Req, State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status, Resp0} =
        case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
            {'EXIT', {badarg, Trace}} ->
                logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
                {400, <<"Json decoding failed.">>};
            _Json ->
                {400, <<"Notimplemented.">>}
        end,
    Resp = cowboy_req:set_resp_body(jsx:encode(Resp0), Req),
    cowboy_req:reply(Status, Resp),
    {stop, Resp, State}.
