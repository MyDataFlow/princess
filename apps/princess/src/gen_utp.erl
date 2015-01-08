%%%-------------------------------------------------------------------
%%% @author davidalphafox <>
%%% @copyright (C) 2015, davidalphafox
%%% @doc
%%%
%%% @end
%%% Created :  7 Jan 2015 by davidalphafox <>
%%%-------------------------------------------------------------------
-module(gen_utp).

-behaviour(gen_server2).
-include("utp_packet.hrl").
%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		 terminate/2, code_change/3]).
-export([listen/1,listen/2]).
-export([accept/1,close/1]).

-export([incoming/2]).

-record(accept_queue,{ 
        	waittings      :: queue(),
        	incomings      :: queue(),
        	len            :: integer(),
        	backlog        :: integer() 
        }).

-record(state, {
		port,
        udp_socket,
		disptcher_count,
		cur_dispatcher,
		disptcher_sup,
		utp_sockets,
		utp_socket_monitors,
        utp_socket_sup,
		utp_accepts,
		utp_accept_monitors
	}).

%%%===================================================================
%%% API
%%%===================================================================
listen(Pid,Options) ->
    case validate_listen_opts(Options) of
        ok ->
            call(Pid,{listen, Options});
        badarg ->
            {error, badarg}
    end.

listen(Pid) ->
    listen(Pid,[{backlog, 5}]).

accept(Pid) ->
    {ok, _Socket} = call(Pid,accept).

close({utp_socket, Pid}) ->
    utp_socket:close(Pid);
close(Pid)->
    gen_server2:cast(Pid,close).

incoming(Pid,Msg)->
	gen_server2:cast(Pid,{incoming,Msg}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Args) ->
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
	DisptcherCount = proplists:get_value(disptcher_count,Args,10),
	case Port of
		undefined ->
			{stop,{error,"Can not open UDP."}};
		_->
			{ok,UDPSocket} =  gen_udp:open(Port, [binary, {active, false}]),
			UTPSockets = ets:new(utp_sockets,[set,{read_concurrency,true},public]),
			Pid = self(),
			R1 = supervisor:start_child(utp_sup, dispatcher_sup_spec(Port,
				DisptcherCount,[Pid,UTPSockets,UDPSocket])),
            R2 = supervisor:start_child(utp_sup,utp_socket_sup_spec(Port)),
			case {R1,R2} of 
				{{ok,DisSup},{ok,USocketSup}}->
					State = #state{
						port = Port,
                        udp_socket = UDPSocket,
						disptcher_count = DisptcherCount,
						cur_dispatcher = 1,
						disptcher_sup = DisSup,
						utp_sockets =  UTPSockets,
						utp_socket_monitors = gb_trees:empty(),
                        utp_socket_sup = USocketSup,
						utp_accepts = closed,
						utp_accept_monitors = closed
					},
					{ok, State};
				Error ->
                    terminate_supervisor(Port),
					{stop,Error}
			end
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

handle_call({listen, Options}, _From, #state { utp_accepts = closed } = S) ->
    Backlog = proplists:get_value(backlog, Options),
    {reply, ok, S#state{ utp_accepts = new_acceptor_queue(Backlog),
    	utp_accept_monitors = gb_trees:empty()}};
