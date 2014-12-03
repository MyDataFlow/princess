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
-define(SERVER, ?MODULE).
-define(TIMEOUT, 60000).

-record(state, {
	fetchers,
	socket,
	transport,
	buff
	}).

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
	{stop,timeout,State};

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

set_socket(Client,ListenerPid,Socket,Transport) ->
	gen_server:cast(Client, {socket_ready,ListenerPid, Socket,Transport}).
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
			
