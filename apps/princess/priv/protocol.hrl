

-define(IPV4, 16#01).
-define(IPV6, 16#04).
-define(DOMAIN, 16#03).

-define(DEFAULT_ID,0).

-define(CMD_PING,0).
-define(CMD_CHANNEL,1).
-define(CMD_CONNECT,2).
-define(CMD_DATA,3).
-define(CMD_CLOSE,4).


-record(magic_command,{
		id,
		cmd,
		data
	}).