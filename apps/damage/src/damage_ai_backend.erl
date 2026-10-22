%% SPDX-License-Identifier: Apache-2.0
%% Trusted adapters receive ONLY the selected profile and explicit AI request,
%% never the DamageBDD execution context. Do not log requests or credentials.
-module(damage_ai_backend).

-callback invoke(proplists:proplist(), map()) ->
    {ok, #{text := binary(), model := binary(), usage := map()}}
    | {ok, #{embedding := [number()], model := binary(), usage := map()}}
    | {error, atom() | {http_status, integer()}}.
