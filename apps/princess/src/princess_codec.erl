-module(princess_codec).
-include ("priv/protocol.hrl").
-export ([new/0,encode/2,decode/2]).

-record(princess_codec_context,{
	remain
}).

new()->
	Context = #princess_codec_context{remain = <<>>},
	{ok,Context}.

encode(Context,Data)->
	ID = Data#princess_command.id,
	Cmd = Data#princess_command.cmd,
	Content = Data#princess_command.data,
	{ok,Buff} = princess_encode(ID,Cmd,Content),
	{ok,Buff,Context}.

princess_encode(ID,Cmd,Data)->
	IDBin = binary_marshal:encode(1,ID,sint64),
	CmdBin = binary_marshal:encode(2,Cmd,sint32),
	DataBin = binary_marshal:encode(3,Data,bytes),	
	{ok,<<IDBin/bits,CmdBin/bits,DataBin/bits>>}.

decode(Context,Data)->
	Remain = Context#princess_codec_context.remain,
	NewData = <<Remain/bits,Data/bits>>,
	{ok,Buff,RemainData} = princess_decode(NewData,[]),
	{ok,Buff,Context#princess_codec_context{remain = RemainData}}.

princess_decode(Data,Acc)->
	R = try
		{{1,ID},Rest0} = binary_marshal:decode(Data,sint64),
		{{2,Cmd},Rest1} = binary_marshal:decode(Rest0,sint32),
		{{3,Content},Rest2} = binary_marshal:decode(Rest1,bytes),
		{Rest2,#princess_command{
				id = ID,
				cmd = Cmd,
				data = Content
			}}
	catch 
        _:_Reason ->
        	{ok,lists:reverse(Acc),Data}
    end,
    case R of
    	{ok,NewAcc,Data}->
    		{ok,NewAcc,Data};
    	{Rest,Command}->
    		princess_decode(Rest,[Command|Acc])
    end.
