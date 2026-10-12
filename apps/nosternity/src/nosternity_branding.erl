%% Operator-controlled, validated presentation values shared by HTML and NIP-11.
%% Templates must use ordinary escaped Mustache variables for these strings.
-module(nosternity_branding).
-export([template_vars/0, page_title/1, relay_info/0]).

template_vars() ->
    Logo = nosternity_config:get(node_logo_url),
    Favicon = nosternity_config:get(node_favicon_url),
    #{
        name => nosternity_config:get(node_name),
        title => nosternity_config:get(node_title),
        description => nosternity_config:get(node_description),
        logo_url => Logo,
        favicon_url => Favicon,
        accent_color => nosternity_config:get(node_accent_color),
        has_logo => Logo =/= <<>>,
        has_favicon => Favicon =/= <<>>
    }.

page_title(<<>>) ->
    nosternity_config:get(node_title);
page_title([]) ->
    nosternity_config:get(node_title);
page_title(Page) ->
    Title = nosternity_config:get(node_title),
    Prefix = unicode:characters_to_binary(Page),
    <<Prefix/binary, " | ", Title/binary>>.

relay_info() ->
    Info = #{
        name => nosternity_config:get(node_name),
        description => nosternity_config:get(node_description)
    },
    %% Advertise only absolute icon URLs for interoperability with remote
    %% NIP-11 clients; root-relative logos remain available in this node's UI.
    case nosternity_config:get(node_logo_url) of
        <<>> -> Info;
        <<"/", _/binary>> -> Info;
        Logo -> Info#{icon => Logo}
    end.
