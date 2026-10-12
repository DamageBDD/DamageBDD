-module(nosternity_branding_http_tests).
-include_lib("eunit/include/eunit.hrl").

default_pages_test() ->
    with_server(fun(Port) ->
        {200, Headers, Home} = request(Port, <<"GET">>, <<"/">>),
        ?assertEqual(<<"no-store">>, proplists:get_value(<<"cache-control">>, Headers)),
        contains(Home, <<"<title>Nosternity Search</title>">>),
        contains(Home, <<"<h1>Nosternity Search</h1>">>),
        contains(Home, <<"<strong>Nosternity Search</strong>">>),
        excludes(Home, <<"<img ">>),
        excludes(Home, <<"rel=\"icon\"">>),
        {200, _, Note} = request(Port, <<"GET">>, <<"/nostr/note/?id=abc123">>),
        contains(Note, <<"<title>Nostr Note | Nosternity Search</title>">>),
        contains(Note, <<"value=\"abc123\"">>),
        {200, _, Asset} = request(Port, <<"GET">>, <<"/branding/README.txt">>),
        contains(Asset, <<"Optional public node branding assets">>)
    end).

custom_branding_test() ->
    with_server(fun(Port) ->
        set_branding(),
        {200, _, Home} = request(Port, <<"GET">>, <<"/">>),
        contains(Home, <<"<title>Community &amp; Search</title>">>),
        contains(Home, <<"<h1>Community &amp; Search</h1>">>),
        contains(Home, <<"<strong>A &amp; B &lt;Node&gt;</strong>">>),
        contains(Home, <<"src=\"https://example.org/logo.svg?x=1&amp;y=2\"">>),
        contains(Home, <<"alt=\"A &amp; B &lt;Node&gt; logo\"">>),
        contains(Home, <<"rel=\"icon\" href=\"/branding/favicon.svg\"">>),
        contains(Home, <<"--node-accent:#123abc;">>),
        contains(Home, <<"&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;">>),
        excludes(Home, <<"<script>alert">>),
        %% An operator's environment update is observed by the next request.
        application:set_env(nosternity, node_title, <<"Updated title">>),
        {200, _, Updated} = request(Port, <<"GET">>, <<"/">>),
        contains(Updated, <<"<title>Updated title</title>">>)
    end).

note_id_is_escaped_once_test() ->
    with_server(fun(Port) ->
        set_branding(),
        {200, _, Note} = request(
            Port,
            <<"GET">>,
            <<"/nostr/note/?id=%22%3E%3Cscript%3E%26">>
        ),
        contains(Note, <<"<title>Nostr Note | Community &amp; Search</title>">>),
        contains(Note, <<"value=\"&quot;&gt;&lt;script&gt;&amp;\"">>),
        excludes(Note, <<"&amp;quot;">>),
        excludes(Note, <<"&amp;lt;script">>),
        excludes(Note, <<"value=\"\"><script>">>)
    end).

http_methods_test() ->
    with_server(fun(Port) ->
        {200, Headers, <<>>} = request(Port, <<"HEAD">>, <<"/">>),
        ?assertEqual(<<"no-store">>, proplists:get_value(<<"cache-control">>, Headers)),
        {405, _, _} = request(Port, <<"POST">>, <<"/">>)
    end).

discovery_matches_branding_test() ->
    with_server(fun(Port) ->
        {200, _, DefaultBody} = request(Port, <<"GET">>, <<"/nostr">>),
        Default = jsx:decode(DefaultBody, [return_maps]),
        ?assertNot(maps:is_key(<<"icon">>, Default)),
        set_branding(),
        {200, Headers, Body} = request(Port, <<"GET">>, <<"/nostr">>),
        ?assertEqual(
            <<"application/nostr+json">>,
            proplists:get_value(<<"content-type">>, Headers)
        ),
        Info = jsx:decode(Body, [return_maps]),
        ?assertEqual(<<"A & B <Node>">>, maps:get(<<"name">>, Info)),
        ?assertEqual(<<"<script>alert(\"x\")</script>">>, maps:get(<<"description">>, Info)),
        ?assertEqual(<<"https://example.org/logo.svg?x=1&y=2">>, maps:get(<<"icon">>, Info)),
        lists:foreach(
            fun(Key) ->
                ?assertEqual(maps:get(Key, Default), maps:get(Key, Info))
            end,
            [<<"supported_nips">>, <<"software">>, <<"version">>, <<"limitation">>]
        ),
        ?assertEqual([1, 9, 11, 40, 50], maps:get(<<"supported_nips">>, Info)),
        application:set_env(nosternity, node_logo_url, <<"/branding/logo.svg">>),
        {200, _, RelativeBody} = request(Port, <<"GET">>, <<"/nostr">>),
        ?assertNot(maps:is_key(<<"icon">>, jsx:decode(RelativeBody, [return_maps])))
    end).

contains(Body, Fragment) -> ?assertNotEqual(nomatch, binary:match(Body, Fragment)).
excludes(Body, Fragment) -> ?assertEqual(nomatch, binary:match(Body, Fragment)).

set_branding() ->
    lists:foreach(
        fun({Key, Value}) -> application:set_env(nosternity, Key, Value) end,
        [
            {node_name, <<"A & B <Node>">>},
            {node_title, <<"Community & Search">>},
            {node_description, <<"<script>alert(\"x\")</script>">>},
            {node_logo_url, <<"https://example.org/logo.svg?x=1&y=2">>},
            {node_favicon_url, <<"/branding/favicon.svg">>},
            {node_accent_color, <<"#123abc">>}
        ]
    ).

with_server(Fun) ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    Keys = [
        node_name,
        node_title,
        node_description,
        node_logo_url,
        node_favicon_url,
        node_accent_color
    ],
    Saved = [{Key, application:get_env(nosternity, Key)} || Key <- Keys],
    lists:foreach(fun(Key) -> application:unset_env(nosternity, Key) end, Keys),
    Ref = make_ref(),
    %% Use the production handlers and application templates on a loopback port.
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/", nosternity_http, #{action => home_ui}},
            {"/nostr/note/", nosternity_http, #{action => note_ui}},
            {"/nostr", nosternity_websocket, #{}},
            {"/branding/[...]", cowboy_static, {priv_dir, nosternity, "branding"}}
        ]}
    ]),
    try
        {ok, _} = cowboy:start_clear(
            Ref,
            [{ip, {127, 0, 0, 1}}, {port, 0}],
            #{env => #{dispatch => Dispatch}}
        ),
        Fun(ranch:get_port(Ref))
    after
        cowboy:stop_listener(Ref),
        lists:foreach(
            fun
                ({Key, undefined}) -> application:unset_env(nosternity, Key);
                ({Key, {ok, Value}}) -> application:set_env(nosternity, Key, Value)
            end,
            Saved
        )
    end.

request(Port, Method, Path) ->
    {ok, Pid} = gun:open(
        "127.0.0.1",
        Port,
        #{transport => tcp, protocols => [http], retry => 0}
    ),
    try
        {ok, http} = gun:await_up(Pid, 3000),
        Ref = gun:request(Pid, Method, Path, [], <<>>),
        case gun:await(Pid, Ref, 3000) of
            {response, fin, Status, Headers} ->
                {Status, Headers, <<>>};
            {response, nofin, Status, Headers} ->
                {ok, Body} = gun:await_body(Pid, Ref, 3000),
                {Status, Headers, Body}
        end
    after
        gun:close(Pid)
    end.
