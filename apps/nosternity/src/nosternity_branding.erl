%% Operator-controlled, validated presentation values shared by HTML and NIP-11.
%% Templates must use ordinary escaped Mustache variables for these strings.
-module(nosternity_branding).
-export([template_vars/0, page_title/1, relay_info/0]).

template_vars() ->
    Brand = theme_branding(),
    Logo = brand_value(Brand, <<"logo">>, nosternity_config:get(node_logo_url)),
    Favicon = brand_value(Brand, <<"favicon">>, nosternity_config:get(node_favicon_url)),
    #{
        name => brand_value(Brand, <<"name">>, nosternity_config:get(node_name)),
        title => brand_value(Brand, <<"name">>, nosternity_config:get(node_title)),
        description => brand_value(Brand, <<"tagline">>, nosternity_config:get(node_description)),
        logo_url => Logo,
        favicon_url => Favicon,
        accent_color => brand_value(Brand, <<"accent">>, nosternity_config:get(node_accent_color)),
        has_logo => Logo =/= <<>>,
        has_favicon => Favicon =/= <<>>
    }.

page_title(<<>>) ->
    maps:get(title, template_vars());
page_title([]) ->
    maps:get(title, template_vars());
page_title(Page) ->
    Title = maps:get(title, template_vars()),
    Prefix = unicode:characters_to_binary(Page),
    <<Prefix/binary, " | ", Title/binary>>.

relay_info() ->
    Vars = template_vars(),
    Info = #{
        name => maps:get(name, Vars),
        description => maps:get(description, Vars)
    },
    %% Advertise only absolute icon URLs for interoperability with remote
    %% NIP-11 clients; root-relative logos remain available in this node's UI.
    case maps:get(logo_url, Vars) of
        <<>> -> Info;
        <<"/", _/binary>> -> Info;
        Logo -> Info#{icon => Logo}
    end.

%% The themes catalog is served by Damage's supervised store in the same node.
%% A standalone Nosternity process remains usable without that dependency.
theme_branding() ->
    try damage_theme:branding(<<"nosternity">>)
    catch _:_ -> #{} end.
brand_value(Map, Field, Default) ->
    case maps:get(Field, Map, <<>>) of
        <<>> -> Default;
        Value when is_binary(Value) -> Value;
        _ -> Default
    end.
