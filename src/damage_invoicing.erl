-module(damage_invoicing).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, is_authorized/2]).
-export([content_types_accepted/2]).
-export([trails/0]).
-export([delete_resource/2]).
-export([lookup_invoice/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Damage Invoices"]).

trails() ->
  [
    trails:trail(
      "/invoices",
      damage_invoicing,
      #{},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "List invoices.",
          produces => ["application/json"],
          parameters => []
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Create new invoice.",
          produces => ["application/json"],
          parameters
          =>
          [
            #{
              name => <<"label">>,
              description => <<"label for invoice.">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            },
            #{
              name => <<"description">>,
              description => <<"description for invoice.">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            },
            #{
              name => <<"amount_msats">>,
              description => <<"amount in micro sats for invoice.">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            }
          ]
        },
        delete
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Delete invoice.",
          produces => ["application/json"],
          parameters => [
            #{
              name => <<"payment_hash">>,
              description => <<"payment hash for invoice to cancel.">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            }
]
        }
      }
    )
  ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
  {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
  {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

allowed_methods(Req, State) ->
  {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

to_json(Req, #{ae_account := _AeAccount} = State) ->
  {jsx:encode(#{}), Req, State}.


from_json(Req, #{ae_account := AeAccount, ae_account := AeAccount} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status, Resp0} =
    case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
      {'EXIT', {badarg, Trace}} ->
        logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
        {400, <<"Json decoding failed.">>};

      #{label := Label, amount_msats := Amount, cltv := Cltv, description := Description} = InvReq ->
        ?LOG_DEBUG("Invoice request ~p", [InvReq]),
        case cln:hold_invoice(Amount, Description, Label, Cltv) of
            #{bolt11 :=
              _Bolt11,
          created_index := _Index,expires_at := _Expiry,
          payment_hash :=
              _PaymentHash,
          payment_secret :=
              _PaymentSecret} = Invoice ->
                {202, Invoice};

          Error ->
                ?LOG_ERROR("Failed to create invoice ~p", [Error]),
            {400, "Failed to create invoice." }

        end
    end,
  Resp = cowboy_req:set_resp_body(jsx:encode(Resp0), Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


delete_resource(Req, #{ae_account := _AeAccount} = State) ->
  Deleted =
    lists:foldl(
      fun
        (PaymentHash, Acc) ->
          ?LOG_DEBUG("deleted ~p ~p", [maps:get(path_info, Req), PaymentHash]),
          ok = cln:hold_invoice_cancel(PaymentHash),
          Acc + 1
      end,
      0,
      maps:get(path_info, Req)
    ),
  ?LOG_INFO("deleted ~p invoice", [Deleted]),
  {true, Req, State}.

lookup_invoice(Req, State) ->
  ?LOG_INFO("look up invoice ~p ~p", [Req, State]),
  [].
    
