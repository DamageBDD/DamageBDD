%%% A deliberately data-only, versioned theme package. No user CSS, HTML,
%%% fonts, JS, URLs in CSS or remote stylesheets are accepted.
-module(damage_theme_manifest).
-export([validate/1, validate_branding/1, css/2, key/1, builtin/0, package_hash/1]).

-define(SCHEMA, <<"damage-theme/v1">>).
-define(APPS, [<<"damage">>, <<"ecai">>, <<"nosternity">>, <<"erm">>, <<"bop">>]).

builtin() ->
    [
        #{<<"schema">> => ?SCHEMA, <<"id">> => <<"damage-dark">>, <<"version">> => <<"1.0.0">>,
          <<"name">> => <<"Damage Dark">>, <<"description">> => <<"Original DamageBDD control plane">>,
          <<"tokens">> => #{<<"background">> => <<"#0e1520">>, <<"surface">> => <<"#182535">>,
              <<"text">> => <<"#e6edf7">>, <<"muted">> => <<"#9daec3">>,
              <<"accent">> => <<"#9dd576">>, <<"border">> => <<"#344358">>},
          <<"price_sats">> => 0, <<"price_damage">> => 0, <<"builtin">> => true},
        #{<<"schema">> => ?SCHEMA, <<"id">> => <<"forest">>, <<"version">> => <<"1.0.0">>,
          <<"name">> => <<"Forest">>, <<"description">> => <<"Quiet green surfaces and moss accents">>,
          <<"tokens">> => #{<<"background">> => <<"#f5f8f0">>, <<"surface">> => <<"#ffffff">>,
              <<"text">> => <<"#20352c">>, <<"muted">> => <<"#66796b">>,
              <<"accent">> => <<"#497a4a">>, <<"border">> => <<"#dce5d6">>},
          <<"price_sats">> => 0, <<"price_damage">> => 0, <<"builtin">> => true},
        #{<<"schema">> => ?SCHEMA, <<"id">> => <<"violet">>, <<"version">> => <<"1.0.0">>,
          <<"name">> => <<"Violet">>, <<"description">> => <<"Contrast-rich purple interface">>,
          <<"tokens">> => #{<<"background">> => <<"#141021">>, <<"surface">> => <<"#211a33">>,
              <<"text">> => <<"#f1e9ff">>, <<"muted">> => <<"#b7a9d0">>,
              <<"accent">> => <<"#bc98ff">>, <<"border">> => <<"#433758">>},
          <<"price_sats">> => 0, <<"price_damage">> => 0, <<"builtin">> => true}
    ].

key(M) ->
    <<(maps:get(<<"id">>, M))/binary, "@", (maps:get(<<"version">>, M))/binary>>.

validate(M) when is_map(M) ->
    try
        ?SCHEMA = maps:get(<<"schema">>, M),
        Id = bounded(maps:get(<<"id">>, M), <<"^[a-z][a-z0-9-]{1,47}$">>, 48),
        Version = bounded(maps:get(<<"version">>, M), <<"^[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}$">>, 18),
        Name = plain_text(maps:get(<<"name">>, M), 1, 90),
        Desc = plain_text(maps:get(<<"description">>, M, <<>>), 0, 500),
        Colors = colors(maps:get(<<"tokens">>, M)),
        Brand = validate_branding(maps:get(<<"branding">>, M, #{})),
        true = is_map(Brand),
        Apps = maps:get(<<"apps">>, M, ?APPS),
        true = is_list(Apps) andalso Apps =/= [] andalso length(Apps) =< length(?APPS),
        true = lists:all(fun(A) -> lists:member(A, ?APPS) end, Apps),
        Sats = nonneg(maps:get(<<"price_sats">>, M, 0), 1000000000),
        Damage = nonneg(maps:get(<<"price_damage">>, M, 0), 100000000000000000),
        true = Sats > 0 orelse Damage > 0 orelse maps:get(<<"license">>, M, <<"free">>) =:= <<"free">>,
        {ok, #{<<"schema">> => ?SCHEMA, <<"id">> => Id, <<"version">> => Version,
            <<"name">> => Name, <<"description">> => Desc, <<"tokens">> => Colors,
            <<"branding">> => Brand, <<"apps">> => lists:usort(Apps),
            <<"price_sats">> => Sats, <<"price_damage">> => Damage}}
    catch
        _:_ -> {error, invalid_theme_manifest}
    end;
validate(_) -> {error, invalid_theme_manifest}.

validate_branding(M) when is_map(M), map_size(M) =< 5 ->
    try
        %% Restrict logos to operator-provided, same-origin static images.
        %% Prevent CSS/JS URLs and remote image beacons from NFT metadata.
        Name = plain_text(maps:get(<<"name">>, M, <<>>), 0, 90),
        Tag = plain_text(maps:get(<<"tagline">>, M, <<>>), 0, 180),
        Logo = image_path(maps:get(<<"logo">>, M, <<>>)),
        Icon = image_path(maps:get(<<"favicon">>, M, <<>>)),
        #{<<"name">> => Name, <<"tagline">> => Tag, <<"logo">> => Logo,
          <<"favicon">> => Icon}
    catch _:_ -> {error, invalid_branding} end;
