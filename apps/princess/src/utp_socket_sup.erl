
-module(utp_socket_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-export([create_utp_socket/2]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
  supervisor:start_link(?MODULE,[]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
	RestartStrategy = {simple_one_for_one, 50, 3600},
	UTPSocketMFA = {utp_socket, start_link, []},                                                                
 	UTPSocketWorker = {utp_socket,UTPSocketMFA,temporary,5000,worker,[]}, 
	Children = [UTPSocketWorker],
  	{ok, { RestartStrategy,Children} }.

create_utp_socket(Sup,UDPSocket)->
	{ok,Pid} = supervisor:start_child(Sup,[UDPSocket]),
	Pid.

