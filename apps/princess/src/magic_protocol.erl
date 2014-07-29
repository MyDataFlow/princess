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
-export([remote_close/2,to_fog/3]).
-define(SERVER, ?MODULE).
-define(TIMEOUT, 60000).

-record(state, {
	socket,
	transport,
	buff
	}).
remote_close(Pid,ID)->
	gen_server:cast(Pid,{remote_close,ID}).
to_fog(Pid,ID,Bin)->
	gen_server:cast(Pid,{to_fog,ID,Bin}).

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
start_link(ListenerPid, Socket, Transport, _Opts) ->
	{ok,Pid} = gen_server:start_link(?MODULE, [], []),
	lager:log(info,?MODULE,"start_link ~n"),
	set_socket(Pid,ListenerPid,Socket,Transport),
	{ok,Pid}.

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
init([]) ->
	State = #state{
		socket = undefined,
		transport = undefined,
		buff = <<>>
	},
	{ok, State}.

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

handle_cast({socket_ready,ListenerPid, Socket,Transport},State)->
	lager:log(info,?MODULE,"socket_ready~n"),
	ranch:accept_ack(ListenerPid),
	ok = Transport:setopts(Socket, [{active, once}, binary]),
	NewState = State#state{socket = Socket,transport = Transport},
	{noreply,NewState};

handle_cast({remote_close,ID},#state{socket = Socket,transport = Transport} = State)->
	Packet = pack(ID,3,<<>>),
	Transport:send(Socket,Packet),
	{noreply,State};
handle_cast({to_fog,ID,Bin},#state{socket = Socket,transport = Transport} = State)->
	Packet = pack(ID,2,Bin),
	Transport:send(Socket,Packet),
	{noreply,State};
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
handle_info({ssl, Socket, Bin},#state{socket = Socket,transport = Transport,buff = Buff} = State) ->
  % Flow control: enable forwarding of next TCP message
  ok = Transport:setopts(Socket, [{active, false}]),
  {Packet,NewBuff} = unpack(<<Buff/bits,Bin/bits>>,[]),
  packet(Packet,Socket,Transport),
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

packet([],_Socket,_Transport)->
	ok;
packet([<<0:64/integer,0:32/integer>>|T],Socket,Transport)->
	lager:log(info,?MODULE,"ping~n"),
	Data = pack(0,0,<<>>),
	Transport:send(Socket,Data),
	packet(T,Socket,Transport);
packet([<<ID:64/integer,1:32/integer,Rest/bits>>|T],Socket,Transport)->
	lager:log(info,?MODULE,"fetch~n"),
	<<AddrLen:32/big,Rest2/bits>> = Rest,
	<<Addr:AddrLen/binary,Port:16/big>> = Rest2,
	Pid = self(),
	princess_fetcher:fetch(Pid,ID,Addr,Port),
	packet(T,Socket,Transport);
packet([<<ID:64/integer,2:32/integer,Rest/bits>>|T],Socket,Transport)->
	lager:log(info,?MODULE,"more data~n"),
	Pid = self(),
	princess_fetcher:to_free(Pid,ID,Rest),
	packet(T,Socket,Transport);
packet([<<ID:64/integer,3:32/integer,_Rest/bits>>|T],Socket,Transport)->
	lager:log(info,?MODULE,"close~n"),
	Pid = self(),
	princess_fetcher:client_close(Pid,ID),
	packet(T,Socket,Transport).

pack(ID,OP,Data)->
	R1 = <<ID:64/integer,OP:32/integer,Data/bits>>,
	Len = erlang:byte_size(R1),
	<<Len:32/big,R1/bits>>.

unpack(Data,Acc) when byte_size(Data) < 4 ->
	{lists:reverse(Acc),Data};
unpack(<<Len:32/big,PayLoad/bits>> = Data,Acc) when Len > byte_size(PayLoad) ->
	{lists:reverse(Acc),Data};
unpack(<<Len:32/big, _/bits >> = Data, Acc) ->                                                                                                                                                                                                                                                 
  << _:32/big,Packet:Len/binary, Rest/bits >> = Data,
  unpack(Rest,[Packet|Acc]).
