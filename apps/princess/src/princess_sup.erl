
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
	GenConf = princess_config:get(gen),
	GeneratorMFA = {generator_worker, start_link, [GenConf]},                                                                
 	GeneratorWorker = {generator_worker,GeneratorMFA,permanent,5000,worker,[]}, 
 	UTPSupMFA = {utp_sup,start_link,[]},
 	UTPSup = {utp_sup,UTPSupMFA,permanent,5000,supervisor,[]},
	Children = [GeneratorWorker,UTPSup],
  	{ok, { RestartStrategy,Children} }.

