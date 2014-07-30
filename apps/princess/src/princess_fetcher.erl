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

-export([client_open/5,client_close/3,channel_close/2]).

-define(OPTIONS,
	[binary,
		{reuseaddr, true},
		{active, once}
  ]).

-define(TIMEOUT,30000).
-record(state, {
		sockets
	}).

%%%===================================================================
%%% API
%%%===================================================================
client_open(Pid,Channel,ID,Address,Port)->
	gen_server:cast(Pid,{client_open,Channel,ID,Address,Port}).
client_close(Pid,Channel,ID)->
	gen_server:cast(Pid,{client_close,Channel,ID}).
channel_close(Pid,Channel)->
	gen_server:cast(Pid,{channel_close,Channel}).
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
	{ok,Pid} = gen_server:start_link(?MODULE, [], []),
	princess_queue:checkin(Pid),
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
	Sockets = ets:new(sockets, [ordered_set,private]),
  State = #state{
  	sockets = Sockets
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
handle_cast({client_open,Channel,ID,Address,Port},State)->

	#state{sockets = Sockets}  = State,
	Addr = erlang:binary_to_list(Address),
	try
		Result = ranch_tcp:connect(Addr, Port, ?OPTIONS, ?TIMEOUT),
		case Result of
  		{ok, TargetSocket} ->
    		ets:insert(Sockets, {TargetSocket,{Channel,ID}}),
    		princess_queue:remote_open(Channel,ID),
    		ranch_tcp:setopts(TargetSocket, [{active, once}]),
    		lager:log(info,?MODULE,"client open id:~p Addr:~p Port:~p",[ID,Address,Port]),
   			{noreply, State};
    	{error, Error} ->
      	princess_queue:remote_close(Channel,ID),
      	{noreply, State}
  	end
  catch
  	_:_Reason ->
  		princess_queue:remote_close(Channel,ID),
  		{noreply, State}
  end;

handle_cast({transfer_to_fetcher,Channel,ID,Bin},State)->
	#state{sockets = Sockets}  = State,
	case ets:match_object(Sockets,{'_',{Channel,ID}}) of
		[{Socket,{Channel,ID}}] ->
			ranch_tcp:send(Socket,Bin),
			lager:log(info,?MODULE,"transfer to fetcher id:~p",[ID]),
			{noreply, State};
    [] ->
    	princess_queue:remote_close(Channel,ID),
	  	{noreply, State}
	end;

handle_cast({client_close,Channel,ID},State)->
	#state{sockets = Sockets}  = State,
	case ets:match_object(Sockets,{'_',{Channel,ID}}) of
		[{Socket,{Channel,ID}}] ->
			ets:delete(Sockets,Socket),
			ranch_tcp:close(Socket),
			lager:log(info,?MODULE,"client close id:~p",[ID]),
			{noreply, State};
    [] ->
	  	{noreply, State}
	end;

handle_cast({channel_close,Channel},State) -> 
	#state{sockets = Sockets}  = State,
	lager:log(info,?MODULE,"channel close channel:~p",[Channel]),
	case ets:match_object(Sockets,{'_',{Channel,'_'}}) of
		[] ->
			{noreply,State};
		Any ->
			channel_loop_close(Any,Sockets),
  		{noreply, State}
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
 	#state{sockets = Sockets}  = State,
	case ets:match_object(Sockets,{Socket,'_'}) of
		[{Socket,{Channel,ID}}] ->
	  	princess_queue:transfer_to_channel(Channel,ID,Bin),
	  	ranch_tcp:setopts(Socket, [{active, once}]),
			{noreply, State};
    [] ->
    	ranch_tcp:close(Socket),
	  	{noreply, State}
	end;

handle_info({tcp_closed, Socket},State) ->
	#state{sockets = Sockets}  = State,
	case ets:match_object(Sockets,{Socket,'_'}) of
		[{Socket,{Channel,ID}}] ->
			ets:delete(Sockets,Socket),
	  	princess_queue:remote_close(Channel,ID),
			{noreply, State};
    [] ->
	  	{noreply, State}
	end;

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
channel_loop_close([],_Sockets)->
	ok;
channel_loop_close([H|T],Sockets)->
	{Socket,{_Channel,_ID}} = H,
	ets:delete(Sockets,Socket),
	ranch_tcp:close(Socket),
	channel_loop_close(T,Sockets).