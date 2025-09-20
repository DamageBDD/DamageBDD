%% Dynamic installers rendered via bbmustache templates.
%% Routes (Trails):
%%   GET /install/    -> HTML form (install_form.html.mustache)
%%   GET /install.sh  -> Bash script (install.sh.mustache)
%%   GET /install.ps1 -> PowerShell script (install.ps1.mustache)

-module(damage_install_http).

-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([trails/0]).
-export([allowed_methods/2, is_authorized/2,
         content_types_provided/2, content_types_accepted/2,
         to_html/2, to_text/2, from_json/2, from_html/2]).

-include_lib("kernel/include/logger.hrl").

-define(TAGS, ["Installers"]).

%%% ──────────────────────────── Trails ────────────────────────────
trails() ->
    [
      trails:trail("/install/",    ?MODULE, #{action => form}, #{ get => #{ tags => ?TAGS, description => "Installer form", produces => ["text/html"] } }),
      trails:trail("/install.sh",  ?MODULE, #{action => sh},   #{ get => #{ tags => ?TAGS, description => "Bash installer",   produces => ["text/plain"] } }),
      trails:trail("/install.ps1", ?MODULE, #{action => ps1},  #{ get => #{ tags => ?TAGS, description => "PowerShell bootstrap", produces => ["text/plain"] } })
    ].

%%% ───────────────────────── cowboy_rest ─────────────────────────
init(Req, Opts) -> {cowboy_rest, Req, Opts}.
allowed_methods(Req, State) -> {[<<"GET">>], Req, State}.
is_authorized(Req, State) -> {true, Req, State}.

content_types_provided(Req, #{action := form} = S) -> { [{{<<"text">>, <<"html">>, '*'}, to_html}], Req, S};
content_types_provided(Req, #{action := sh}   = S) -> { [{{<<"text">>, <<"plain">>, '*'}, to_text}], Req, S};
content_types_provided(Req, #{action := ps1}  = S) -> { [{{<<"text">>, <<"plain">>, '*'}, to_text}], Req, S};
content_types_provided(Req, S) -> { [{{<<"text">>, <<"plain">>, '*'}, to_text}], Req, S}.

content_types_accepted(Req, S) ->
    {[
      {{<<"application">>, <<"json">>, '*'}, from_json},
      {{<<"text">>, <<"plain">>, '*'}, from_html}
     ], Req, S}.
from_json(Req, S) -> {stop, cowboy_req:reply(405, Req), S}.
from_html(Req, S) -> {stop, cowboy_req:reply(405, Req), S}.

%%% ─────────────────────────── Helpers ───────────────────────────
qs(Req) -> cowboy_req:parse_qs(Req).
q(Qs, K, Default) ->
    case lists:keyfind(K, 1, Qs) of {K, V} when is_binary(V), byte_size(V)>0 -> V; _ -> Default end.

safe_bin(B) ->
    case re:run(B, "^[A-Za-z0-9._:-]+$", [{capture, none}]) of match -> B; _ -> <<>> end.

no_cache(Req0, CT) ->
    Req1 = cowboy_req:set_resp_header(<<"content-type">>, CT, Req0),
    Req2 = cowboy_req:set_resp_header(<<"x-content-type-options">>, <<"nosniff">>, Req1),
    cowboy_req:set_resp_header(<<"cache-control">>, <<"no-store">>, Req2).

%%% ───────────────────────── Renderers ───────────────────────────
to_html(Req0, #{action := form} = State) ->
    Qs = qs(Req0),
    Ctx = #{
      domain => q(Qs, <<"domain">>, <<"run.example.com">>),
      email  => q(Qs, <<"email">>,  <<"admin@example.com">>),
      repo   => q(Qs, <<"repo">>,   <<"https://github.com/DamageBDD/DamageBDD.git">>),
      branch => q(Qs, <<"branch">>, <<"main">>),
      port   => q(Qs, <<"port">>,   <<"8080">>)
    },
    %% Template rendering via damage_utils helpers (bbmustache). :contentReference[oaicite:1]{index=1}
    Html = damage_utils:load_template("install_form.html.mustache", Ctx),
    Req  = no_cache(Req0, <<"text/html; charset=utf-8">>),
    {Html, Req, State}.

to_text(Req0, #{action := sh} = State) ->
    Qs = qs(Req0),
    Ctx = #{
      domain => safe_bin(q(Qs, <<"domain">>, <<"run.example.com">>)),
      email  => safe_bin(q(Qs, <<"email">>,  <<"admin@example.com">>)),
      repo   => q(Qs, <<"repo">>,   <<"https://github.com/DamageBDD/DamageBDD.git">>),
      branch => safe_bin(q(Qs, <<"branch">>, <<"main">>)),
      port   => safe_bin(q(Qs, <<"port">>,   <<"8080">>))
    },
    Script = damage_utils:load_template("install.sh.mustache", Ctx), %% :contentReference[oaicite:2]{index=2}
    Req1   = no_cache(Req0, <<"text/x-shellscript; charset=utf-8">>),
    Req    = cowboy_req:set_resp_header(<<"content-disposition">>, <<"attachment; filename=install.sh">>, Req1),
    {Script, Req, State};

to_text(Req0, #{action := ps1} = State) ->
    Qs = qs(Req0),
    Ctx = #{
      domain => safe_bin(q(Qs, <<"domain">>, <<"run.example.com">>)),
      email  => safe_bin(q(Qs, <<"email">>,  <<"admin@example.com">>))
    },
    PS1 = damage_utils:load_template("install.ps1.mustache", Ctx), %% :contentReference[oaicite:3]{index=3}
    Req1 = no_cache(Req0, <<"application/x-powershell; charset=utf-8">>),
    Req  = cowboy_req:set_resp_header(<<"content-disposition">>, <<"attachment; filename=install.ps1">>, Req1),
    {PS1, Req, State}.
