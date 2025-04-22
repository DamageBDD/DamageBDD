-module(nosternity_fileserver).

-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, is_authorized/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("nosternity.hrl").

-define(TRAILS_TAG, ["Executing Tests"]).

trails() ->
    [
        trails:trail(
            "/version/",
            damage_http,
            #{action => version},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Form to execute a test on this DamageBDD server.",
                        produces => ["text/html"]
                    }
            }
        ),
        trails:trail(
            "/.well-known/nostr/nip96.json",
            asyncmind_http,
            #{action => nip96},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "REST API for HTTP file storage servers intended to be used in conjunction with the nostr network.",
                        produces => ["text/html"]
                    }
            }
        )
    ].

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

is_authorized(Req, #{action := version} = State) ->
    {true, Req, State}.

from_json(Req, #{public_key := AeAccount, public_key := AeAccount} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status, Resp0} =
        case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
            {'EXIT', {badarg, Trace}} ->
                ?LOG_ERROR("json decoding failed ~p err: ~p.", [Data, Trace]),
                {400, <<"Json decoding failed.">>};
            #{domain := _Domain} ->
                ok
        end,
    Resp = cowboy_req:set_resp_body(jsx:encode(Resp0), Req),
    cowboy_req:reply(Status, Resp),
    {stop, Resp, State}.

to_json(Req, #{public_key := AeAccount} = State) ->
    Domains = damage_ae:get_domains(AeAccount),
    {jsx:encode(Domains), Req, State}.
