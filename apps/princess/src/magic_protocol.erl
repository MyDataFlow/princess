%%%-------------------------------------------------------------------
%%% @author David Alpha Fox <>
%%% @copyright (C) 2014, David Alpha Fox
%%% @doc
%%%
%%% @end
%%% Created : 29 Jul 2014 by David Alpha Fox <>
%%%-------------------------------------------------------------------
-module(magic_protocol).
-include("priv/protocol.hrl").

-behaviour(gen_server).

%% API
-export([start_link/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		 terminate/2, code_change/3]).
-export([recv_data/3]).
-define(SERVER, ?MODULE).
-define(TIMEOUT, 60000).

-record(state, {
	fetchers,
	socket,
	transport,
	buff
	}).
connect(Pid,Channel)->
	gen_server:cast(Pid,{connect,Channel,Bin}).
recv_data(Pid,Channel,Bin)->
	gen_server:cast(Pid,{recv_data,Channel,Bin}).

start_link(ListenerPid, Socket, Transport, _Opts) ->
	{ok,Pid} = gen_server:start_link(?MODULE, [], []),
	set_socket(Pid,ListenerPid,Socket,Transport),
	{ok,Pid}.

init([]) ->
	State = #state{
		fetchers = ets:new(fetchers, [ordered_set,private]),
		socket = undefined,
		transport = undefined,
		buff = <<>>
	},
	{ok, State}.

handle_call(_Request, _From, State) ->
	Reply = ok,
	{reply, Reply, State}.

handle_cast({socket_ready,ListenerPid, Socket,Transport},State)->
	ranch:accept_ack(ListenerPid),
	ok = Transport:setopts(Socket, [{active, once}, binary]),
	NewState = State#state{socket = Socket,transport = Transport},
	{noreply,NewState};

handle_cast({recv_data,Channel,Bin},State)->
	#state{
		socket = Socket,
		transport = Transport
	} = State,
	try
		Packet = protocol_marshal:write(?RSP_DATA,Channel,Bin),	
		Transport:send(Socket,Packet)
	catch
		_:_Reason ->
  			ok
	end,
	{noreply,State};
handle_cast({connect,Channel},State)->
	#state{
		socket = Socket,
		transport = Transport
	} = State,
	try
		Packet = protocol_marshal:write(?RSP_CONNECT,Channel,undefined),	
		Transport:send(Socket,Packet)
	catch
		_:_Reason ->
  			ok
	end,
	{noreply,State};
handle_cast(_Msg, State) ->
	{noreply, State}.


handle_info({ssl, Socket, Bin},#state{socket = Socket,transport = Transport,buff = Buff} = State) ->
  % Flow control: enable forwarding of next TCP message
  ok = Transport:setopts(Socket, [{active, false}]),
  {Cmds,NewBuff} = protocol_marshal:read(<<Buff/bits,Bin/bits>>),
  NewState = process(Cmds,State),
  ok = Transport:setopts(Socket, [{active, once}]),
  NewState1 = NewState#state{buff = NewBuff},
  {noreply,NewState1};

handle_info({ssl_closed, Socket}, #state{socket = Socket} = State) ->
  	{stop, normal, State};

handle_info(timeout,State)->
	{stop,normal,State};

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

set_socket(Client,ListenerPid,Socket,Transport) ->
	gen_server:cast(Client, {socket_ready,ListenerPid, Socket,Transport}).

address(Data)->
	<<AType:8,AddrLen:32/big,Rest2/bits>> = Data,
	<<Addr:AddrLen/binary,Port:16/big>> = Rest2,
	Address = case AType of
		?IPV4 ->
			erlang:list_to_tuple(erlang:binary_to_list(Addr));
		?DOMAIN ->
			erlang:binary_to_list(Addr)
		end,
	{Address,Port}.

process([],State)->
	State;
process([H|T],State)->
	#state{
		fetchers = Fetchers,
		socket = Socket,
		transport = Transport
		} = State,
	{Data,NewState} = case H of
		{?REQ_PING,_,_}->
			Packet = protocol_marshal:write(?RSP_PONG,undefined,undefined),
			{Packet,State};
		{?REQ_CHANNEL,_,_} ->
			Channel = generator_worker:gen_id(),
			Packet = protocol_marshal:write(?RSP_CHANNEL,undefined,Channel),
			{Packet,State};
		{?REQ_DATA,ID,Payload} ->
			case ets:match_object(Fetchers,{ID,'_'}) of
				[] ->
					Packet = protocol_marshal:write(?RSP_CLOSE,ID,undefined),
					{Packet,State};
				[{ID,Pid}]->
					princess_fetcher:recv_data(Pid,Payload),
					{undefined,State}
				end;
		{?REQ_CONNECT,ID,Payload} ->
			{Address,Port} = address(Payload),
			Fetcher = princess_fetcher:connect(ID,Address,Port),
			case Fetcher of
				undefined ->
					Packet = protocol_marshal:write(?RSP_CLOSE,ID,undefined),
					{Packet,State};
				_ ->
					Packet = protocol_marshal:write(?RSP_CONNECT,ID,undefined),
					ets:insert(Fetchers,{ID,Fetcher}),
					{Packet,State}
				end;
		{?REQ_CLOSE,ID,_} ->
			case ets:match_object(Fetchers,{ID,'_'}) of
				[] ->
					Packet = protocol_marshal:write(?RSP_CLOSE,ID,undefined),
					{Packet,State};
				[{ID,Pid}]->
					princess_fetcher:close(Pid),
					{undefined,State}
				end
		end,
	NewState2 = case Data of
		undefined ->
			NewState;
		_ ->
			Transport:send(Socket,Data),
			NewState
	end,
	process(T,NewState2).