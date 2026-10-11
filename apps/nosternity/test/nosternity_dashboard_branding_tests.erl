%% Real Mustache and Cowboy exercise for operator branding on the dashboard.
-module(nosternity_dashboard_branding_tests).
-include_lib("eunit/include/eunit.hrl").

branding_http_test_() -> {timeout, 30, fun branding_http/0}.
branding_http() ->
    Keys = [node_name, node_title, node_description, node_logo_url,
        node_favicon_url, node_accent_color],
    Previous = [{K, application:get_env(nosternity, K)} || K <- Keys],
    [{ok, _} = application:ensure_all_started(A) || A <- [cowboy, gun]],
    Ref = make_ref(),
    {ok, _} = cowboy:start_clear(Ref, #{socket_opts => [{ip, {127,0,0,1}}, {port, 0}]},
        #{env => #{dispatch => cowboy_router:compile([{'_', nosternity_dashboard:routes()}])}}),
    Port = ranch:get_port(Ref),
    try
        [application:set_env(nosternity, K, V) || {K, V} <- [
            {node_name, <<"Sydney <Node> & friends">>},
            {node_title, <<"Search <script>alert(1)</script>">>},
            {node_description, <<"Conversations & discovery">>},
            {node_logo_url, <<"https://images.example:8443/logo.png?a=1&b=2">>},
            {node_favicon_url, <<"https://icons.example/favicon.ico">>},
            {node_accent_color, <<"#006D77">>}]],
        {200, Headers, HTML} = get(Port, "/dashboard"),
        includes(HTML, <<"<title>Search &lt;script&gt;alert(1)&lt;/script&gt;</title>">>),
        includes(HTML, <<"Sydney &lt;Node&gt; &amp; friends">>),
        includes(HTML, <<"data-node-name=\"Sydney &lt;Node&gt; &amp; friends\"">>),
        includes(HTML, <<"class=\"node-logo\"">>),
        includes(HTML, <<"https://images.example:8443/logo.png?a=1&amp;b=2">>),
        includes(HTML, <<"rel=\"icon\" href=\"https://icons.example/favicon.ico\"">>),
        includes(HTML, <<"--green:#006D77">>),
        includes(HTML, <<"content=\"#006D77\"">>),
        includes(HTML, <<"id=\"authTemplate\"">>),
        includes(HTML, <<"data-action=\"nostrLogin\"">>),
        ?assertEqual(nomatch, binary:match(HTML, <<"<script>alert(1)</script>">>)),
        CSP = proplists:get_value(<<"content-security-policy">>, Headers),
        includes(CSP, <<"img-src 'self' data: https://icons.example https://images.example:8443;">>),
        includes(CSP, <<"script-src 'self';">>),
        ?assertEqual(nomatch, binary:match(CSP, <<"logo.png">>)),
        {200, _, Auth} = get(Port, "/dashboard/fragments/auth"),
        includes(Auth, <<"Create a Sydney &lt;Node&gt; &amp; friends account">>),
        {200, _, Root} = get(Port, "/"),
        ?assertEqual(HTML, Root),
        application:set_env(nosternity, node_logo_url, <<"/logo.png">>),
        application:set_env(nosternity, node_favicon_url, <<>>),
        {200, Headers2, _} = get(Port, "/dashboard"),
        includes(proplists:get_value(<<"content-security-policy">>, Headers2),
            <<"img-src 'self' data:;">>),
        application:set_env(nosternity, node_logo_url, <<"http://[::1]:8080/logo.png">>),
        {200, IPv6Headers, _} = get(Port, "/dashboard"),
        includes(proplists:get_value(<<"content-security-policy">>, IPv6Headers),
            <<"img-src 'self' data: http://[::1]:8080;">>),
        application:set_env(nosternity, node_logo_url, <<>>),
        {ok, Sidebar} = nosternity_dashboard:render(<<"sidebar">>),
        ?assertEqual(nomatch, binary:match(Sidebar, <<"class=\"node-logo\"">>)),
        includes(Sidebar, <<"class=\"logo\"">>),
        {404, _, _} = get(Port, "/dashboard/fragments/not_allowed")
    after
        cowboy:stop_listener(Ref),
        [case V of undefined -> application:unset_env(nosternity, K);
            {ok, X} -> application:set_env(nosternity, K, X) end || {K, V} <- Previous]
    end.

includes(Binary, Text) -> ?assertNotEqual(nomatch, binary:match(Binary, Text)).
get(Port, Path) ->
    {ok, Conn} = gun:open("127.0.0.1", Port, #{protocols => [http]}),
    try
        {ok, http} = gun:await_up(Conn),
        Stream = gun:get(Conn, Path),
        case gun:await(Conn, Stream) of
            {response, fin, Status, Headers} -> {Status, Headers, <<>>};
            {response, nofin, Status, Headers} ->
                {ok, Body} = gun:await_body(Conn, Stream), {Status, Headers, Body}
        end
    after gun:close(Conn) end.
