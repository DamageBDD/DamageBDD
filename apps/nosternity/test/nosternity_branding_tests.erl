-module(nosternity_branding_tests).
-include_lib("eunit/include/eunit.hrl").

defaults_test() ->
    with_branding([], fun() ->
        Vars = nosternity_branding:template_vars(),
        ?assertEqual(<<"Nosternity Search">>, maps:get(name, Vars)),
        ?assertEqual(<<"Nosternity Search">>, maps:get(title, Vars)),
        ?assertEqual(<<"#6750a4">>, maps:get(accent_color, Vars)),
        ?assertEqual(<<>>, maps:get(logo_url, Vars)),
        ?assertEqual(<<>>, maps:get(favicon_url, Vars)),
        ?assertEqual(false, maps:get(has_logo, Vars)),
        ?assertEqual(false, maps:get(has_favicon, Vars)),
        ?assertEqual(<<"Nosternity Search">>, nosternity_branding:page_title(<<>>)),
        ?assertEqual(<<"Note | Nosternity Search">>, nosternity_branding:page_title(<<"Note">>)),
        ?assertEqual(maps:with([name,description], Vars), nosternity_branding:relay_info())
    end).

custom_unicode_and_discovery_test() ->
    Name = [$M, 16#00e1, $l, $a, $g, $a],
    with_branding([{node_name,Name}, {node_title,"Community Notes"},
                   {node_description,"A community search node"},
                   {node_logo_url,"https://cdn.example.org/logo.svg?v=2"},
                   {node_favicon_url,"/static/favicon.png"},
                   {node_accent_color,"#ABC123"}], fun() ->
        ?assertEqual(ok, nosternity_config:validate()),
        Vars = nosternity_branding:template_vars(),
        ?assertEqual(unicode:characters_to_binary(Name), maps:get(name, Vars)),
        ?assertEqual(<<"Community Notes">>, nosternity_branding:page_title([])),
        ?assertEqual(<<"Search | Community Notes">>, nosternity_branding:page_title("Search")),
        ?assertEqual(true, maps:get(has_logo, Vars)),
        ?assertEqual(true, maps:get(has_favicon, Vars)),
        ?assert(lists:all(fun is_binary/1,
            maps:values(maps:without([has_logo,has_favicon], Vars)))),
        ?assertEqual(#{name=>unicode:characters_to_binary(Name),
                       description=><<"A community search node">>,
                       icon=><<"https://cdn.example.org/logo.svg?v=2">>},
                     nosternity_branding:relay_info())
    end).

relative_logo_is_not_advertised_test() ->
    with_branding([{node_logo_url,<<"/static/logo.svg">>}], fun() ->
        ?assertEqual(true, maps:get(has_logo, nosternity_branding:template_vars())),
        ?assertEqual(false, maps:is_key(icon, nosternity_branding:relay_info()))
    end).

