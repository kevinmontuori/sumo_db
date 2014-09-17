-module('20140903_mig').

-behavior(sumo_migration).

-export([up/0, down/0]).

up() ->
    io:format("=== ~p up/0~n", [?MODULE]),
    ok.

down() ->
    io:format("=== ~p down/0~n", [?MODULE]),
    ok.