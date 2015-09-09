-module(utp_ets).
-behaviour(gen_server).

%% Public API
-export([start_link/0, new/2, file2tab/1, file2tab/2, give_away/1, watch/1, recover/2]).

%% OTP gen_server Callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
            orphans = dict:new()
        }).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

new(Name, Options) when is_atom(Name) ->
    case lists:member(named_table, Options) of
        true ->
            new({Name, make_ref()}, Options);
        false ->
            error(not_unique, [Name, Options])
    end;

new(Name, Options) when is_tuple(Name) ->
    case gen_server:call(?MODULE, {new, [Name, Options]}) of
        {trapped, Class, Reason} ->
            erlang:Class(Reason);
        Reply ->
            Reply
    end.

file2tab(Filename) ->
    file2tab(Filename, []).

file2tab(Filename, Options) ->
    gen_server:call(?MODULE, {file2tab, Filename, Options}).


give_away(Name) ->
    gen_server:call(?MODULE, {give_away, Name}).

watch(Tab) when is_atom(Tab) ->
    ets:setopts(Tab, {heir, whereis(?MODULE), Tab}).

recover(Name, Opts) ->
    case ?MODULE:give_away(Name) of
        not_found ->
            case recover_from_disk(Opts) of
                not_found ->
                    SafeOpts = ets_new_from_recover_options(Opts),
                    ?MODULE:new(Name, SafeOpts);
                Response -> Response
            end;
        Tab -> {ok, Tab}
    end.

init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

handle_call({new, [{Name, Ref}, DirtyOpts]}, {Owner, _}, State0) ->
    try
        Options = remove_heir_options(DirtyOpts),
        HeirData = case lists:member(named_table, Options) of
            true ->
                Name;
            false ->
                {Name, Ref}
        end,
        Tab = ets:new(Name, [{heir, self(), HeirData} | Options]),
        ets:give_away(Tab, Owner, []),
        {reply, Tab, State0}
    catch
        Class:Pattern ->
            {reply, {trapped, Class, Pattern}, State0}
    end;

handle_call({file2tab, Filename, Options}, {Owner, _}, State0) ->
    case ets:file2tab(Filename, Options) of
        {error, _} = Error ->
            {reply, Error, State0};
        {ok, Tab} = Reply ->
            HeirData = case ets:info(Tab, named_table) of
                true -> Tab;
                false -> {Tab, make_ref()}
            end,

            ets:setopts(Tab, {heir, self(), HeirData}),
            ets:give_away(Tab, Owner, []),
            {reply, Reply, State0}
    end;

handle_call({give_away, Name}, {Owner, _}, State0) ->
    case del_orphan(Name, State0) of
        not_found ->
            {reply, not_found, State0};
        {Tab, State1} ->
            ets:give_away(Tab, Owner, []),
            {reply, Tab, State1}
    end;

handle_call(_Request, _From, State) ->
    Reply = not_implemented,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', _Pid, _Reason}, State) ->
    % handle trapped exit signals from linked processes
    {noreply, State};

handle_info({'ETS-TRANSFER', Tab, _FromPid, HeirData}, State0) ->
    % handle ets table transfers from other processes
    {noreply, add_orphan(HeirData, Tab, State0)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(shutdown, _State) ->
    % handle being ordered to shutdown from supervisor
    ok;

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

recover_from_disk(Opts) ->
    case lists:keyfind(filename, 1, Opts) of
        false ->
            not_found;
        {filename, Filename} ->
            SafeOpts = case lists:keyfind(verify, 1, Opts) of
                false -> [];
                VerifyOpt -> [VerifyOpt]
            end,
            case ?MODULE:file2tab(Filename, SafeOpts) of
                % not sure if erlang will mutate iolists not not, hence _Filename
                {error, {read_error, {file_error, _Filename, enoent}}} ->
                    not_found;
                Response -> Response
            end
    end.

ets_new_from_recover_options(Opts) ->
    lists:keydelete(verify, 1, lists:keydelete(filename, 1, Opts)).

remove_heir_options(Options) ->
    lists:dropwhile(
        fun (E) when is_tuple(E), element(1, E) =:= heir ->
                true;
            (_) ->
                false
        end,
        Options).

add_orphan(Key, Tab, State0) ->
    State0#state{ orphans = dict:store(Key, Tab, State0#state.orphans) }.

del_orphan(Key, #state{ orphans = Orphans }=State0) ->
    case dict:find(Key, Orphans) of
        {ok, Tab} ->
            {Tab, State0#state{ orphans = dict:erase(Key, Orphans) }};
        error ->
            not_found
    end.
