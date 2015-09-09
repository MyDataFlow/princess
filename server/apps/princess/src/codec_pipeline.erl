-module(codec_pipeline).
-export([new/0,add_codec/3,pipe_in/2,pipe_out/2]).
%%-callback pipe(tuple()) -> {ok,tuple()} | {error,tuple()}.

-record(codec_pipeline_context, {
			codecs 
		}).

new()->
	{ok,#codec_pipeline_context {
		codecs = []
	}}.


add_codec(Context,Codec,CodecContext)->
	Codecs = Context#codec_pipeline_context.codecs,
	Codecs1 = [{Codec,CodecContext}|Codecs],
	{ok,Context#codec_pipeline_context{codecs = Codecs1}}.

pipe_in(Context,Data)->
	Codecs = Context#codec_pipeline_context.codecs,
	Fun = fun(E, R)->
		{Codec,CodecContext} = E,
		{ok,Buff,NewCodecContext} = Codec:decode(CodecContext,R),
		{{Codec,NewCodecContext},Buff}
	end,
	{NewCodecs,Result} = lists:mapfoldr(Fun,Data,Codecs),
	{ok,Result,Context#codec_pipeline_context{codecs = NewCodecs}}.

pipe_out(Context,Data)->
	Codecs = Context#codec_pipeline_context.codecs,
	Fun = fun(E, R)->
		{Codec,CodecContext} = E,
		{ok,Buff,NewCodecContext} = Codec:encode(CodecContext,R),
		{{Codec,NewCodecContext},Buff}
	end,
	{NewCodecs,Result} = lists:mapfoldl(Fun,Data,Codecs),
	{ok,Result,Context#codec_pipeline_context{codecs = NewCodecs}}.
