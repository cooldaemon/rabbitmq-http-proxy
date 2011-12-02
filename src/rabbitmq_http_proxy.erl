-module(rabbitmq_http_proxy).

-behaviour(application).
-export([start/2, stop/1]).

-include_lib("amqp_client/include/amqp_client.hrl").

-define(
  SERVER_UNAVAILABLE,
  {503, [{"Content-Type", "text/plain"}], <<"Server Unavailable">>}
).

-define(
  REQUEST_TIMEOUT,
  {408, [{"Content-Type", "text/plain"}], <<"Request Timeout">>}
).

start(_Type, _StartArgs) ->
  {ok, Connection} = amqp_connection:start(#amqp_params_direct{}),
  ProxyQueue = list_to_binary(get_env(queue, "http")),
  declare_proxy_queue(Connection, ProxyQueue),
  Timeout = get_env(request_timeout, 1000 * 60),
  Encoder = mochijson2:encoder([{utf8, true}]),
  rabbit_mochiweb:register_context_handler(
    get_env(context, "proxy"),
    "",
    fun(_, Request) ->
        proxy(Connection, ProxyQueue, Timeout, Encoder, Request)
    end,
    none
  ),
  {ok, spawn(fun loop/0)}.

stop(_State) ->
    ok.

declare_proxy_queue(Connection, ProxyQueue) ->
  {ok, Channel} = amqp_connection:open_channel(Connection),
  amqp_channel:call(Channel, #'queue.declare'{queue = ProxyQueue}),
  amqp_channel:close(Channel).

get_env(Key, Default) ->
  case application:get_env(?MODULE, Key) of
    {ok, Value} -> Value;
    _           -> Default
  end.

proxy(Connection, ProxyQueue, Timeout, Encoder, Request) ->
  Request:respond(
    publish_request_and_consume_response(
      Connection, ProxyQueue, Timeout,
      make_message(Encoder, Request)
    )
  ).

make_message(Encoder, Request) ->
  {_Module, [
    {method,   Method},
    {version,  _Version},
    {raw_path, Path},
    {headers,  Headers}
  ]} = Request:dump(),
  {
    convert_headers(Headers),
    list_to_binary(Encoder({struct, [
      {method, Method},
      {path,   list_to_binary(Path)},
      {body,   get_post(Request)}
    ]}))
  }.

convert_headers(Headers) ->
  lists:map(
    fun ({Key, Value}) ->
      {atom_or_list_to_binary(Key), longstr, list_to_binary(Value)}
    end,
    Headers
  ).

atom_or_list_to_binary(Atom) when is_atom(Atom) ->
  list_to_binary(atom_to_list(Atom));
atom_or_list_to_binary(List) ->
  list_to_binary(List).

get_post(Request) ->
  case Request:recv_body() of
    undefined -> <<"">>;
    Binary    -> Binary
  end.

publish_request_and_consume_response(Connection, ProxyQueue, Timeout, Message) ->
  {ok, Channel} = amqp_connection:open_channel(Connection),
  Queue = declare_receiving_response_queue(Channel),
  publish_request(Channel, ProxyQueue, Queue, Message),
  Response = consume_response(Timeout, Channel, Queue),
  amqp_channel:close(Channel),
  Response. %{Code, ResponseHeaders, Body}

declare_receiving_response_queue(Channel) ->
  #'queue.declare_ok'{queue = Queue} = amqp_channel:call(
    Channel,
    #'queue.declare'{
      exclusive   = true,
      auto_delete = true
    }
  ),
  Queue.

publish_request(Channel, ProxyQueue, Queue, {Headers, Body}) ->
  amqp_channel:cast(
    Channel,
    #'basic.publish'{routing_key = ProxyQueue},
    #amqp_msg{
      props = #'P_basic'{
        content_type = <<"application/json">>,
        headers      = Headers,
        reply_to     = Queue
      },
      payload = Body
    }
  ).

consume_response(Timeout, Channel, Queue) ->
  Ref = make_ref(),
  Consumer = spawn_consumer(Channel, Ref),
  amqp_channel:subscribe(
    Channel,
    #'basic.consume'{
      queue     = Queue,
      no_ack    = true,
      exclusive = true
    },
    Consumer
  ),
  receive
    {Consumer, Ref, Content} -> Content
  after Timeout ->
    % REQUEST_TIMEOUT
    ?SERVER_UNAVAILABLE
  end.

spawn_consumer(Channel, Ref) ->
  Notify = {self(), Ref},
  spawn(fun() -> receive
    #'basic.consume_ok'{consumer_tag = Tag} ->
      drain(Channel, Notify, Tag)
  end end).

drain(Channel, {Parent, Ref}, Tag) ->
  receive
    {
      #'basic.deliver'{consumer_tag = Tag},
      #amqp_msg{
        props   = #'P_basic'{
          headers = Headers,
          app_id  = Code % FIXME
        },
        payload = Content
      }
    } ->
      cancel(Channel, Tag),
      Parent ! {self(), Ref, {
          make_code(Code),
          filter_type(Headers),
          Content
      }}
  end. 

cancel(Channel, Tag) ->
  CancelOk
    = #'basic.cancel_ok'{consumer_tag = Tag}
    = amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = Tag}),
  receive CancelOk -> ok end.

make_code(BinaryCode) ->
  case string:to_integer(binary_to_list(BinaryCode)) of
    {error, no_integer} -> 200;
    {Code,  _Rest}      -> Code
  end.

filter_type(Header) ->
  lists:map(fun ({Key, _Type, Value}) -> {Key, Value} end, Header).

loop() ->
  receive _ -> loop() end.