validate_branding(_) -> {error, invalid_branding}.

colors(Colors) when is_map(Colors), map_size(Colors) =< 6 ->
    Names = [<<"background">>, <<"surface">>, <<"text">>, <<"muted">>, <<"accent">>, <<"border">>],
    true = maps:size(Colors) =:= 6,
    maps:from_list([{Name, bounded(maps:get(Name, Colors), <<"^#[0-9a-fA-F]{6}$">>, 7)} || Name <- Names]).

bounded(Value, Regex, Max) when is_binary(Value), byte_size(Value) =< Max ->
    match = re:run(Value, Regex, [{capture, none}]), Value.
plain_text(Value, Min, Max) when is_binary(Value), byte_size(Value) >= Min, byte_size(Value) =< Max ->
    nomatch = re:run(Value, <<"[\\x00-\\x1f\\x7f<>]">>, [{capture, none}]),
    Value.
image_path(<<>>) -> <<>>;
image_path(<<"/static/img/", Rest/binary>> = P) when byte_size(Rest) =< 120 ->
    match = re:run(Rest, <<"^[A-Za-z0-9_/-]+\\.(png|jpg|jpeg|webp|ico)$">>, [{capture, none}]),
    nomatch = binary:match(Rest, <<"..">>),
    nomatch = binary:match(Rest, <<"//">>),
    P.
nonneg(I, Max) when is_integer(I), I >= 0, I =< Max -> I.

%% Stable package digest across key ordering; no runtime atom creation.
package_hash(M) ->
    Hex = binary:encode_hex(crypto:hash(sha256, term_to_binary(canonical(M), [deterministic]))),
    list_to_binary(string:lowercase(binary_to_list(Hex))).
canonical(M) when is_map(M) ->
    lists:sort([{K, canonical(V)} || {K, V} <- maps:to_list(M)]);
canonical(L) when is_list(L) -> [canonical(V) || V <- L];
canonical(V) -> V.

%% Loaded last in <head>. The six package colours remain immutable; semantic
%% roles are derived at render time, not added to NFT manifests or their hashes.
%% CSS cannot contain values from nonvalidated manifests.
css(App, M) when is_binary(App), is_map(M) ->
    Colors = maps:get(<<"tokens">>, M),
    BG = maps:get(<<"background">>, Colors),
    Surface = maps:get(<<"surface">>, Colors),
    Text = maps:get(<<"text">>, Colors),
    Muted = maps:get(<<"muted">>, Colors),
    Accent = maps:get(<<"accent">>, Colors),
    Border = maps:get(<<"border">>, Colors),
    %% Define cross-product tokens first; compatibility aliases then inherit them.
    Vars = semantic_vars(BG, Surface, Text, Muted, Accent, Border) ++ [
        {<<"damage-bg">>, BG}, {<<"damage-surface">>, Surface},
        {<<"damage-text">>, <<"var(--theme-text)">>}, {<<"damage-muted">>, <<"var(--theme-muted)">>},
        {<<"damage-accent">>, Accent}, {<<"damage-border">>, Border},
        {<<"ws-bg">>, BG}, {<<"ws-surface">>, Surface},
        {<<"ws-panel">>, Surface}, {<<"ws-input">>, BG},
        {<<"ws-raised">>, <<"var(--theme-surface-alt)">>},
        {<<"ws-accent-text">>, contrast_text(Accent)},
        {<<"ws-error">>, <<"var(--theme-danger)">>},
        {<<"ws-text">>, <<"var(--theme-text)">>}, {<<"ws-muted">>, <<"var(--theme-muted)">>},
        {<<"ws-accent">>, Accent}, {<<"ws-line">>, Border},
        {<<"green">>, Accent}, {<<"ink">>, <<"var(--theme-text)">>}, {<<"line">>, Border},
        {<<"muted">>, <<"var(--theme-muted)">>}, {<<"node-accent">>, Accent},
        {<<"accent">>, Accent}, {<<"background">>, BG}, {<<"surface">>, Surface},
        {<<"text">>, <<"var(--theme-text)">>}, {<<"bg">>, BG}, {<<"fg">>, <<"var(--theme-text)">>},
        {<<"paper">>, Surface}, {<<"panel">>, Surface}, {<<"card">>, Surface},
        {<<"on-accent">>, contrast_text(Accent)}
    ],
    AppVars = case App of
        <<"ecai">> -> ecai_vars(BG, Surface, Text, Muted, Accent, Border);
        _ -> []
    end,
    Lines = [[<<"--">>, K, <<":">>, V, <<";">>] || {K, V} <- Vars ++ AppVars],
    %% Make background/surfaces participate in existing hardcoded shells.
    Extra = case App of
        <<"damage">> -> <<".damage-dashboard .dashboard-sidebar,.damage-dashboard .dashboard-topbar{background:var(--damage-surface)}.damage-dashboard .dashboard-main{background:var(--damage-bg)}">>;
        <<"nosternity">> -> <<"body{background:var(--theme-bg);color:var(--theme-text)}">>;
        <<"bop">> -> <<"body,body.dark{background:var(--theme-bg);color:var(--theme-text)}">>;
        <<"ecai">> -> <<".console-shell,.console-body{background:var(--damage-bg);color:var(--damage-text)}.console-sidebar,.console-topbar{background:var(--damage-surface)}.theme-brand-logo{width:42px;height:42px;object-fit:contain;flex-shrink:0;border-radius:9px}">>;
        _ -> <<>>
    end,
    iolist_to_binary([<<":root,body{">>, Lines,
        <<"color-scheme:var(--theme-color-scheme);}\n">>, Extra, <<"\n">>]).

