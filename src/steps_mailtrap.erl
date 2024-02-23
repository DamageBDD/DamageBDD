-module(steps_mailtrap).

-export([step/6]).

step(Config, Context, <<"Given">>, _N, ["I have an email inbox", Inbox], _) ->
  Defaults =
    [
      {<<"accept">>, "application/json"},
      {<<"user-agent">>, "damagebdd/1.0"},
      {<<"content-type">>, "application/json"}
    ],
  Headers =
    proplists:from_map(
      proplists:to_map(
        lists:keymerge(1, maps:get(headers, Context, []), Defaults)
      )
    ),
  Url =
    "https://mailtrap.io/api/accounts/{account_id}/projects/{project_id}/inboxes",
  steps_http:gun_post(Config, Context, Url, Headers, Inbox);

%https://api-docs.mailtrap.io/docs/mailtrap-api-docs/86631e73937e2-create-an-inbox
step(
  Config,
  Context,
  <<"Then">>,
  _N,
  ["I should receive an email with subject", _Subject],
  _
) ->
  steps_http:gun_get(
    Config,
    Context,
    "https://mailtrap.io/api/accounts/{account_id}/inboxes/{inbox_id}/messages",
    [{<<"accept">>, "application/json"}, {<<"user-agent">>, "damagebdd/1.0"}]
  ).
