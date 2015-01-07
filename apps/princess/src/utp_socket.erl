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
-export([start_link/0]).

%% gen_fsm callbacks
-export([init/1, state_name/2, state_name/3, handle_event/3,
		 handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-define(SERVER, ?MODULE).
-record(utp_context,{
		state,
		% how much of the window is used, number of bytes in-flight
		% packets that have not yet been sent do not count, packets
		% that are marked as needing to be re-sent (due to a timeout)
		% don't count either
		cur_window,
		last_rcv_window,
		max_window, %maximum window size, in bytes
		sndbuf, %UTP_SNDBUF setting, in bytes
		rcvbuf,	%UTP_RCVBUF setting, in bytes
		conn_seed,
		conn_id_recv,
		conn_id_send,
		reply_micro,
		eof_nr,
		ack_nr,	%All sequence numbers up to including this have been properly received by us
		seq_nr, %This is the sequence number for the next packet to be sent.
		mtu_discover_time = 0,
		mtu_floor = ?UTP_DEFAULT_MTU,
		mtu_ceiling = 0,
		mtu_last = 0,
		mtu_probe_seq = 0,
		mtu_probe_size = 0
	}).
-record(state, {
		udp_pid,
		remote_addr,
		remote_port,
		context
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
start_link() ->
	gen_fsm:start_link(?MODULE, [], []).

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
init([]) ->
	{ok, state_name, #state{}}.

?UTP_STATE_CS_UNINITIALIZED(_Event,State)->
	{next_state, state_name, State}.
?UTP_STATE_CS_SYN_SENT(_Event,State)->
	{next_state, state_name, State}.
?UTP_STATE_CS_CONNECTED(_Event,State)->
	{next_state, state_name, State}.
?UTP_STATE_CS_CONNECTED_FULL(_Event,State)->
	{next_state, state_name, State}.
?UTP_STATE_CS_GOT_FIN(_Event,State)->
	{next_state, state_name, State}.
?UTP_STATE_CS_DESTROY_DELAY(_Event,State)->
	{next_state, state_name, State}.
?UTP_STATE_CS_FIN_SENT(_Event,State)->
	{next_state, state_name, State}.
?UTP_STATE_CS_RESET(_Event,State)->
	{next_state, state_name, State}.
?UTP_STATE_CS_DESTROY(_Event,State)->
	{next_state, state_name, State}.

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
mtu_search_update(Context)->
	MTUFloor = Context#utp_context.mtu_floor,
	MTUCeiling = Context#utp_context.mtu_ceiling,
	MTULast = (MTUFloor + MTUCeiling) / 2,
	if 
		MTUCeiling - MTUFloor =< 16 ->
			MTUDiscoverTime = ?UTP_DEFAULT_DISCOVER_TIME,
			Context#utp_context{
				mtu_discover_time = MTUDiscoverTime,
				mtu_last = MTUFloor,
				mtu_ceiling = MTUFloor,
				mtu_probe_seq = 0,
				mtu_probe_size = 0
			};
		true ->
			Context#utp_context{
				mtu_last = MTULast,
				mtu_probe_seq = 0,
				mtu_probe_size = 0
			}
	end.

mtu_reset(Context)->
	Context#utp_context{
		mtu_discover_time = ?UTP_DEFAULT_DISCOVER_TIME,
		mtu_ceiling = ?UDP_IPV4_MTU,
		mtu_floor = ?UTP_DEFAULT_MTU
	}.

packet_size(Context)->
	MTU = if
		Context#utp_context.mtu_last > 0 ->
			Context#utp_context.mtu_last;
		true ->
			Context#utp_context.mtu_ceiling
		end,
	MTU - ?UTP_PACKET_HEADR_SIZE.

rcv_window(Context)->
	Context#utp_context.rcvbuf.


