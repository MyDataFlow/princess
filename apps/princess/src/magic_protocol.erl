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
-export([remote_open/3,remote_close/3]).
-define(SERVER, ?MODULE).
-define(TIMEOUT, 60000).

-record(state, {
	fetchers,
	queues,
	socket,
	transport,
	buff
	}).
remote_open(Pid,Fetcher,ID)->
	gen_server:cast(Pid,{remote_open,Fetcher,ID}).
remote_close(Pid,Fetcher,ID)->
	gen_server:cast(Pid,{remote_close,Fetcher,ID}).

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
		fetchers = ets:new(fetchers, [ordered_set,private]),
		queues = ets:new(queues,[ordered_set,private]),
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
handle_cast({remote_open,Fetcher,ID},#state{fetchers = Fetchers,queues = Q} = State)->
	case ets:lookup(Fetchers,ID) of
		[{ID,Fetcher}]->
			case ets:lookup(Q,ID) of
				[] ->
					ok;
				Cmds ->
					RCmds = lists:reverse(Cmds),
					Fun = fun(Cmd)->
						princess_queue:transfer_to_fetcher(Fetcher,Cmd)
					end,
					lists:foreach(Fun,RCmds),
					ets:delete(Q,{ID,[]})
			end;
		[] ->
			ets:insert(Fetchers,{ID,Fetcher})
	end,
	{noreply,State};

handle_cast({remote_close,Fetcher,ID},State)->
	#state{fetchers = Fetchers,queues = Q,socket = Socket,transport = Transport} = State,
	case ets:lookup(Fetchers,ID) of
		[{ID,Fetcher}]->
			ets:delete(Fetchers,ID),
			case ets:lookup(Q,ID) of
				[] ->
					ok;
				[_Any]->
					ets:delete(Q,ID)
			end;
		[] ->
			ok
	end,
	Packet = pack(ID,3,<<>>),
	Transport:send(Socket,Packet),
	{noreply,State};
	
handle_cast({transfer_to_channel,_Fetcher,ID,Bin},#state{socket = Socket,transport = Transport} = State)->
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
  packet(Packet,State),
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

packet([],_State)->
	ok;

packet([<<0:64/integer,0:32/integer>>|T],State)->
	#state{socket = Socket,transport = Transport} = State,
	Data = pack(0,0,<<>>),
	Transport:send(Socket,Data),
	packet(T,State);

packet([<<ID:64/integer,1:32/integer,Rest/bits>>|T],State)->
	<<AddrLen:32/big,Rest2/bits>> = Rest,
	<<Addr:AddrLen/binary,Port:16/big>> = Rest2,
	lager:log(info,?MODULE,"fetch id:~p Addr:~p, Port:~p~n",[ID,Addr,Port]),
	princess_queue:client_open(ID,Addr,Port),
	packet(T,State);

packet([<<ID:64/integer,2:32/integer,Rest/bits>>|T],State)->
	lager:log(info,?MODULE,"more data id:~p Data:~p~n",[ID,Rest]),
	Q = State#state.queues,
	Fetchers = State#state.fetchers,
	case ets:lookup(Fetchers,ID) of
		[{ID,Fetcher}]->
			princess_queue:transfer_to_fetcher(Fetcher,ID,Rest);
		[]->	
			case ets:lookup(Q,ID) of
				[] ->
					NewCmds = [Rest],
					ets:insert(Q,{ID,NewCmds});
				[Cmds] ->
					NewCmds = [Rest | Cmds],
					ets:insert(Q,{ID,NewCmds})
			end
	end,
	packet(T,State);

packet([<<ID:64/integer,3:32/integer,_Rest/bits>>|T],State)->
	lager:log(info,?MODULE,"close id:~p~n",[ID]),
	princess_queue:client_close(ID),
	Q = State#state.queues,
	Fetchers = State#state.fetchers,
	case ets:lookup(Fetchers,ID) of
		[{ID,_Fetcher}]->
			ets:delete(Fetchers,ID);	
		[] ->
			case ets:lookup(Q,ID) of
				[] ->
					ok;
				[_Cmds] ->
					ets:delete(Q,ID)
			end
	end,

	packet(T,State).

pack(ID,OP,Data)->
	lager:log(info,?MODULE,"id:~p op:~p~n",[ID,OP]),
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
