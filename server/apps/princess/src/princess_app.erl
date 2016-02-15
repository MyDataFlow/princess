-module(princess_app).

-behaviour(application).
%% Application callbacks
-export([start/2, stop/1]).
-export([princess_pipe/0]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
	lager:start(),
	ok = application:start(crypto),
	ok = application:start(asn1),
	ok = application:start(public_key),
	ok = application:start(ssl),
	princess_sup:start_link().

stop(_State) ->
  ok.

start_listener()->
	ListenerConf = princess_config:get(listener),
	
	Port = proplists:get_value(port,ListenerConf),
	MaxWorker = proplists:get_value(max_worker,ListenerConf),
	AcceptorWorker = proplists:get_value(acceptor_worker,ListenerConf),
	Priv = code:priv_dir(princess),

	Certfile = proplists:get_value(certfile,ListenerConf),
	Keyfile = proplists:get_value(keyfile,ListenerConf),
	Cert = lists:concat([Priv,"/",Certfile]),
	Key = lists:concat([Priv,"/",Keyfile]),
	TransOpts = [{certfile,Cert},{keyfile,Key},{port, Port},{reuseaddr, true}],

	{ok, _} = ranch:start_listener(princess,AcceptorWorker,
                ranch_ssl, TransOpts, magic_protocol,[]),
	ranch:set_max_connections(princess,MaxWorker).

princess_pipe()->
	{ok,Pipe} = codec_pipeline:new(),
	{ok,PrincessCodec} = princess_codec:new(),
	{ok,FixedLengthCodec} = fixed_length_codec:new(2,16),
	{ok,Pipe1} = codec_pipeline:add_codec(Pipe,fixed_length_codec,FixedLengthCodec),
	codec_pipeline:add_codec(Pipe1,princess_codec,PrincessCodec).