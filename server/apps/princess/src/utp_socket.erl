%%%-------------------------------------------------------------------
%%% @author davidalphafox <>
%%% @copyright (C) 2015, davidalphafox
%%% @doc
%%%
%%% @end
%%% Created :  6 Jan 2015 by davidalphafox <>
%%%-------------------------------------------------------------------
-module(utp_socket).
-include("utp.hrl").
-include("utp_packet.hrl").

-behaviour(gen_fsm).

%% API
-export([start_link/1]).

%% gen_fsm callbacks
-export([init/1, state_name/2, state_name/3, handle_event/3,
		 handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).
-export([idle/2,idle/3]).

-record(utp_context,{
		remote_addr,
		remote_port,
		conn_id_recv,
		conn_id_send
	}).
-record(state, {
		udp_socket,
		retransmit_timeout,
		connector,
		utp_mtu_context,
		utp_wnd_context,
		utp_buffer_context,
		utp_context
	}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this
%% function does not return until Module:init/1 has returned.
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(UDPSocket) ->
	gen_fsm:start_link(?MODULE, [UDPSocket], []).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/[3,4], this function is called by the new
%% process to initialize.
%%
%% @spec init(Args) -> {ok, StateName, State} |
%%                     {ok, StateName, State, Timeout} |
%%                     ignore |
%%                     {stop, StopReason}
%% @end
%%--------------------------------------------------------------------
init([UDPSocket]) ->
	MTUContext = utp_mtu:new(),
	UTPContext = #utp_context{},
	WndContext = utp_window:new(),
	BufferContext = utp_buffer:new(),
	State = #state{
		udp_socket = UDPSocket,
		connector = undefined,
		utp_mtu_context = MTUContext,
		utp_wnd_context = WndContext,
		utp_buffer_context = BufferContext,
		utp_context = UTPContext
	},
	{ok,idle,State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same
%% name as the current state name StateName is called to handle
%% the event. It is also called if a timeout occurs.
%%
%% @spec state_name(Event, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
idle(close, S) ->
    {next_state,destroy, S, 0};
idle(_Msg, S) ->
    {next_state, idle, S}.

state_name(_Event, State) ->
	{next_state, state_name, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/[2,3], the instance of this function with
%% the same name as the current state name StateName is called to
%% handle the event.
%%
%% @spec state_name(Event, From, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------

idle({connect,Host,Port,ConnectionID},From, State = #state {
	connector = undefined,utp_mtu_context = MTU,
	utp_wnd_context = Wnd,utp_buffer_context = Buffer,utp_context = Context}) ->
    NewContext = Context#utp_context{
    	remote_addr = Host,
    	remote_port = Port,
    	conn_id_recv = ConnectionID,
    	conn_id_send = ConnectionID + 1
    },
    MaxWnd = utp_mtu:packet_size(MTU),
    NewWnd = utp_window:update_max_window(Wnd,MaxWnd),
    SeqNo = utp_util:random_id(),
    NewBuffer = utp_buffer:set_seq(Buffer,SeqNo + 1),
    %send sync
    RTO = set_retransmit_timer(utp_window:rto(NewWnd), undefined),
    {next_state, syn_sent,
    State#state{ retransmit_timeout = RTO, 
                  connector = 	From,
                  utp_wnd_context = NewWnd,
                  utp_buffer_context  = NewBuffer,
                  utp_context = NewContext
                }};

idle({accept, {Host,Port,SYN}}, _From, #state {connector = undefined,
	utp_wnd_context = Wnd,utp_buffer_context = Buffer,utp_context = Context} = State) ->
    ConnSndID = SYN#packet_ver_one_header.connection_id,
    ConnRCVID = ConnSndID + 1,

    NewContext = Context#utp_context{
    	remote_addr = Host,
    	remote_port = Port,
    	conn_id_recv = ConnRCVID,
    	conn_id_send = ConnSndID
    },
    SeqNo = utp_util:random_id(),
    AdvertisedWindow = SYN#packet_ver_one_header.wnd_size,
    NewWnd = utp_window:update_advertised_window(Wnd,AdvertisedWindow),
    Buffer0 = utp_buffer:set_ack(Buffer,SYN#packet_ver_one_header.ack_nr + 1),
    NewBuffer = utp_buffer:set_ack(Buffer0,SeqNo + 1),
    %send ack
    %% @todo retransmit timer here?
    start_tick_timer(),
    {reply, ok, connected,
            State#state {utp_wnd_context = NewWnd,
            	utp_buffer_context = NewBuffer,
            	utp_context = NewContext}};

idle(_Msg, _From, State) ->
    {reply, idle, {error, enotconn}, State}.

state_name(_Event, _From, State) ->
	Reply = ok,
	{reply, Reply, state_name, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%
%% @spec handle_event(Event, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
	{next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/[2,3], this function is called
%% to handle the event.
%%
%% @spec handle_sync_event(Event, From, StateName, State) ->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {reply, Reply, NextStateName, NextState} |
%%                   {reply, Reply, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState} |
%%                   {stop, Reason, Reply, NewState}
%% @end
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
	Reply = ok,
	{reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it receives any
%% message other than a synchronous or asynchronous event
%% (or a system message).
%%
%% @spec handle_info(Info,StateName,State)->
%%                   {next_state, NextStateName, NextState} |
%%                   {next_state, NextStateName, NextState, Timeout} |
%%                   {stop, Reason, NewState}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, StateName, State) ->
	{next_state, StateName, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_fsm when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%
%% @spec terminate(Reason, StateName, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) ->
	ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
	{ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

set_retransmit_timer(N, Timer) ->
    set_retransmit_timer(N, N, Timer).
set_retransmit_timer(N, K, undefined) ->
    Ref = gen_fsm:start_timer(N, {retransmit_timeout, K}),
    {set, Ref};
set_retransmit_timer(N, K, {set, Ref}) ->
    gen_fsm:cancel_timer(Ref),
    NewRef = gen_fsm:start_timer(N, {retransmit_timeout, K}),
    {set, NewRef}.

clear_retransmit_timer(undefined) ->
    undefined;
clear_retransmit_timer({set, Ref}) ->
    gen_fsm:cancel_timer(Ref),
    undefined.

start_tick_timer()->
	gen_fsm:start_timer(500, tick_timer).