-module(order_storage). %change to order_distributer or maybe scheduler?, Believe distributer is better than scheduler
-compile(export_all).

-record(order, {floor, direction}).

-define(PROCESS_GROUP_NAME, order_distributers).
-define(DETS_TABLE_NAME, "orders").

% this should maybe be done with dict so it can map from order to handler

%% API
%%%%%%%%%%

add_order(Floor, Direction) ->
    HandlingScheduler = if 
			    (Direction == up) or (Direction == down) -> 
				schedule_order(Floor, Direction); % should maybe happend isolated from caller ? it might deadlock ? maybe it's better crash the caller as well?
			    Direction == command ->
				ClosestScheduler = pg2:get_closest_pid(?PROCESS_GROUP_NAME),  
				NodeForClosesScheduler = node(ClosestScheduler), % the crash if not on same node can maybe be done nicer. What if no process exists?
				NodeForClosesScheduler = node(),
				ClosestScheduler
			end,
    Self = self(),
    Order = #order{floor=Floor, direction=Direction},
    AddOrderFunction = fun(OrderDistributorPid) ->
			       OrderDistributorPid ! {add_order, Order, HandlingScheduler, Self}
		       end,
    foreach_distributer(AddOrderFunction).

remove_order(Floor, Direction) ->
    Self = self(),
    Order = #order{floor=Floor, direction=Direction},
    AddOrderFunction = fun(OrderDistributorPid) ->
			       OrderDistributorPid ! {remove_order, Order, Self}
		       end,
    foreach_distributer(AddOrderFunction).


is_order(Floor, Direction) ->
    Order = #order{floor=Floor, direction=Direction},
    ClosestDistributer = pg2:get_closest_pid(?PROCESS_GROUP_NAME),
    ClosestDistributer ! {is_order, Order, self()},
    receive
	{is_order, Order, Response} ->
	    Response
    end.

get_orders(Pid) -> %function for debug only
    Pid ! {get_orders, self()},
    receive
	{orders, Orders} ->
	    Orders
    end.


%% Callbacks
%%%%%%%%%%%

request_bid(Floor, Direction) ->
    get(listener) ! {bid_request, Floor, Direction, self()},
    receive 
	{bid_price, Price} ->
	    Price
    end.

