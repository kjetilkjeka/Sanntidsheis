-module(elev).
-export([start/0]).

start() ->
    DriverManagerPID = spawn(fun() -> driver_manager() end),
    FsmManagerPid = spawn(fun() -> fsm_manager_init() end),

    elev_driver:start(DriverManagerPID),
    FsmPID = fsm:start(FsmManagerPid),
    register(fsm, FsmPID),

    QueuePID = queue:start().

fsm_manager_init() -> % dirty hack, plz fix
    timer:sleep(100), % wait for driver initalization
    fsm_manager().
fsm_manager() ->
    receive
	{motor, up} ->
	    elev_driver:set_motor_direction(up);
	{motor, down} ->
	    elev_driver:set_motor_direction(down);
	{motor, stop} ->
	    elev_driver:set_motor_direction(stop);
	{doors, open} ->
	    elev_driver:set_door_open_lamp(on);
	{doors, close} ->
	    elev_driver:set_door_open_lamp(off)
    end,
    fsm_manager().

driver_manager() ->
    receive
	{new_order, Direcetion, Floor} ->
	    lol;
	{floor_reached, Floor} ->
	    fsm:event_floor_reached(fsm)
    end,
    driver_manager().
