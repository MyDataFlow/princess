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

start_link() ->
	gen_server:start_link(?MODULE, [], []),

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
    		magic_protocol:connected(Parent,Channel),
   			{noreply, NewState};
    	{error, Error} ->
   			{stop,normal,State}
  	end
  catch
  	_:_Reason ->
  		{stop,normal,State}
  end;

handle_cast({data,Bin},State)->
	#state{socket = Socket}  = State,
	ranch_tcp:send(Socket,Bin)
	{noreply,State};

handle_cast({close,Channel},State)->
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
    	channel = Channel,
    	socket = TargetSocket
    	} = State,
    magic_protocol:recv_data(Parent,Channel,Data),
    ranch_tcp:setopts(Socket, [{active, once}]),
    {noreply, State};

handle_info({tcp_closed, Socket},State) ->
	{stop,normal,State};

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