%% One semantic contract for all first-party styles. Component-local aliases
%% reference these roles with their original defaults as fallbacks. This also
%% lets standalone/static pages remain usable when the theme endpoint is absent.
semantic_vars(BG, Surface, Text, Muted, Accent, Border) ->
    Ink = readable_on(Text, [Surface, BG]),
    SoftText = readable_on(Muted, [Surface, BG]),
    Link = readable_on(Accent, [Surface, BG]),
    Good = semantic(<<"#17694f">>, <<"#91d99c">>, Surface),
    Bad = semantic(<<"#a72c43">>, <<"#ff9eae">>, Surface),
    Warn = semantic(<<"#795917">>, <<"#ffd392">>, Surface),
    Info = semantic(<<"#285eae">>, <<"#a9c9ff">>, Surface),
    Scheme = case luminance(Surface) < 0.179 of true -> <<"dark">>; false -> <<"light">> end,
    [
        {<<"theme-bg">>, BG}, {<<"theme-surface">>, Surface},
        {<<"theme-surface-alt">>, mix(Surface, Ink, 96)},
        {<<"theme-input">>, BG}, {<<"theme-text">>, Ink},
        {<<"theme-muted">>, SoftText}, {<<"theme-link">>, Link},
        {<<"theme-border">>, Border}, {<<"theme-control-border">>, SoftText},
        {<<"theme-accent">>, Accent}, {<<"theme-on-accent">>, contrast_text(Accent)},
        {<<"theme-accent-hover">>, Accent},
        {<<"theme-accent-soft">>, mix(Surface, Accent, 94)},
        {<<"theme-focus">>, Link},
        {<<"theme-success">>, Good}, {<<"theme-success-soft">>, mix(Surface, Good, 94)},
        {<<"theme-on-success">>, contrast_text(Good)},
        {<<"theme-danger">>, Bad}, {<<"theme-danger-soft">>, mix(Surface, Bad, 94)},
        {<<"theme-on-danger">>, contrast_text(Bad)},
        {<<"theme-warning">>, Warn}, {<<"theme-warning-soft">>, mix(Surface, Warn, 94)},
        {<<"theme-on-warning">>, contrast_text(Warn)},
        {<<"theme-info">>, Info}, {<<"theme-info-soft">>, mix(Surface, Info, 94)},
        {<<"theme-on-info">>, contrast_text(Info)},
        {<<"theme-backdrop">>, <<"rgba(0,0,0,.6)">>},
        {<<"theme-shadow">>, <<"rgba(0,0,0,.18)">>},
        {<<"theme-focus-glow">>, mix(Link, <<"transparent">>, 20)},
        {<<"theme-color-scheme">>, Scheme}
    ].

mix(A, B, Percent) ->
    iolist_to_binary([<<"color-mix(in srgb,">>, A, <<" ">>,
        integer_to_binary(Percent), <<"%,">>, B, <<")">>]).