handle_call({listen, _Opts}, _From, #state { utp_accepts = #accept_queue{} } = S) ->
    {reply, {error, ealreadylistening}, S};


handle_call(accept, _From, #state { utp_accepts = closed } = S) ->
    {reply, {error, no_listen}, S};
handle_call(accept, {Pid,_} = From, #state{ udp_socket = Socket,utp_socket_monitors = SMonitors,
	utp_socket_sup = Sup,utp_accepts = Q,utp_accept_monitors = AMonitors} = S) ->
    {ok, Pairings, NewQ} = add_acceptor(From, Q),
    A1 = demonitor_acceptor(Pid,Pairings,AMonitors),
    NewAMonitors = case A1 of
    			{M,true}->
    				M;
    			{M,false}->
    				Ref = erlang:monitor(process,Pid),
    				gb_trees:enter(Pid,Ref,M)
    			end,
	NewSMonitors = monitor_accepted(Sup,Socket,Pairings,SMonitors),
    {noreply, S#state { utp_accepts = NewQ,utp_socket_monitors = NewSMonitors,
                        utp_accept_monitors = NewAMonitors }};


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
handle_cast({incoming, _SYN}, #state { utp_accepts = closed } = S) ->
    {noreply, S};
handle_cast({incoming, SYN}, #state{ udp_socket = Socket,utp_socket_monitors = SMonitors,
    utp_socket_sup = Sup,utp_accepts = Q,utp_accept_monitors = AMonitors} = S) ->
    case add_incoming(SYN, Q) of
        synq_full ->
            {noreply, S};
        duplicate ->
            {noreply, S};
        {ok, Pairings, NewQ} ->
            A1 = demonitor_acceptor(undefined,Pairings,AMonitors),
            {NewAMonitors,_} =  A1,
            NewSMonitors = monitor_accepted(Sup,Socket,Pairings,SMonitors),
            {noreply, S#state { utp_accepts = NewQ,utp_socket_monitors = NewSMonitors,
                        utp_accept_monitors = NewAMonitors }}
    end;

handle_cast(close,State)->
	Port = State#state.port,
	Socket = State#state.udp_socket,
    terminate_supervisor(Port),
	gen_udp:close(Socket),
	{stop,normal,State};

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

	CurDispatcher = State#state.cur_dispatcher,
	DisptcherCount = State#state.disptcher_count,
	Sup = State#state.disptcher_sup,

	{Pid,N} = next_dispatcher(Sup,CurDispatcher,DisptcherCount),
	utp_dispatcher:dispatch(Pid,{Host,Port,Bin}),
	inet:setopts(Socket,[{active,true}]),

	NewState = State#state{cur_dispatcher = N},
	{noreply,NewState};

handle_info({'DOWN', Ref, process, Pid, _Reason}, State) ->
    AMonitors = State#state.utp_accept_monitors,
    SMonitors = State#state.utp_socket_monitors,
    Tid = State#state.utp_sockets,
    Acceptors = State#state.utp_accepts,
    R1 = gb_trees:lookup(Ref, SMonitors),
    R2 = gb_trees:lookup(Pid,AMonitors),
    NewSMonitors = case R1 of
        {value,V}->
            utp_utils:del_connection(V,Tid),
            gb_trees:delete(Ref,SMonitors);
        _->
            SMonitors
        end,
    {NewAMonitors,NewAcceptors} = case R2 of
        {value,_V} ->
            {gb_trees:delete(Pid,AMonitors),
            del_acceptor(Pid,Acceptors)};
        _->
            {AMonitors,Acceptors}
        end,
    {noreply, State#state {
        utp_socket_monitors = NewSMonitors,
        utp_accepts = NewAcceptors,
        utp_accept_monitors = NewAMonitors
    }};
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
call(Pid,Msg) ->
    gen_server2:call(Pid, Msg, infinity).

dispatcher_sup_spec(Port,DisptcherCount,Opts)
		when is_integer(DisptcherCount) ->
	{{utp_dispatcher_sup, Port}, {utp_dispatcher_sup, start_link, [ 
		Port,DisptcherCount, Opts]},
		permanent, infinity, supervisor, [utp_dispatcher_sup]}.
utp_socket_sup_spec(Port)->
    {{utp_socket_sup, Port}, {utp_socket_sup, start_link, []},
        permanent, infinity, supervisor, [utp_socket_sup]}.

next_one(N,Max)->
	Next = (N + 1) rem Max,
	case Next of
		0 ->
			Max;
		_->
			Next
	end.

next_dispatcher(Sup,N,Max)->
	Children = supervisor:which_children(Sup),
	Child = lists:nth(N,Children),
	{_Id, Pid, _Type, _Modules} = Child,
	case Pid of
		undefined -> 
			Next = next_one(N,Max),
			next_dispatcher(Sup,Next,Max);
		_->
			{Pid,next_one(N,Max)}
	end.

validate_listen_opts([]) ->
    ok;
