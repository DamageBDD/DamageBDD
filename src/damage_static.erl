-module(damage_static).

-export([init/2, terminate/3]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([trails/0]).

trails() -> [{"/help", damage_static, {priv_dir, damage, "help"}}].

init(Req, Opts) ->
    logger:info("Got init ~p ~p.", [Req, Opts]),
    {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
    {
        [
            {{<<"text">>, <<"html">>, '*'}, to_html},
            {{<<"application">>, <<"json">>, '*'}, to_json},
            {{<<"text">>, <<"plain">>, '*'}, to_text}
        ],
        Req,
        State
    }.

to_html(Req, {priv_dir, damage, File}) ->
    UserAgent = cowboy_req:header(<<"user-agent">>, Req, ""),
    case UserAgent of
        <<"curl", _/binary>> -> serve_file(Req, File, ".txt");
        _Other -> serve_file(Req, File, ".html")
    end.

to_json(Req, {priv_dir, damage, File}) -> serve_file(Req, File, ".json").

to_text(Req, {priv_dir, damage, File}) -> serve_file(Req, File, ".txt").

serve_file(Req, File, Mime) ->
    PrivDir = code:priv_dir(damage),
    FilePath = filename:join([PrivDir, "static", File ++ Mime]),
    logger:info("serviing path ~p", [FilePath]),
    case file:read_file(FilePath) of
        {ok, Data} ->
            Uri = cowboy_req:uri(Req, #{path => undefined, qs => undefined}),
            Resp =
                cowboy_req:set_resp_body(
                    mustache:render(
                        binary_to_list(Data),
                        [
                            {
                                damage_url,
                                binary_to_list(binary:list_to_bin(lists:flatten(Uri)))
                            }
                        ]
                    ),
                    Req
                ),
            {stop, cowboy_req:reply(200, Resp), undefined};
        _ ->
            {ok, Req5} = cowboy_req:reply(404, #{}, <<>>, Req),
            {ok, Req5, undefined}
    end.

terminate(_Reason, _Req, _State) -> ok.