%% Retain supplied colours where readable on both canvas and panels. If not,
%% minimally move toward the better contrasting endpoint (rather than turning
%% all muted labels pure black/white). Opposing custom surfaces may not admit
%% one foreground; use the best achievable minimum contrast in that case.
readable_on(FG, Backgrounds) ->
    Black = <<"#000000">>, White = <<"#ffffff">>,
    Target = case min_contrast(Black, Backgrounds) >= min_contrast(White, Backgrounds) of
        true -> Black; false -> White
    end,
    readable_step(FG, Target, Backgrounds, 0).
readable_step(FG, Target, BGs, N) ->
    Candidate = blend_hex(FG, Target, N),
    case min_contrast(Candidate, BGs) >= 4.7 orelse N =:= 20 of
        true -> Candidate;
        false -> readable_step(FG, Target, BGs, N + 1)
    end.
min_contrast(FG, BGs) -> lists:min([contrast_ratio(FG, BG) || BG <- BGs]).
blend_hex(<<"#", AR:2/binary, AG:2/binary, AB:2/binary>>,
          <<"#", BR:2/binary, BG:2/binary, BB:2/binary>>, N) ->
    iolist_to_binary([<<"#">> | [io_lib:format("~2.16.0b", [
        round((binary_to_integer(A,16) * (20-N) + binary_to_integer(B,16) * N) / 20)
    ]) || {A,B} <- [{AR,BR},{AG,BG},{AB,BB}]]]).

%% ECAI's legacy palette used --paper/--canvas while the theme supplied only
%% --surface/--background. Remap both halves; derive readable interactive text.
ecai_vars(BG, Surface, Text, Muted, Accent, Border) ->
    Ink = readable_on(Text, [Surface, BG]),
    SoftText = readable_on(Muted, [Surface, BG]),
    [
        {<<"canvas">>, BG}, {<<"paper">>, Surface}, {<<"ink">>, Ink},
        {<<"text">>, Ink}, {<<"muted">>, SoftText},
        {<<"navy">>, Surface}, {<<"navy-soft">>, BG},
        {<<"nav-ink">>, Ink}, {<<"nav-muted">>, SoftText},
        {<<"blue">>, Accent}, {<<"blue-strong">>, Accent},
        {<<"on-accent">>, contrast_text(Accent)},
        {<<"link">>, readable_on(Accent, [Surface, BG])}, {<<"focus">>, readable_on(Accent, [Surface, BG])},
        {<<"border">>, Border}, {<<"border-strong">>, SoftText},
        {<<"surface-2">>, <<"color-mix(in srgb,", Surface/binary, " 94%,", Ink/binary, ")">>},
        {<<"accent-soft">>, <<"color-mix(in srgb,", Accent/binary, " 12%,", Surface/binary, ")">>},
        {<<"sky">>, <<"color-mix(in srgb,", Accent/binary, " 12%,", Surface/binary, ")">>},
        {<<"nav-active-bg">>, <<"color-mix(in srgb,", Accent/binary, " 12%,", Surface/binary, ")">>},
        {<<"success">>, semantic(<<"#21805d">>, <<"#91d99c">>, Surface)},
        {<<"danger">>, semantic(<<"#b4324e">>, <<"#ff9eae">>, Surface)},
        {<<"warning">>, semantic(<<"#84621d">>, <<"#ffd392">>, Surface)},
        {<<"ecai-color-scheme">>, case luminance(Surface) < 0.179 of true -> <<"dark">>; false -> <<"light">> end}
    ].

semantic(Dark, Light, Background) ->
    case contrast_ratio(Dark, Background) >= 4.5 of
        true -> Dark;
        false -> readable(Light, Background)
    end.

readable(Foreground, Background) ->
    case contrast_ratio(Foreground, Background) >= 4.5 of
        true -> Foreground;
        false -> contrast_text(Background)
    end.
contrast_text(Background) ->
    case contrast_ratio(<<"#000000">>, Background) >= contrast_ratio(<<"#ffffff">>, Background) of
        true -> <<"#000000">>;
        false -> <<"#ffffff">>
    end.
contrast_ratio(A, B) ->
    LA = luminance(A), LB = luminance(B),
    (max(LA, LB) + 0.05) / (min(LA, LB) + 0.05).
luminance(<<"#", R:2/binary, G:2/binary, B:2/binary>>) ->
    0.2126 * linear_channel(R) + 0.7152 * linear_channel(G) + 0.0722 * linear_channel(B).
linear_channel(Hex) ->
    V = binary_to_integer(Hex, 16) / 255,
    case V =< 0.04045 of
        true -> V / 12.92;
        false -> math:pow((V + 0.055) / 1.055, 2.4)
    end.
