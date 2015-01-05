-module(hm_mnesia).
-export([mneisa_dir/0,ensure_mnesia_dir/0]).
-export([ensure_schema/0,persist_schema/0,ensure_mnesia/0]).

mneisa_dir() ->
	mnesia:system_info(directory).

ensure_mnesia_dir() ->
    MnesiaDir = mneisa_dir() ++ "/",
    case filelib:ensure_dir(MnesiaDir) of
        {error, Reason} ->
            throw({error, {cannot_create_mnesia_dir, MnesiaDir, Reason}});
        ok ->
            ok
    end.


ensure_schema()->
	case mnesia:system_info(is_running) of
		yes ->
			application:stop(mnesia),
			ok = mnesia:create_schema([node()]),
			application:start(mnesia);
		_->
			ok = mnesia:create_schema([node()]),
			application:start(mnesia)
		end.

persist_schema()->
	StorageType = mnesia:table_info(schema, storage_type),
	if 
		StorageType /= disc_copies ->
			case mnesia:change_table_copy_type(schema, node(), disc_copies) of
				{atomic, ok}->
      				true;
      			{aborted, _R}->
      				false
     		end;
    	true -> 
     		true
  	end.

ensure_mnesia()->
	ensure_mnesia_dir(),
	application:start(mnesia),
	case persist_schema() of
		true ->
			ok;
		false ->
			ensure_schema()
	end.
	
