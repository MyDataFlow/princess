
-module(princess_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
	RestartStrategy = {one_for_one, 5, 10},

	FetcherMFA = {princess_fetcher, start_link, []},                                                                
 	FetcherWorker = {princess_fetcher,FetcherMFA,permanent,5000,worker,[]}, 

	Children = [FetcherWorker],
  {ok, { RestartStrategy,Children} }.

