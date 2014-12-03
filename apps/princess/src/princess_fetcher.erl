%%%-------------------------------------------------------------------
%%% @author David Alpha Fox <>
%%% @copyright (C) 2014, David Alpha Fox
%%% @doc
%%%
%%% @end
%%% Created : 29 Jul 2014 by David Alpha Fox <>
%%%-------------------------------------------------------------------
-module(princess_fetcher).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		 terminate/2, code_change/3]).

-export([connect/3,recv_data/2,close/1]).

-define(OPTIONS,
	[binary,
		{reuseaddr, true},
		{active, once}
  ]).

-define(TIMEOUT,30000).
-record(state, {
		parent,
		channel,
		socket
	}).

connect(Channel,Address,Port)->
	Parent = self(),
	R = start_link(),
	case R of
		{ok,Pid}->
			gen_server:cast(Pid,{connect,Parent,Channel,Address,Port}),
			Pid;
		_->
			undefined
	end.

recv_data(Pid,Data)->
	gen_server:cast(Pid,{recv_data,Data}).
close(Pid)->
	gen_server:cast(Pid,{close}).

start_link() ->
	gen_server:start_link(?MODULE, [], []).

init([]) ->   
	State = #state{
		parent = undefined,
		channel = undefined,
  		socket = undefined
  	},
  	{ok, State}.

handle_call(_Request, _From, State) ->
	Reply = ok,
	{reply, Reply, State}.

handle_cast({connect,Parent,Channel,Address,Port},State)->
	try
		Result = ranch_tcp:connect(Address, Port, ?OPTIONS, ?TIMEOUT),
		case Result of
  		{ok, TargetSocket} ->
    		ranch_tcp:setopts(TargetSocket, [{active, once}]),
    		NewState = #state{
    			parent = Parent,
    			channel = Channel,
    			socket = TargetSocket
    			},
    		magic_protocol:connect(Parent,Channel),
   			{noreply, NewState};
    	{error, Error} ->
   			{stop,error,State}
  	end
  catch
  	_:_Reason ->
  		{stop,error,State}
  end;

handle_cast({recv_data,Bin},State)->
	#state{socket = Socket}  = State,
	ranch_tcp:send(Socket,Bin),
	{noreply,State};

handle_cast({close},State)->
	#state{socket = Socket}  = State,
	try
		ranch_tcp:close(Socket),
		{stop,normal,State}
	catch
  		_:_Reason ->
  			{stop,normal,State}
  	end;

handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({tcp, Socket, Bin},State)->
 	ranch_tcp:setopts(Socket, [{active, false}]),
 	#state{
   		parent = Parent,
    	channel = Channel
    	} = State,
    magic_protocol:recv_data(Parent,Channel,Bin),
    ranch_tcp:setopts(Socket, [{active, once}]),
    {noreply, State};

handle_info({tcp_closed, _Socket},State) ->
	{stop,close,State};

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, State) ->
	#state{socket = Socket}  = State,
	try
		ranch_tcp:close(Socket),
		ok
	catch
  		_:_Reason ->
  			ok
  	end.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
