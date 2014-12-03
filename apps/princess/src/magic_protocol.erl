%%%-------------------------------------------------------------------
%%% @author David Alpha Fox <>
%%% @copyright (C) 2014, David Alpha Fox
%%% @doc
%%%
%%% @end
%%% Created : 29 Jul 2014 by David Alpha Fox <>
%%%-------------------------------------------------------------------
-module(magic_protocol).

-behaviour(gen_server).

%% API
-export([start_link/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		 terminate/2, code_change/3]).
-define(SERVER, ?MODULE).
-define(TIMEOUT, 60000).

-define(IPV4, 16#01).
-define(IPV6, 16#04).
-define(DOMAIN, 16#03).

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

handle_cast({socket_ready,ListenerPid, Socket,Transport},State)->,
	ranch:accept_ack(ListenerPid),
	ok = Transport:setopts(Socket, [{active, once}, binary]),
	NewState = State#state{socket = Socket,transport = Transport},
	{noreply,NewState};

handle_cast(_Msg, State) ->
	{noreply, State}.


handle_info({ssl, Socket, Bin},#state{socket = Socket,transport = Transport,buff = Buff} = State) ->
  % Flow control: enable forwarding of next TCP message
  ok = Transport:setopts(Socket, [{active, false}]),
  {Cmds,NewBuff} = protocol_marshal:read(Buff),
  ok = Transport:setopts(Socket, [{active, once}]),
  NewState = State#state{buff = NewBuff},
  {noreply,NewState};

handle_info({ssl_closed, Socket}, #state{socket = Socket} = State) ->
  	{stop, normal, State};

handle_info(timeout,State)->
	{stop,timeout,State};

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
	lager:log(info,?MODULE,"stop"),
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
set_socket(Client,ListenerPid,Socket,Transport) ->
	gen_server:cast(Client, {socket_ready,ListenerPid, Socket,Transport}).