handle_order(Order) -> % the world might have seen better names than handle_order
    get(listener) ! {handle_order, Order#order.floor, Order#order.direction, self()}.

%% process functions
%%%%%%%%%%%%%%%


start(Listener) ->
    spawn(fun() -> init(Listener) end).

init(Listener) ->
    put(listener, Listener),
    init_dets(),
    join_process_group(),
    Orders = add_orders_from_dets(dict:new()),
    reschedule_orders_async(Orders),
    loop(Orders).

loop(Orders) -> % OrderMap maps orders to something descriptive
    receive
	upgrade ->
	    ?MODULE:loop(Orders);
	{request_bid, Floor, Direction, Caller} ->
	    Price = request_bid(Floor, Direction), % this may cause deadlock if request bid fucks up
	    Caller ! {bid_price, Price, self()},
	    loop(Orders);						       
	{is_order, Order, Caller} ->
	    Response = is_in_orders(Orders, Order, self()),
	    Caller ! {is_order, Order, Response},
	    loop(Orders);
	{remove_order, Order, _Caller} ->
	    NewOrders = remove_from_orders(Orders, Order, self()),
	    remove_from_dets(Order),
	    loop(NewOrders);
	{add_order, Order, Handler, _Caller} ->
	    add_to_dets(Order),
	    NewOrders = add_to_orders(Orders, Order, Handler),
	    case Handler == self() of
		true ->
		    handle_order(Order);
		false ->
		    do_nothing
	    end,
	    loop(NewOrders);
	{get_orders, Caller} -> % for debug only
	    Caller ! {orders, Orders},
	    loop(Orders)
    end.
    

%% functions for scheduling order
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

reschedule_orders_async(Orders) -> % a bit messy, fix plz
    Reschedule = fun(Order, _Handler) ->
			 BidWinner = schedule_order(Order#order.floor, Order#order.direction),
			 Self = self(),
			 AddOrderFunction = fun(OrderDistributorPid) ->
						    OrderDistributorPid ! {add_order, Order, BidWinner, Self}
					    end,
			 foreach_distributer(AddOrderFunction)
		 end,

    spawn(fun() -> foreach_order(Orders, Reschedule) end). % plz make this safer by timing and killing
 		  
    

    
% should maybe take order record since it's called reschedule_!order!
% many io:formats here for debugging, consider removing at the end.
schedule_order(Floor, Direction) -> % may cause deadlock if members change between calls
    io:format("Order auction started on order Floor: ~w, Direction: ~w ~n", [Floor, Direction]),
    Self = self(),
    RequestBidFunction = fun(Member) ->
				 Member ! {request_bid, Floor, Direction, Self}
			 end,
    foreach_distributer(RequestBidFunction),
    AllMembers = pg2:get_members(?PROCESS_GROUP_NAME),
    io:format("Members are ~w ~n", [AllMembers]),
    Bids = receive_bids(AllMembers),
    io:format("Bids are ~w ~n", [Bids]),
    {_LeastBid, WinningMember} = lists:min(Bids),
    io:format("Winning member is ~w ~n", [WinningMember]),
    WinningMember.


receive_bids([]) ->
    [];
receive_bids(MembersNotCommited) ->
    receive 
	{bid_price, Price, Handler} ->
	    [{Price, Handler}|receive_bids(lists:delete(Handler, MembersNotCommited))]
    end.


%% Functions encapsulating what datatype Orders realy is
%%%%%%%%%%%%%%%%

add_to_orders(Orders, Order, Handler) -> dict:append(Order, Handler, Orders).

%this is not the nicest construct of a function in the world. Pretty many ifs and cases. !!!!!!Should do this with pattern matching ofcourse!!!!
remove_from_orders(Orders, Order, Handler) -> %pretty simuliar construct as is_in_order, possible to do more general?
    if 
	Order#order.direction == command ->
	    case dict:is_key(Order, Orders) of
		true ->
		    Handlers = dict:fetch(Order, Orders),
		    NewHandlers = lists:delete(Handler, Handlers),
		    DictWithoutOrder = dict:erase(Order, Orders),
		    dict:append_list(Order, NewHandlers, DictWithoutOrder);
		
		false ->
		    false
	    end;
	(Order#order.direction == up) or (Order#order.direction == down) ->
	    dict:erase(Order, Orders)
    end.

% do this with pattern matching instead
is_in_orders(Orders, Order, Handler) -> 
    if 
	Order#order.direction == command ->
	    case dict:is_key(Order, Orders) of
		true ->
		    Handlers = dict:fetch(Order, Orders),
		    lists:member(Handler, Handlers);
		false ->
		    false
	    end;
	(Order#order.direction == up) or (Order#order.direction == down) ->
	    dict:is_key(Order, Orders)
    end.
	
%Function(Order, Handler)
foreach_order(Orders, Function) -> 
    F = fun({Order, Handler}) -> Function(Order, Handler) end,
    lists:foreach(F, dict:to_list(Orders)).
     

%% Communication/Synchronization procedures
%%%%%%%%%%%%%%%%%%%

join_process_group() -> % need maybe better name?
    pg2:create(?PROCESS_GROUP_NAME),
    pg2:join(?PROCESS_GROUP_NAME, self()).

%F(OrderDistributor)
foreach_distributer(Function) -> % maybe foreach_member
    OrderDistributers = pg2:get_members(?PROCESS_GROUP_NAME),
    lists:foreach(Function, OrderDistributers).


%% Functions interfacing the disc copy
%%%%%%%%%%%%%%%%%%%%%

init_dets() ->
    dets:open_file(?DETS_TABLE_NAME, [{type,bag}]).

add_to_dets(Order) ->
    dets:insert(?DETS_TABLE_NAME, Order).

remove_from_dets(Order) ->
    dets:delete_object(?DETS_TABLE_NAME, Order).

add_orders_from_dets(Orders) ->
    %consider removing all non order elements first
    Self = self(),
    AddOrderFunction = fun(Order, Orders) -> add_to_orders(Orders, Order, Self) end, %shadowed warning, maybe find better name?
    dets:foldl(AddOrderFunction, Orders, ?DETS_TABLE_NAME).
