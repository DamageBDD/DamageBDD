-module(damage_logger_filters).

-export([module_only/2]).

module_only(#{meta := #{mfa := {Module, _, _}}} = LogEvent, Module) ->
    LogEvent;
module_only(_, _) ->
    stop.
