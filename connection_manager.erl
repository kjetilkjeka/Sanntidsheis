-module(connection_manager).
-compile(export_all).

-define(SEND_PORT, 5678).
-define(RECV_PORT, 5677).
%-define(COOKIE, "erlang"). 
-define(SEEK_PERIOD, 5000).


start_auto_discovery() ->
    spawn(fun() -> listen_for_connections() end),
    spawn(fun() -> broadcast_loop() end).
		  
		  


listen_for_connections() ->
    {ok, RecvSocket} = gen_udp:open(?RECV_PORT, [list, {active,false}]), % socket will never close?
    listen_for_connections(RecvSocket).    
listen_for_connections(RecvSocket) ->
    {ok, {_Adress, ?SEND_PORT, NodeName}} = gen_udp:recv(RecvSocket, 0), % kan kresje dersom SEND_PORT er feil
    Node = list_to_atom(NodeName),
    case is_in_cluster(Node) of % maybe this test is useless? just try to connect anyway?
	true ->
	    listen_for_connections(RecvSocket);
	false ->
	    connect_to_node(Node),
	    listen_for_connections(RecvSocket)
    end.


is_in_cluster(Node) ->
    NodeList = [node()|nodes()],
    lists:member(Node, NodeList).

connect_to_node(Node) ->
    net_adm:ping(Node). %might be not very intuitive return value, should maybe crash if not possible


broadcast_loop() ->
    {ok, Socket} = gen_udp:open(?SEND_PORT, [list, {active,true}, {broadcast, true}]),
    broadcast_loop(Socket).
broadcast_loop(SendSocket) ->
    ok = gen_udp:send(SendSocket, {255,255,255,255}, ?RECV_PORT, atom_to_list(node())),
    timer:sleep(?SEEK_PERIOD),
    broadcast_loop(SendSocket).

    