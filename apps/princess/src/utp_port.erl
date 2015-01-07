%%%-------------------------------------------------------------------
%%% @author davidalphafox <>
%%% @copyright (C) 2015, davidalphafox
%%% @doc
%%%
%%% @end
%%% Created :  7 Jan 2015 by davidalphafox <>
%%%-------------------------------------------------------------------
-module(utp_port).

-behaviour(gen_server2).
-include("utp_packet.hrl").
%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		 terminate/2, code_change/3]).

-record(state, {
		port,
		udp_socket,
		utp_sockets
	}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Args) -
	gen_server2:start_link(?MODULE, Args, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(Args) ->
	Port = proplists:get_value(port,Args),
	case Port of
		undefined ->
			{stop,{error,wrong_port}};
		_->
			{ok,UDPSocket} =  gen_udp:open(Port, [binary, {active, false}]),
			UTPSockets = utp_ets:new({utp_sockets,Port},[set,{read_concurrency,true}]),
			State = #state{
				port = Port,
				udp_socket = UDPSocket,
				utp_sockets =  UTPSockets
			},
			{ok, State}
	end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
	Reply = ok,
	{reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
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
handle_info({udp, Socket, Host, Port, Bin},State)->
	inet:setopts(Socket,[{active, false}]),
	process(Host,Port,Bin,State),
	inet:setopts(Socket,[{active,true}]),
	{noreply,State};
handle_info(_Info, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
	ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
lookup(Key,Tid)->
	case ets:match_object(Tid,Key) of 
		[] ->
			undefined;
		[{Key,UTPSocket}] ->
			UTPSocket
	end.

store({Key,Value},Tid)->
	ets:insert(Tid,{Key,Value}).

send_reset(Host,Port,ConnectionID,Header,State)->
	Packet = utp_protocol:reset_packet(ConnectionID,Header#packet_ver_one_header.seq_nr),
	gen_udp:send(State#state.udp_socket,Host,Port,Packet),
	ok.

process(Host,Port,Bin,State)->
	R = utp_protocol:decode(Bin),
	case R of
		{error,Reason}->
			ok;
		{ok,Packet}->
			process_internal(Host,Port,Packet,State)
	end.
process_internal(Host,Port,Packet,State)->
	{Header,Extensions,Payload} = Packet,
	% id is either our recv id or our send id
	% if it's our send id, and we initiated the connection, our recv id is id + 1
	% if it's our send id, and we did not initiate the connection, our recv id is id - 1
	% we have to check every case
	ConnectionID  = Header#packet_ver_one_header.connection_id,
	Type = Header#packet_ver_one_header.type,
	process_internal(Host,Port,Type,ConnectionID,Header,Extensions,Payload,State).

process_internal(Host,_Port,?UTP_PACKET_ST_RESET,ConnectionID,Header,Extensions,Payload,State)->
	Pid0 = lookup({Host,ConnectionID},State#state.utp_sockets),
	Pid1 = lookup({Host,ConnectionID + 1},State#state.utp_sockets),
	Pid2 = lookup({Host,ConnectionID - 1},State#state.utp_sockets),
	case {Pid0,Pid1,Pid2} of
		{undefined,undefined,undefined}->
			ok;
		{undefined,undefined,_}->
			gen_fsm:send_event(Pid2,{?UTP_PACKET_ST_RESET,Header,Extensions,Payload});
		{undefined,_,_}->
			gen_fsm:send_event(Pid1,{?UTP_PACKET_ST_RESET,Header,Extensions,Payload});
		{_,_,_}->
			gen_fsm:send_event(Pid0,{?UTP_PACKET_ST_RESET,Header,Extensions,Payload})
	end;
	
process_internal(Host,Port,?UTP_PACKET_ST_SYN,ConnectionID,Header,Extensions,Payload,State)->
	Pid = lookup({Host,ConnectionID + 1},State#state.utp_sockets),
	case Pid of
		undefined ->
			try
				UTPSocket = utp_socket_sup:create_socket(Host,Port,self()),
				store({{Host,ConnectionID + 1},UTPSocket},State#state.utp_sockets),
				gen_fsm:send_event(UTPSocket,{?UTP_PACKET_ST_SYN,Header,Extensions,Payload})
			catch 
				_:_ ->
					ok
			end;
		_->
			ok
	end;
process_internal(Host,Port,Type,ConnectionID,Header,Extensions,Payload,State)->
	Pid = lookup({Host,ConnectionID},State#state.utp_sockets),
	case Pid of
		undefined ->
			send_reset(Host,Port,ConnectionID,Header,State);
		_->
			gen_fsm:send_event(Pid,{Type,Header,Extensions,Payload})
	end.