text_bounds_and_controls_test() ->
    lists:foreach(fun({Key,Min,Max}) ->
        lists:foreach(fun(N) ->
            Value = binary:copy(<<"x">>, N),
            with_branding([{Key,Value}], fun() ->
                ?assertEqual(Value, nosternity_config:get(Key)) end)
        end, [Min,Max]),
        lists:foreach(fun(Value) -> assert_invalid(Key, Value) end,
            [binary:copy(<<"x">>, Max+1), <<0>>, <<"a\nb">>, <<"a\tb">>,
             <<127>>, <<16#85/utf8>>, <<255>>, [16#d800], 123, undefined]),
        case Min of 1 -> assert_invalid(Key, <<>>); 0 -> ok end
    end, [{node_name,1,128}, {node_title,1,256}, {node_description,0,2048}]),
    %% Bounds count Unicode characters, so accented names are not penalized.
    UnicodeName = binary:copy(<<16#00e9/utf8>>, 128),
    with_branding([{node_name,UnicodeName}], fun() ->
        ?assertEqual(UnicodeName, nosternity_config:get(node_name)) end).

valid_url_forms_test() ->
    lists:foreach(fun(Key) ->
        lists:foreach(fun(URL) -> with_branding([{Key,URL}], fun() ->
            ?assertEqual(URL, nosternity_config:get(Key)) end) end,
            [<<>>, <<"/logo.svg">>, <<"/static/logo.svg?v=2#icon">>,
             <<"https://example.org/logo.png">>, <<"http://localhost:9001/icon.svg">>,
             <<"HTTPS://example.org/logo.svg">>, <<"https://[::1]:9001/logo.svg">>,
             <<"/static/%C3%A9.svg">>, <<"/static/steven's-logo.svg">>,
             <<"https://example.org/logo.svg?token=abc%2F123%3D&v=2">>])
    end, [node_logo_url,node_favicon_url]).

unsafe_urls_test() ->
    lists:foreach(fun(Key) ->
        lists:foreach(fun(Value) -> assert_invalid(Key,Value) end,
            [<<"javascript:alert(1)">>, <<"data:image/svg+xml,bad">>,
             <<"ftp://example.org/logo">>, <<"//example.org/logo">>,
             <<"logo.svg">>, <<"../logo.svg">>, <<"/../logo.svg">>,
             <<"/static/./logo.svg">>, <<"/%2e%2E/logo.svg">>,
             <<"/%2fexample.org/logo">>, <<"/static/%5clogo.svg">>,
             <<"/static/\\logo.svg">>, <<"http://name:secret@example.org/logo">>,
             <<"https://@example.org/logo">>, <<"https:///logo">>,
             <<"https://example.org:65536/logo">>, <<"https://example.org:abc/logo">>,
             <<"https://example.org/logo\n.svg">>, <<"/bad logo.svg">>,
             <<"/bad%00logo.svg">>, <<"/bad%logo.svg">>,
             <<"/logo.svg\" onerror=\"alert(1)">>, <<255>>,
             binary:copy(<<"x">>,2049), 123])
    end, [node_logo_url,node_favicon_url]).

accent_color_test() ->
    lists:foreach(fun(Value) -> assert_invalid(node_accent_color,Value) end,
        [<<"red">>, <<"#abc">>, <<"#abcd1234">>, <<"#gg0000">>,
         <<"#000000;display:none">>, <<"#000000\n">>, <<255>>]),
    with_branding([{node_accent_color,"#09aAfF"}], fun() ->
        ?assertEqual(<<"#09aAfF">>, nosternity_config:get(node_accent_color)) end).

startup_errors_exclude_values_test() ->
    with_branding([{node_logo_url,<<"https://operator:private-secret@example.org/logo">>}], fun() ->
        ?assertEqual({error,{invalid_configuration,node_logo_url}},
                     nosternity_config:validate()),
        ?assertError({invalid_configuration,node_logo_url}, nosternity_branding:template_vars())
    end).

assert_invalid(Key, Value) ->
    with_branding([{Key,Value}], fun() ->
        ?assertError({invalid_configuration,Key}, nosternity_config:get(Key)),
        ?assertEqual({error,{invalid_configuration,Key}}, nosternity_config:validate())
    end).

with_branding(Values, Fun) ->
    Keys = [enabled,node_name,node_title,node_description,node_logo_url,
            node_favicon_url,node_accent_color],
    Saved = [{K,application:get_env(nosternity,K)} || K <- Keys],
    lists:foreach(fun(K) -> application:unset_env(nosternity,K) end, Keys),
    application:set_env(nosternity,enabled,true),
    lists:foreach(fun({K,V}) -> application:set_env(nosternity,K,V) end, Values),
    try Fun()
    after lists:foreach(fun
        ({K,undefined}) -> application:unset_env(nosternity,K);
        ({K,{ok,V}}) -> application:set_env(nosternity,K,V)
    end, Saved) end.
