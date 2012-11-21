%% -*- coding: utf-8; mode: erlang -*-
%% @copyright 2012 Göran Weinholt
%% @author Göran Weinholt <goran@weinholt.se>
%% @doc The driving algorithm in the supercompiler.

-module(scp_main).
-export([drive/3]).

-include("scp.hrl").

lookup_function(Env, K={Name,Arity}) ->
    %% TODO: use local here and recognize letrecs in drive
    case dict:find(K, Env#env.global) of
        {ok,Fun} ->
            {ok,Fun};
        _ ->
            dict:find(K, Env#env.global)
    end.

head_variables(Head) ->
    sets:from_list(lists:flatmap(fun scp_pattern:pattern_variables/1, Head)).

extend_bound(Env,Vars) ->
    Env#env{bound=sets:union(Env#env.bound, Vars)}.

%% The driving algorithm. The environment is used to pass information
%% downwards and upwards the stack. R is the current context.

%% Evaluation rules.
drive(Env0, E={T,_,_}, R=[#case_ctxt{clauses=Cs0}|_])
  when T=='integer'; T=='float'; T=='atom'; T=='string'; T=='char' -> %R1
    drive_const_case(Env0, E, R);
drive(Env0, E={nil,_}, R=[#case_ctxt{clauses=Cs0}|_]) -> %R1
    drive_const_case(Env0, E, R);
drive(Env0, E={tuple,_,[]}, R=[#case_ctxt{clauses=Cs0}|_]) -> %R1
    drive_const_case(Env0, E, R);

drive(Env0, E2={T,_,_}, Ctxt=[#op_ctxt{line=L, op=Op, e1=E1, e2=hole}|R])
  when T=='integer'; T=='float'; T=='atom'; T=='string'; T=='char' -> %R2
    case scp_expr:apply_op(L, Op, E1, E2) of
        {ok,V} -> drive(Env0, V, R);
        _ -> build(Env0, E2, Ctxt)
    end;
drive(Env0, E1={T,_,_}, Ctxt=[#op1_ctxt{line=L, op=Op}|R])
  when T=='integer'; T=='float'; T=='atom'; T=='string'; T=='char' -> %R2
    case scp_expr:apply_op(L, Op, E1) of
        {ok,V} -> drive(Env0, V, R);
        _ -> build(Env0, E1, Ctxt)
    end;

drive(Env0, E={'atom',L0,G}, R=[#call_ctxt{args=Args}|_]) -> %R3
    %% This is a function call to a local function or a BIF.
    Arity = length(Args),
    case lookup_function(Env0, {G, Arity}) of
        {ok,Fun} -> drive_call(Env0, E, L0, G, Arity, Fun, R);
        _ -> drive_BIF(Env0, E, R)
    end;
drive(Env0, E={'fun',Lf,{function,G,Arity}}, R=[#call_ctxt{args=Args}|_])
  when length(Args) == Arity -> %R3
    drive(Env0, {'atom',Lf,G}, R);
%% TODO: R3 for 'fun' in any context
%% TODO: R3 for {remote,_,{atom,_,lists},{atom,_,flatten}} and so on.

drive(Env0, E, R=[#case_ctxt{clauses=Cs0}|_])
  when element(1,E) == 'cons'; element(1,E) == 'tuple';
       element(1,E) == 'bin'; element(1,E) == 'record';
       element(1,E) == 'op' -> %R4
    drive_constructor_case(Env0, E, R);

drive(Env0, {'fun',Lf,{clauses,Cs0}}, [#call_ctxt{line=Lc,args=As}|R]) -> %R5
    %% This is how inlining happens. The original rule uses a let, but
    %% the equivalent rule for Erlang must use an alpha-converted case
    %% (at least if the patterns for the arguments aren't simple).
    %%    (fun (X,Y) -> X) (1,2).
    %% => case {1,2} of {X,Y} -> X end.
    %% FIXME: check that the arity matches
    E = {tuple,Lc,As},
    Cs = lists:map(fun ({clause,Line,H0,G0,B0}) ->
                           {clause,Line,[{tuple,Line,H0}],G0,B0}
                   end,
                   Cs0),
    {Env,Case} = scp_expr:alpha_convert(Env0, scp_expr:make_case(Lf,E,Cs)),
    drive(Env, Case, R);

drive(Env0, {'fun',Line,{clauses,Cs0}}, R) ->   %R6
    {Env,Cs} = drive_clauses(Env0, Cs0),
    build(Env, {'fun',Line,{clauses,Cs}}, R);

drive(Env0, E={var,_,Rhs}, R=[#case_ctxt{}|_]) -> %R8
    drive_constructor_case(Env0, E, R);

drive(Env0, {'call',Line,{'fun',1,{function,scp_expr,letrec,1}},[Arg]}, R) ->
    %% TODO: Letrec.
    1 = 2;

drive(Env0, E={'block',Lb,[{'match',Lm,P0,E0},Rest]}, R) ->
    drive(Env0, scp_expr:make_case(Lb, E0, [{clause,Lm,[P0],[],[Rest]}]), R);
drive(Env0, {'block',Line,[A0,B0]}, R) ->       %New rule
    {Env1, A} = drive(Env0, A0, []),
    {Env, B} = drive(Env1, B0, R),
    {Env, scp_expr:make_block(Line, A, B)};
drive(Env0, {'block',Line,Es}, R) ->
    drive(Env0, scp_expr:list_to_block(Line, Es), R);

%% Focusing rules.
drive(Env0, E={T,_,_}, Ctxt=[#op_ctxt{line=L, op=Op, e1=hole, e2=E2}|R])
  when T=='integer'; T=='float'; T=='atom'; T=='string'; T=='char' -> %R10
     drive(Env0, E2, [#op_ctxt{line=L, op=Op, e1=E}|R]);

drive(Env0, {cons,L,H,T}, R) ->                 %R11 for cons
    drive(Env0, H, [#cons_ctxt{line=L, tail=T}|R]);
drive(Env0, {op,L,Op,E1,E2}, R) ->              %R11
    %% TODO: handle ++ specially
    drive(Env0, E1, [#op_ctxt{line=L, op=Op, e2=E2}|R]);
drive(Env0, {op,L,Op,E}, R) ->
    drive(Env0, E, [#op1_ctxt{line=L, op=Op}|R]);
drive(Env0, {tuple,L,[A|As]}, R) ->
    %% Drive on one element at a time.
    drive(Env0, A, [#tuple_ctxt{line=L, todo=As}|R]);

drive(Env0, {'call',L,F,Args}, R) ->            %R12
    drive(Env0, F, [#call_ctxt{line=L, args=Args}|R]);

drive(Env0, {'match',L,P,E}, R) ->
    %% XXX: pushes match into case clauses etc
    drive(Env0, E, [#match_ctxt{line=L,pattern=P}|R]);

drive(Env0, {'case',L,E,Cs}, R) ->              %R13
    drive(Env0, E, [#case_ctxt{line=L, clauses=Cs}|R]);

drive(Env0, {'if',L,Cs}, R) ->
    drive_if(Env0, L, Cs, R);

%% TODO: 'compile' list comprehensions

%% Fallthrough.
drive(Env0, Expr, R) ->                         %R14
    io:fwrite("~n%% Fallthrough!~n", []),
    io:fwrite("%% Expr: ~p~n%% R: ~p~n",
               [%%Env0#env{forms=x,
              %%           global=dict:fetch_keys(Env0#env.global),
              %%           local=dict:fetch_keys(Env0#env.local)},
               Expr, R]),
    build(Env0, Expr, R).

%% Rebuilding expressions.
build(Env0, Expr, [#tuple_ctxt{line=Line, done=Done, todo=[]}|R]) ->
    build(Env0, {tuple,Line,lists:reverse([Expr|Done])}, R);
build(Env0, Expr, [#tuple_ctxt{line=Line, done=Done, todo=[T|Ts]}|R]) ->
    drive(Env0, T, [#tuple_ctxt{line=Line, done=[Expr|Done], todo=Ts}|R]);

build(Env0, Expr, [#cons_ctxt{line=Line, tail=T0}|R]) ->  %R15 for cons
    %% The intuition here is that the head of the cons has been driven
    %% (c.f. R11) and now it's time to drive the tail and build a
    %% residual cons expression.
    %% TODO: maybe it's better to have this work like tuple and call
    {Env1,T1} = drive(Env0, T0, []),
    build(Env1, {cons,Line,Expr,T1}, R);

build(Env0, Expr, [#op_ctxt{line=Line, op=Op, e1=hole, e2=E2}|R]) ->        %R15
    {Env1,E} = drive(Env0, E2, []),
    build(Env1, {op,Line,Op,Expr,E}, R);
build(Env0, Expr, [#op_ctxt{line=Line, op=Op, e1=E1, e2=hole}|R]) ->        %R16
    build(Env0, {op,Line,Op,E1,Expr}, R);

build(Env0, Expr, [#call_ctxt{line=Line, args=Args0}|R]) -> %R17
    {Env,Args} = drive_list(Env0, fun drive/3, Args0),
    build(Env, scp_expr:make_call(Line,Expr,Args), R);
%% build(Env0, Expr={var,_,_}, [#case_ctxt{line=Line, clauses=Cs0}|R]) -> %R18
%%     drive_case_variable(Env0, Expr, Line, Cs0, R);
build(Env0, Expr, [#case_ctxt{line=Line, clauses=Cs0}|R]) -> %R19
    build_case_general(Env0, Expr, Line, Cs0, R);
build(Env0, Expr, [#op1_ctxt{line=Line, op=Op}|R]) ->
    build(Env0, {op,Line,Op,Expr}, R);
build(Env0, Expr, [#match_ctxt{line=Line, pattern=P}|R]) ->
    build(Env0, {match,Line,P,Expr}, R);

build(Env, Expr, []) ->                         %R20
    {Env, Expr}.

%% TODO:
%% build_case_variable(Env0, {var,Lc,V}, Line, Cs0, R) ->
%%     %% Drive every clause body in the R context, substituting in V
%%     %% where possible.
%%     {Cs1,Env1} = lists:mapfoldr(
%%                    fun ({clause,Lc,H0,G0,B0},Env00) ->
%%                            Vars = head_variables(H0),
%%                            Env01 = extend_bound(Env00, Vars),
%%                            B1 = scp_expr:list_to_block(Lc, B0),
%%                            {Env02,B} = drive(Env01, B1, R),
%%                            Env03 = Env02#env{bound=Env00#env.bound},
%%                            {{clause,Lc,H0,G0,[B]},Env03}
%%                    end,
%%                    Env0, Cs0),
%%     %% FIXME: find the new bindings going out of the case
%%     Case = scp_expr:make_case(Line, Expr, Cs1),
%%     {Env1, Case}.

build_case_general(Env0, Expr, Line, Cs0, R) ->
    %% Drive every clause body in the R context.
    %% TODO: should have the same features as drive_constructor_case
    {Cs1,Env1} = lists:mapfoldr(
                   fun ({clause,Lc,H0,G0,B0},Env00) ->
                           Vars = head_variables(H0),
                           Env01 = extend_bound(Env00, Vars),
                           B1 = scp_expr:list_to_block(Lc, B0),
                           {Env02,B} = drive(Env01, B1, R),
                           Env03 = Env02#env{bound=Env00#env.bound},
                           {{clause,Lc,H0,G0,[B]},Env03}
                   end,
                   Env0, Cs0),
    %% FIXME: find the new bindings going out of the case expr
    Case = scp_expr:make_case(Line, Expr, Cs1),
    {Env1, Case}.


%% Driving of if expressions.
drive_if(Env0, L, Cs0, R) -> drive_if(Env0, L, Cs0, R, []).

drive_if(Env0, Line, [{clause,Lc,[],G0,B0}|Cs], R, Acc) ->
    B1 = scp_expr:list_to_block(Lc, B0),
    G = scp_pattern:simplify_guard_seq(G0),
    case scp_pattern:guard_seq_eval(G) of
        true when Acc == [] ->
            %% The guard is always true and there were no other
            %% clauses before this one. Eliminate the if expression
            %% completely.
            drive(Env0, B1, R);
        true ->
            %% The guard is always true. Remove the rest of the
            %% clauses.
            drive_if1(Env0, Line, Lc, G, B1, [], R, Acc);
        false when Cs =/= []; Acc =/= [] ->
            %% The guard is always false and this is not the only
            %% clause left. Remove the clause.
            drive_if(Env0, Line, Cs, R, Acc);
        _ ->
            %% This clause is maybe true or it is the last clause
            %% which is always false.
            drive_if1(Env0, Line, Lc, G, B1, Cs, R, Acc)
    end;
drive_if(Env0, Line, [], _R, Acc) ->
    %% TODO: find the new bindings going out of the if expr
    {Env0, scp_expr:make_if(Line, lists:reverse(Acc))}.

drive_if1(Env0, Line, Lc, G, B0, Cs, R, Acc) ->
    %% Drive a single if clause in the R context (thereby pushing R
    %% into the clause body).
    {Env1,B} = drive(Env0, B0, R),
    %% New bindings in one clause are not transmitted to the next
    %% clause.
    Env2 = Env1#env{bound=Env0#env.bound},
    C = {clause,Lc,[],G,[B]},
    drive_if(Env2, Line, Cs, R, [C|Acc]).

%% Driving of function clauses (always in the empty context).
drive_list(Env0, Fun, [C0|Cs0]) ->
    {Env1,C1} = Fun(Env0, C0, []),
    {Env,Cs} = drive_list(Env1, Fun, Cs0),
    {Env,[C1 | Cs]};
drive_list(Env, _, []) ->
    {Env,[]}.
drive_clauses(Env, Cs) ->
    drive_list(Env, fun drive_clause/3, Cs).
drive_clause(Env0, {clause,L,Head,Guard,Body0}, _) ->
    Vars = head_variables(Head),
    Env1 = extend_bound(Env0, Vars),
    {Env2,Body} = drive(Env1, scp_expr:list_to_block(L, Body0), []),
    Env = Env2#env{bound=Env0#env.bound},
    {Env,{clause,L,Head,Guard,[Body]}}.

%% Driving of function calls. First try to find a renaming of an old
%% expression. Then try to find a homeomorphic embedding. Then if that
%% doesn't work, make a new function.
drive_call(Env0, Funterm, Line, Name, Arity, Fun0, R) ->
    %% It is safe to return {Env0,L} if things become difficult.
    io:fwrite("Call: ~p, ~w/~w, R: ~p~n", [Funterm,Name,Arity,R]),
    io:fwrite("Fun: ~p~n", [Fun0]),
    L = plug(Funterm, R),
    FV = scp_expr:free_variables(Env0#env.bound, L),
    %% TODO: second try to find a homeomorphic embedding

    Renaming = scp_expr:find_renaming(Env0, L),
    io:fwrite("Renaming: ~p~n", [Renaming]),

    case Renaming of
        {ok,Fname} ->
            %% L is a renaming of an old expression.
            io:fwrite("Folding. Fname=~p, FV=~p~n",[Fname,FV]),
            Expr={'call',Line,{atom,Line,Fname},[{var,Line,X} || X <- FV]},
            {Env0#env{found=[Fname|Env0#env.found]},Expr};
        _ ->
            %% Neither a renaming nor an embedding.
            {Env1,Fname} = scp_expr:gensym(Env0, Env0#env.name),
            {Env2,Fun} = scp_expr:alpha_convert(Env1, Fun0),
            %% Remember that Fname came from the expression L.
            Env3 = Env2#env{ls = [{Fname,L}|Env2#env.ls]},
            io:fwrite("Before: ~p~nAfter: ~p~n", [Fun0,Fun]),
            %% Drive the fun in the original context. If the context is a
            %% call_ctxt then this might do inlining.
            {Env4,E} = drive(Env3, Fun, R),
            io:fwrite("After driving the fun: ~p~n", [E]),
            {Env5,S} = scp_expr:fresh_variables(Env4, dict:new(), FV),
            %% The line numbers are probably going to be a bit wrong.
            case lists:member(Fname, Env5#env.found) of
                false ->
                    %% Fname was never used in E, so there is no need
                    %% to residualize a new function. This basically
                    %% inlines what would otherwise be a new function.
                    %% Need to forget about Fname, because otherwise
                    %% it might be used afterwards.
                    Env6 = Env5#env{ls = lists:keydelete(Fname, 1, Env5#env.ls)},
                    {Env6,E};
                _ ->
                    Head = [scp_expr:subst(S, {var,Line,X}) || X <- FV],
                    %% io:fwrite("S: ~p~n", [S]),
                    %% io:fwrite("Free variables in ~p: ~w~n", [L,FV]),
                    %% io:fwrite("Head: ~p~n",[Head]),
                    Guard = [],
                    %% io:fwrite("E: ~p~n",[E]),
                    Body = scp_expr:subst(S, E),
                    NewFun0 = {'fun',Line,
                               {clauses,
                                [{clause,Line,Head,Guard,[Body]}]}},
                    NewTerm = {'call',Line,{atom,Line,Fname},
                               [{var,Line,X} || X <- FV]},
                    io:fwrite("NewFun0: ~p~n",[NewFun0]),
                    io:fwrite("NewTerm: ~p~n",[NewTerm]),
                    {Env6,NewFun} = scp_expr:alpha_convert(Env5, NewFun0),
                    io:fwrite("NewFun: ~p~n",[NewFun]),
                    %% This letrec will become a top-level function later.
                    Letrec = scp_expr:make_letrec(Line,[{Fname,length(FV),NewFun}],[NewTerm]),
                    {Env6,Letrec}
            end
    end.

%% Driving of built-in functions. This is where things like length/1
%% can be inlined.
drive_BIF(Env, E, R) ->
    build(Env, E, R).

%% Driving of case expressions.
drive_const_case(Env0, E, Ctxt=[CR=#case_ctxt{clauses=Cs0}|R]) ->
    %% E is a constant.
    %% TODO: drive_constructor_case is much more powerful and should be
    %% used for this as well...
    case scp_pattern:find_matching_const(Env0#env.bound, E, Cs0) of
        [{yes,{clause,L,[{var,_,V}],[],B}}] ->   %R7
            %% The case just binds a variable to a constant.
            S = dict:from_list([{V,E}]),
            drive(Env0, scp_expr:subst(S, scp_expr:list_to_block(L, B)), R);
        [{yes,{clause,L,P,[],B}}] ->
            drive(Env0, scp_expr:list_to_block(L, B), R);
        [] ->
            %% No clauses can match, so preserve the error. It's
            %% possible to make a case without any clauses, but if
            %% printed it can't be parsed back.
            build(Env0, E, Ctxt);
        Possibles ->
            %% Some impossible clauses may have been removed.
            {_,Cs} = lists:unzip(Possibles),
            build(Env0, E, [CR#case_ctxt{clauses=Cs}|R])
    end.

drive_constructor_case(Env0, E0, Ctxt=[CR=#case_ctxt{clauses=Cs0, line=Line}|R]) ->
    case scp_pattern:simplify(Env0#env.bound, E0, Cs0) of
        {_,_,[]} ->
            %% All the clauses disappeared. Preserve the error in the
            %% residual program.
            build(Env0, E0, Ctxt);
        {E0,nothing,SCs} ->
            Cs = [C || {C,nothing} <- SCs],
            case Cs of
                Cs0 ->
                    %% The expression didn't change and neither did
                    %% the clauses.
                    {Env1,E1} = drive(Env0, E0, []),
                    build(Env1, E1, [CR#case_ctxt{clauses=Cs}|R]);
                _ ->
                    %% The expression didn't change, but some clause
                    %% may have been removed.
                    drive(Env0, E0, [CR#case_ctxt{clauses=Cs}|R])
            end;
        {E,nothing,SCs} ->
            %% A new expression, so driving might improve it further.
            Cs = [C || {C,nothing} <- SCs],
            drive(Env0, E, [CR#case_ctxt{clauses=Cs}|R]);
        {E,Rhs0,SCs} ->
            %% An expression was removed from the constructor.
            io:fwrite("Stuff happens: E=~p~n Rhs0=~p~n SCs=~p~n", [E,Rhs0,SCs]),
            Cs1 = rebuild_clauses(Env0, Rhs0, SCs),
            case lists:member(false, Cs1) of
                %% true ->
                %%     %% It wasn't possible to simply substitute the Lhs
                %%     %% in every clause. Bind Rhs0 to a new variable
                %%     %% and do the substitution with that instead. This
                %%     %% is equivalent to the second case in R9.

                %%     %% TODO: check that this works. Also check if it
                %%     %% would work better to make the block and then do
                %%     %% driving on that instead.
                %%     %% TODO: if Lhs=nothing for all SCs, then residualize
                %%     %% Rhs for effect
                %%     io:fwrite("Stuff happening~n"),
                %%     {Env1,Rhs} = drive(Env0, Rhs0, []),
                %%     {Env2,Var} = scp_expr:gensym(Env1, "P"),
                %%     Cs2 = rebuild_clauses(Env2, {var,Line,Var}, SCs),
                %%     Match = {match,Line,{var,Line,Var},Rhs},
                %%     Env = extend_bound(Env2, sets:from_list([Var])),
                %%     Case = drive(Env, E, [CR#case_ctxt{clauses=Cs2}|R]),
                %%     NewE = scp_expr:make_block(Match, Case),
                %%     io:fwrite("Stuff happened: NewE=~p~n", [NewE]),
                %%     NewE;
                false ->
                    %% Lhs in each clause was substituted for Rhs.
                    io:fwrite("Stuff was easy. Cs1=~p~n",[Cs1]),
                    drive(Env0, E, [CR#case_ctxt{clauses=Cs1}|R])
            end;
        Foo ->
            %% Something more clever happened.
            io:fwrite("constructor case default: E=~p~n Ctxt=~p~n Foo=~p~n", [E0,Ctxt,Foo]),
            build(Env0, E0, Ctxt)
    end.

rebuild_clauses(Env, Rhs, [{C0,nothing}|SCs]) ->
    [C0|rebuild_clauses(Env, Rhs, SCs)];
rebuild_clauses(Env, Rhs, [{C0,Lhs}|SCs]) ->
    %% Replace Lhs with Rhs in the body, if it's semantically ok.
    {clause,L,P,G,B0} = C0,
    %% FIXME: if Lhs ever appears in a guard, then Rhs must be a legal
    %% guard expression.
    case scp_expr:terminates(Env, Rhs)
        orelse (scp_expr:is_linear(Lhs, B0)
                andalso scp_expr:is_strict(Lhs, B0)) of
        true ->
            S = dict:from_list([{Lhs,Rhs}]),
            B = [scp_expr:subst(S, X) || X <- B0],
            C = {clause,L,P,G,B},
            [C|rebuild_clauses(Env, Rhs, SCs)];
        _ ->
            false
    end;
rebuild_clauses(_, _, []) ->
    [].

%% Plug an expression into a context.
plug(Expr, [#call_ctxt{line=Line, args=Args}|R]) ->
    plug({call,Line,Expr,Args}, R);
plug(Expr, [#case_ctxt{line=Line, clauses=Cs}|R]) ->
    plug(scp_expr:make_case(Line,Expr,Cs), R);
plug(Expr, [#cons_ctxt{line=Line, tail=T}|R]) ->
    plug({cons,Line,Expr,T}, R);
plug(Expr, [#match_ctxt{line=Line, pattern=P}|R]) ->
    plug({match,Line,Expr,P}, R);
plug(Expr, [#op_ctxt{line=Line, op=Op, e1=hole, e2=E2}|R]) ->
    plug({op,Line,Op,Expr,E2}, R);
plug(Expr, [#op_ctxt{line=Line, op=Op, e1=E1, e2=hole}|R]) ->
    plug({op,Line,Op,E1,Expr}, R);
plug(Expr, [#op1_ctxt{line=Line, op=Op}|R]) ->
    plug({op,Line,Op,Expr}, R);
plug(Expr, [#tuple_ctxt{line=Line, done=Ds, todo=Ts}|R]) ->
    plug({tuple,Line,lists:reverse([Expr|Ds])++Ts}, R);
plug(Expr, []) ->
    Expr.

%% EUnit tests.

build_test() ->
    {_,{integer,0,123}} = drive(#env{}, {integer,0,123}, []),
    Fun = {'fun',1, {clauses, [{clause,1,[{var,1,'X'}], [], [{var,2,'X'}]}]}},
    drive(#env{}, Fun, []).

residualize_test() ->
    %% When something is removed from the scrutinee it must either be
    %% side-effect free or else be residualized for effect.
    E0 = scp_expr:read("case {1,length(U)} of {X,_} -> 1 end"),
    {Env,E} = drive(#env{}, E0, []),
    ['U'] = scp_expr:free_variables(sets:new(), E).
