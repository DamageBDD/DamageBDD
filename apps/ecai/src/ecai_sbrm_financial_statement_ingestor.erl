-module(ecai_sbrm_financial_statement_ingestor).

-author("Steven Joseph <steven@stevenjoseph.in>").

-export([
    ingest_report/1
]).

%%====================================================================
%% Public API
%%====================================================================

%% Entry point: decoded JSON map
ingest_report(#{ <<"reportMetadata">> := Meta,
                 <<"factSet">> := Facts }) ->

    lists:map(
        fun(Fact) ->
            NamedSet = build_named_set(Meta, Fact),
            ecai_named_set_index:ingest(NamedSet)
        end,
        Facts
    ).

%%====================================================================
%% NAMED_SET Construction
%%====================================================================

build_named_set(Meta, Fact) ->
    #{
      <<"NAMED_SET">> => #{
        <<"SIGN">> => sign(Meta, Fact),
        <<"CONTEXT">> => context(Meta, Fact),
        <<"CARRIER_METADATA">> => carrier_metadata(Meta)
      }
    }.

%%--------------------------------------------------------------------
%% SIGN
%%--------------------------------------------------------------------

sign(#{ <<"entityID">> := EntityID,
        <<"currency">> := Currency },
     #{ <<"conceptID">> := ConceptID,
        <<"value">> := Value }) ->

    #{
      <<"subject">>   => EntityID,
      <<"predicate">> => ConceptID,
      <<"object">>    => Value,
      <<"unit">>      => Currency
    }.

%%--------------------------------------------------------------------
%% CONTEXT
%%--------------------------------------------------------------------

context(#{ <<"reportName">> := ReportName,
           <<"reportingPeriod">> := Period,
           <<"status">> := Status },
        Fact) ->

    Base =
        #{
          <<"report_name">>      => ReportName,
          <<"reporting_period">> => Period,
          <<"period_type">>      => maps:get(<<"periodType">>, Fact, undefined),
          <<"balance">>          => maps:get(<<"balance">>, Fact, undefined),
          <<"status">>           => Status
        },

    add_flags(Base, Fact).

add_flags(Context, Fact) ->
    Flags =
        lists:filtermap(
            fun
                ({<<"isTotal">>, true})       -> {true, <<"total">>};
                ({<<"isGrandTotal">>, true})  -> {true, <<"grand_total">>};
                (_) -> false
            end,
            maps:to_list(Fact)
        ),

    case Flags of
        [] -> Context;
        _  -> Context#{ <<"flags">> => Flags }
    end.

%%--------------------------------------------------------------------
%% CARRIER METADATA
%%--------------------------------------------------------------------

carrier_metadata(_Meta) ->
    #{
      <<"source">> => <<"financial_report">>,
      <<"ingestion">> => <<"chunked_fact">>
    }.
