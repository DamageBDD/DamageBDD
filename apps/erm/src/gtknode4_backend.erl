%%%-------------------------------------------------------------------
%%% @doc Behaviour implemented by in-VM gtknode4 protocol backends.
%%%
%%% The production local C-node uses the distributed transport directly.
%%% Backends exist for deterministic contract tests and must return exactly
%%% the same command results and canonical event shapes as the native node.
%%%-------------------------------------------------------------------
-module(gtknode4_backend).

-type backend_state() :: term().
-type capabilities() :: map().
-type command() :: term().
-type result() :: term().
-type event() :: {non_neg_integer(), atom(), map()}.

-callback init(Opts :: map()) ->
    {ok, backend_state(), capabilities()} | {error, term()}.

-callback handle_command(command(), backend_state()) ->
    {reply, result(), backend_state()}
    | {reply, result(), backend_state(), [event()]}.

-callback handle_cast(command(), backend_state()) ->
    {noreply, backend_state()}
    | {noreply, backend_state(), [event()]}.

-callback terminate(Reason :: term(), backend_state()) -> ok.