validate_listen_opts([{backlog, N} | R]) ->
    case is_integer(N) of
        true ->
            validate_listen_opts(R);
        false ->
            badarg
    end;
validate_listen_opts([{force_seq_no, N} | R]) ->
    case is_integer(N) of
        true when N >= 0,
                  N =< 16#FFFF ->
            validate_listen_opts(R);
        true ->
            badarg;
        false ->
            badarg
    end;
validate_listen_opts([{trace_counters, B} | R]) when is_boolean(B) ->
    validate_listen_opts(R);
validate_listen_opts([_U | R]) ->
    validate_listen_opts(R).


new_acceptor_queue(Max) ->
    #accept_queue{ 
    	waittings = queue:new(),
        incomings = queue:new(),
        len = 0,
        backlog = Max }.

add_incoming(_SYNPacket, #accept_queue { len = Len,backlog = Max}) when Len >= Max ->
    overflow_backlog;
add_incoming(SYN, #accept_queue { incomings = I,len = Len} = Q ) ->
    case queue:member(SYN, I) of
        true ->
            duplicate;
        false ->
            try_accept(
              Q#accept_queue {
                incomings = queue:in(SYN, I),
                len   = Len + 1 }, [])
    end.

del_acceptor(Pid,#accept_queue{ waittings = Waittings} = Q)->
   NW = queue:filter(fun({APid,_}) -> APid =/= Pid end,Waittings),
   Q#accept_queue{waittings = NW}.

add_acceptor(From,#accept_queue { waittings = Waittings} = Q) ->
    try_accept(Q#accept_queue{waittings = queue:in(From, Waittings)}, []).

try_accept(#accept_queue { waittings = Waittings,
                             incomings = Incomings,
                              len = Len } = Q, Pairings) ->
    case {queue:out(Waittings), queue:out(Incomings)} of
        {{{value, Acceptor}, W1}, {{value, Packet}, I1}} ->
            try_accept(Q#accept_queue { waittings = W1,
       						incomings = I1,len = Len - 1 },
                        [{Acceptor, Packet} | Pairings]);
        _ ->
            {ok, Pairings, Q} % Can't do anymore work for now
    end.

accept(Sup,Socket,From, {Host,Port,SYN}) ->
    {ok, Pid} = utp_socket_sup:create_utp_socket(Sup,Socket,Host,Port),
    %% We should register because we are the ones that can avoid
    %% the deadlock here
    %% @todo This call can in principle fail due
    %%   to a conn_id being in use, but we will
    %%   know if that happens.
    {Header,_Ext,_Payload} = SYN,
    utp_socket:accept(Pid, SYN),
    gen_server2:reply(From, {ok, {utp_socket, Pid}}),
    {Pid,{Host,Port,Header#packet_ver_one_header.connection_id}}.

demonitor_acceptor(Pid,Pairings,AMonitors)->
	Fun = fun({APid,_ARef},{M0,Has})->
    			case gb_trees:lookup(APid,M0) of
    				{value,V} ->
    					erlang:demonitor(V),
    					{gb_trees:delete(APid,M0),Has};
    				_->
    					case APid of
    						Pid ->
    							{M0,true};
    						_->
    							{M0,false}
    					end
    			end
    		end,
	lists:foldl(Fun,{AMonitors,false},Pairings).

monitor_accepted(Sup,Socket,Pairings,SMonitors)->
 Mappers = [accept(Sup,Socket, Acc, SYN) || {Acc, SYN} <- Pairings],
 lists:foldl(fun({Pid, CID}, Monitors) ->
 			Ref = erlang:monitor(process, Pid),
    		gb_trees:enter(Ref, CID, Monitors)
    	end,SMonitors,Mappers).
terminate_supervisor(Port)->
    supervisor:terminate_child(utp_sup,{utp_socket_sup,Port}),
    supervisor:delete_child(utp_sup,{utp_socket_sup,Port}),
    supervisor:terminate_child(utp_sup,{utp_dispatcher_sup, Port}),
    supervisor:delete_child(utp_sup,{utp_dispatcher_sup, Port}).