-module(princess_app).

-behaviour(application).
%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
	lager:start(),
	application:start(crypto),
	application:start(ssl),
	application:start(ranch),
	start_listener(),
	princess_sup:start_link().

stop(_State) ->
  ok.

start_listener()->
	ListenerConf = princess_config:get(listener),
	
	Port = proplists:get_value(port,ListenerConf),
	MaxWorker = proplists:get_value(max_worker,ListenerConf),
	AcceptorWorker = proplists:get_value(acceptor_worker,ListenerConf),
	
	Certfile = proplists:get_value(certfile,ListenerConf),
	Keyfile = proplists:get_value(keyfile,ListenerConf),

	TransOpts = [{certfile,Certfile},{keyfile,Keyfile},{port, Port},{reuseaddr, true}],

	{ok, _} = ranch:start_listener(princess,AcceptorWorker,
                ranch_ssl, TransOpts, magic_protocol,[]),
	ranch:set_max_connections(princess,MaxWorker).
