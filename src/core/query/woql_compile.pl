:- module(woql_compile,[
              lookup/3,
              lookup_backwards/3,
              compile_query/3,
              compile_query/4,
              empty_context/1,
              empty_context/2,
              filter_transaction_object_read_write_objects/3
          ]).

/** <module> WOQL Compile
 *
 * Core compiler for the WOQL query language.
 *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

:- use_module(jsonld).
:- use_module(json_woql).
% We may need to patch this in again...
%:- use_module(ask), [enrich_graph_fragment/5]).
:- use_module(global_prefixes, [default_prefixes/1]).
:- use_module(resolve_query_resource).
:- use_module(path).
:- use_module(metadata).

:- use_module(core(util)).
% Get op precedence
:- reexport(core(util/syntax)).

:- use_module(core(account)).
:- use_module(core(triple)).
:- use_module(core(transaction)).
:- use_module(core(document)).

:- use_module(library(http/json)).
:- use_module(library(http/json_convert)).
:- use_module(library(solution_sequences)).

:- use_module(library(csv)).
:- use_module(library(isub)).
:- use_module(library(lists)).
:- use_module(library(aggregate)).

:- use_module(library(apply)).
:- use_module(library(yall)).
:- use_module(library(apply_macros)).

/*
 * Ctx is a context object which is used in WOQL queries to
 * keep track of state.
 *
 *******
 * TODO: This is complicated, punt to later
 *
 * store_id --> store_id{ descriptor : graph_descriptor,
 *                        id : integer }
 * store_ids = list(store_id)
 *
 * woql_var ---> woql_var{ prolog_var : var,
 *                         store_ids : store_ids }
 ******
 *
 * woql_var ---> var % currently snarfing prolog unification
 *
 * var_binding ---> var_binding{ woql_var : woql_var,
 *                               var_name : atom }
 * var_bindings = list(var_binding)
 *
 * query_context ---> query_context{ <default_output_graph : graph_descriptor>,
 *                                   <default_collection : collection_descriptor>,
 *                                   <prefixes : context>,
 *                                   transaction_objects : list(query_object),
 *                                   bindings : list(var_binding),
 *                                   selected : list(var_binding)
 *                                }
 */

/*******
 * Monadic DCG management
 *
 * We use DCG's to simplify tracking the state of the WOQL query compiler.
 */

get(Key,Value,Set) :-
    Value = Set.Key.

/* Monadic selection */
update(Key,C0,C1,S0,S1) :-
    C0 = S0.Key,
    S1 = S0.put(Key, C1).

view(Key,C0,S0,S0) :-
    C0 = S0.Key.

swap(Key,C0,C1,S0,S1) :-
    C0 = S0.Key,
    C1 = S1.Key.

put(Key, C0, S0, S1) :-
    S1 = S0.put(Key, C0).

peek(S0,S0,S0).

return(S0,_,S0).

/*
 * merge(S0,S1,SM) is det.
 *
 * We need to merge multiple states into a signal state for output.
 *
 * we use S0 as the "merge in set"
 */
merge(S0) -->
    {
        B0 = S0.get(bindings)
    },

    view(bindings,B1),

    {
        merge_output_bindings(B0,B1,Bindings)
    },

    put(bindings,Bindings).

unify_same_named_vars(_Var, []).
unify_same_named_vars(Var, [Var1|Vars]) :-
    (   var_compare((=), Var, Var1)
    ->  Var = Var1
    ;   true),
    unify_same_named_vars(Var,Vars).

unify_output_bindings([], _).
unify_output_bindings([Var|Vars], Bindings) :-
    unify_same_named_vars(Var, Bindings),
    unify_output_bindings(Vars, Bindings).

merge_output_bindings(B0, B1, Bindings) :-
    unify_output_bindings(B0,B1),
    append(B0, B1, All),
    predsort(var_compare, All, Bindings).

/**
 * empty_context(Context).
 *
 * Add Commit Info
 */
empty_context(Context) :-
    Context = query_context{
        transaction_objects : [],
        default_collection : root,
        filter : type_filter{ types : [instance] },
        prefixes : _{},
        all_witnesses : false,
        write_graph : empty,
        update_guard : _,
        bindings : [],
        selected : [],
        files : [],
        authorization : empty
    }.

/*
 * prototype_empty_context(S0,S1) is det.
 *
 * updates a context, keeping only global info
 */
empty_context -->
    view(prefixes,Prefixes),
    view(transaction_objects,Transaction_Objects),
    view(files,Files),

    { empty_context(S0)
    },
    return(S0),

    put(prefixes,Prefixes),
    put(transaction_objects,Transaction_Objects),
    put(files,Files).

empty_context(Prefixes) -->
    empty_context,
    put(prefixes, Prefixes).

/******************************
 * Binding management utilities
 ******************************/

/* Lookup a variable by name */
lookup(Var_Name,Prolog_Var,[Record|_B0]) :-
    var_record_pl_var(Var_Name,Record,Prolog_Var),
    !.
lookup(Var_Name,Prolog_Var,[_Record|B0]) :-
    lookup(Var_Name,Prolog_Var,B0).

lookup_or_extend(Var_Name, Prolog_Var) -->
    update(bindings,B0,B1),
    {
        (   lookup(Var_Name, Prolog_Var, B0)
        ->  B1=B0
        ;   B1=[var_binding{
                    woql_var : Prolog_Var,
                    var_name : Var_Name}
                |B0])
    }.

lookup_backwards(Prolog_Var,Var_Name,[var_binding{woql_var: _Woql_Var, prolog_var: Binding_Var, var_name: Var_Name}|_]) :-
    Prolog_Var == Binding_Var,
    !.
lookup_backwards(Prolog_Var,Var_Name,[_|Records]) :-
    lookup_backwards(Prolog_Var, Var_Name, Records).

resolve_prefix(Pre,Suf,URI) -->
    view(prefixes,Prefixes),
    {
        (   Full_Prefix = (Prefixes.get(Pre))
        ->  true
        ;   throw(error(woql_syntax_error(unresolvable_prefix(Pre,Suf)),_)))
    },
    (   {v(Var_Name) = Suf}
    ->  view(bindings, Bindings),
        { lookup(Var_Name, Var, Bindings),
          freeze(URI, uri_to_prefixed(URI, Prefixes, Pre:Var))
        }
    ;   {atomic_list_concat([Full_Prefix,Suf],URI)}
    ).

is_boolean_type('http://www.w3.org/2001/XMLSchema#boolean').

resolve_predicate(ignore,_Something) -->
    !,
    [].
resolve_predicate(P,PE) -->
    {
        atom(P),
        \+ uri_has_protocol(P),
        !
    },
    resolve_prefix('@schema', P, PE).
resolve_predicate(P, PE) -->
   resolve(P,PE).

resolve_variable(v(Var_Name),Var) -->
    !,
    lookup_or_extend(Var_Name,Var).
resolve_variable(Not_Var,Not_Var) -->
    [].

/*
 * resolve(ID,Resolution, S0, S1) is det.
 *
 * TODO: This needs a good going over. Way too much duplication of effort.
 */
resolve(ignore,_Something) -->
    !,
    [].
resolve(X,XEx) -->
    {
        atom(X),
        \+ uri_has_protocol(X),
        !
    },
    resolve_prefix('@base', X, XEx).
resolve(ID:Suf,U) -->
    !,
    resolve_prefix(ID,Suf,U).
resolve(v(Var_Name),Var) -->
    !,
    lookup_or_extend(Var_Name,Var).
resolve(X,XEx) -->
    view(prefixes,Prefixes),
    {
        is_dict(X),
        !,
        expand(X,Prefixes,XEx)
    }.
resolve(X@L,XS@L) -->
    resolve(X,XE),
    {
        (   ground(XE),
            atom(XE)
        ->  atom_string(XE,XS)
        ;   XE = XS),
        !
    }.
resolve(X^^T,Lit) -->
    resolve_variable(X,XE),
    resolve(T,TE),
    {
        (   ground(XE)
        ->  (   atom(XE),
                \+ is_boolean_type(TE)
            ->  atom_string(XE,XS)
            ;   XE=XS),
            Lit = XS^^TE
        ;   Lit = XE^^TE),
        !
    }.
resolve(L,Le) -->
    {
        is_list(L),
        !
    },
    mapm(resolve,L,Le).
resolve(X,X) -->
    {
        once((   string(X)
             ;   atom(X)
             ;   number(X)
             ;   is_date(X)
             ;   is_time(X)
             ;   is_date_time(X)
             ;   is_gyear(X)
             ;   is_gyear_month(X)
             ;   is_gmonth(X)
             ;   is_gmonth_day(X)
             ;   is_gday(X)
             ;   is_boolean(X)
             ;   is_duration(X)
             ;   is_gyear_range(X)
             ;   is_date_range(X)
             ;   is_integer_range(X)
             ;   is_decimal_range(X)
             ;   is_point(X)
             ;   is_coordinate_polygon(X)
             ))
    },
    !.
resolve(X,X) -->
    {
        throw(error('How did we get here?', X))
    }.

var_record_pl_var(Var_Name,
                  var_binding{
                      woql_var : Prolog_Var,
                      var_name : Var_Name},
                  Prolog_Var).
var_record_pl_var(Var_Name,
                  var_binding{
                      woql_var : Prolog_Var,
                      prolog_var: _,
                      var_name : Var_Name},
                  Prolog_Var).

var_compare(Op, Left, Right) :-
    compare(Op, Left.var_name, Right.var_name).

/* This partitions a tree cleanly into two segments or fails:
   Reads:  read only
   Writes: write only
*/
partition((A,B), Reads, Writes) :-
    partition(A, A_Reads, []),
    !,
    partition(B, B_Reads, Writes),
    append(A_Reads, B_Reads, Reads).
partition((A,B), Reads, Writes) :-
    partition(B, [], B_Writes),
    !,
    partition(A, Reads, A_Writes),
    append(A_Writes, B_Writes, Writes).
partition((A;B), [(A;B)], []) :-
    /* just fail if we are doing disjunctive writes */
    !,
    partition(A, _, []),
    partition(B, _, []).
partition(not(Q), [not(Q)], []) :-
    /* just fail if we have a write in a not. */
    !,
    partition(Q, _, []).
partition(once(Q), [once(Q)], []) :-
    !,
    partition(Q, _, []).
partition(once(Q), [], [once(Q)]) :-
    partition(Q, [], _),
    !.
partition(limit(N,Q), [limit(N,Q)], []) :-
    /* just fail if we have a limit on a write */
    !,
    partition(Q, _, []).
partition(select(V,Q), [select(V,Q)], []) :-
    /* just fail if we have a select on a write */
    !,
    partition(Q, _, []).
partition(opt(P), [opt(P)], []) :-
    /* just fail if we have an opt on a write */
    !,
    partition(P, _, []).
partition(when(A,B), Reads, Writes) :-
    /* assume "when"s have a read only head */
    !,
    partition(A, A_Reads, []),
    partition(B, B_Reads, Writes),
    append(A_Reads, B_Reads, Reads).
partition(using(C,P), Reads, Writes) :-
    !,
    partition(P, P_Reads, P_Writes),
    (   P_Reads = []
    ->  Reads = [],
        xfy_list(',', Q, P_Writes),
        Writes = [using(C,Q)]
    ;   P_Writes = []
    ->  Writes = [],
        xfy_list(',', Q, P_Reads),
        Reads = [using(C,Q)]
    ->  xfy_list(',', A, P_Reads),
        xfy_list(',', B, P_Writes),
        Reads = [using(C,A)],
        Writes = [using(C,B)]
    ).
partition(from(C,P), Reads, Writes) :-
    partition(P, P_Reads, P_Writes),
    !,
    (   P_Reads = []
    ->  Reads = [],
        xfy_list(',', Q, P_Writes),
        Writes = [from(C,Q)]
    ;   P_Writes = []
    ->  Writes = [],
        xfy_list(',', Q, P_Reads),
        Reads = [from(C,Q)]
    ->  xfy_list(',', A, P_Reads),
        xfy_list(',', B, P_Writes),
        Reads = [from(C,A)],
        Writes = [from(C,B)]
    ).
partition(start(N,P), [start(N,P)], []) :-
    partition(P, _, []),
    !.
partition(count(P,N), [count(P,N)], []) :-
    partition(P, _, []),
    !.
partition(where(P), Reads, Writes) :-
    % where means nothing
    partition(P, Reads, Writes),
    !.
partition(order_by(L,S), [order_by(L,S)], []) :-
    partition(S, _, []),
    !.
partition(into(C,P), Reads, Writes) :-
    partition(P, P_Reads, P_Writes),
    !,
    (   P_Reads = []
    ->  Reads = [],
        xfy_list(',', Q, P_Writes),
        Writes = [into(C,Q)]
    ;   P_Writes = []
    ->  Writes = [],
        xfy_list(',', Q, P_Reads),
        Reads = [into(C,Q)]
    ->  xfy_list(',', A, P_Reads),
        xfy_list(',', B, P_Writes),
        Reads = [into(C,A)],
        Writes = [into(C,B)]
    ).
partition(group_by(L,S), [group_by(L,S)], []) :-
    partition(S, _, []),
    !.
partition(insert(A,B,C), Reads, Writes) :-
    !,
    Reads = [],
    Writes = [insert(A,B,C)].
partition(insert(A,B,C,D), Reads, Writes) :-
    !,
    Reads = [],
    Writes = [insert(A,B,C,D)].
partition(delete(A,B,C), Reads, Writes) :-
    !,
    Reads = [],
    Writes = [delete(A,B,C)].
partition(delete(A,B,C,D), Reads, Writes) :-
    !,
    Reads = [],
    Writes = [delete(A,B,C,D)].
partition(replace_document(A,B), Reads, Writes) :-
    !,
    Reads = [],
    Writes = [replace_document(A,B)].
partition(replace_document(A,B,C), Reads, Writes) :-
    !,
    Reads = [],
    Writes = [replace_document(A,B,C)].
partition(delete_document(A), Reads, Writes) :-
    !,
    Reads = [],
    Writes = [delete_document(A)].
partition(T,[T],[]) :-
    /* Everything else should be read only
     * Note: A bit more energy here would remove the default case and need for cuts.
     */
    !.

/*
 * safe_guard_removal(Term, NewTerm) is det.
 */
safe_guard_removal(Term, Prog) :-
    partition(Term,Reads,Writes),
    (   Writes = []
    ->  xfy_list(',', Prog, Reads)
    ;   Reads = []
    ->  xfy_list(',', Write_Term, Writes),
        Prog = immediately(Write_Term)
    ;   xfy_list(',', A, Reads),
        xfy_list(',', B, Writes),
        Prog = (A,immediately(B))
    ),
    !.
safe_guard_removal(Term, Term).

:- begin_tests(guards).

test(guard_removal_is_impossible, []) :-

    AST = (
        t(a,b,c),
        insert(a,b,c)
    ;   t(e,f,g),
        insert(d,b,c)),

    safe_guard_removal(AST, AST).

test(guard_removal_is_safe, []) :-

    AST = (
        t(a,b,c),
        t(e,f,g),
        insert(a,b,c),
        insert(d,b,c),
        insert(e,f,g)
    ),

    safe_guard_removal(AST, AST2),

    AST2 = ((
                   t(a,b,c),
                   t(e,f,g)),
            immediately(
                (
                    insert(a,b,c),
                    insert(d,b,c),
                    insert(e,f,g)))).

test(alternating_inserts, []) :-

    AST = (
        t(a,b,c),
        insert(a,b,c),
        t(e,f,g),
        insert(d,b,c),
        insert(e,f,g)
    ),

    safe_guard_removal(AST, AST).

test(guard_removal_with_deep_inserts, []) :-

    AST = (
        t(a,b,c),
        (   t(e,f,g),
            (   insert(a,b,c),
                insert(d,b,c),
                (   insert(e,f,g),
                    insert(f,g,h))))),

    safe_guard_removal(AST, AST2),

    AST2 = ((t(a,b,c),
             t(e,f,g)),
            immediately(
                (insert(a,b,c),
                 insert(d,b,c),
                 insert(e,f,g),
                 insert(f,g,h)))).

test(guard_single_query, []) :-

    AST = t(a,b,c),

    safe_guard_removal(AST, (t(a,b,c))).


test(guard_single_insertion, []) :-

    AST = insert(a,b,c),

    safe_guard_removal(AST, immediately(insert(a,b,c))).

test(guard_single_deletion, []) :-

    AST = delete(a,b,c),

    safe_guard_removal(AST, immediately(delete(a,b,c))).

test(guard_double_insertion, []) :-

    AST = (insert(a,b,c),insert(d,e,f)),

    safe_guard_removal(AST, (immediately((insert(a,b,c),insert(d,e,f))))).

:- end_tests(guards).



/*
 * compile_query(+Term:any,-Prog:any,-Ctx_Out:context) is det.
 */
compile_query(Term, Prog, Ctx_Out) :-
    empty_context(Ctx_In),
    compile_query(Term,Prog,Ctx_In,Ctx_Out).

compile_query(Term, Prog, Ctx_In, Ctx_Out) :-
    (   safe_guard_removal(Term, Optimized),
        assert_pre_flight_access(Ctx_In, Term),
        do_or_die(compile_wf(Optimized, Pre_Prog, Ctx_In, Ctx_Out),
                  error(woql_syntax_error(badly_formed_ast(Term)),_)),
        % Unsuspend all updates so they run at the end of the query
        % this is redundant if we do a pre-pass that sets the guard as well.
        Guard = Ctx_Out.update_guard,
        Prog = (Pre_Prog, Guard = true)
    ->  true
    ;   format(atom(M), 'Failure to compile term ~q', [Term]),
        throw(compilation_error(M))).

get_varname(Var,[X=Y|_Rest],Name) :-
    Y == Var,
    !,
    Name = X.
get_varname(Var,[_|Rest],Name) :-
    get_varname(Var,Rest,Name).

guess_varnames([],[]).
guess_varnames([X=Y|Rest],[X|Names]) :-
    var(Y),
    !,
    guess_varnames(Rest,Names).
guess_varnames([_|Rest],Names) :-
    guess_varnames(Rest,Names).

report_instantiation_error(_Prog,context(Pred,Var),Ctx) :-
    memberchk(bindings=B,Ctx),
    get_varname(Var,B,Name),
    !,
    format(string(MSG), "The variable: ~q is unbound while being proceed in the AST operator ~q, but must be instantiated", [Name,Pred]),
    throw(http_reply(method_not_allowed(_{'system:status' : 'system:failure',
                                          'system:message' : MSG}))).
report_instantiation_error(_Prog,context(Pred,_),Ctx) :-
    memberchk(bindings=B,Ctx),
    guess_varnames(B,Names),
    format(string(MSG), "The variables: ~q are unbound, one of which was a problem while being proceed in the AST operator ~q, which but must be instantiated", [Names,Pred]),
    throw(http_reply(method_not_allowed(_{'system:status' : 'system:failure',
                                          'system:message' : MSG}))).

literal_string(Val^^_, Val).
literal_string(Val@_, Val).

not_literal(X) :-
    nonvar(X),
    X = _V^^_T,
    !,
    false.
not_literal(X) :-
    nonvar(X),
    X = _V@_T,
    !,
    false.
not_literal(_).

/* TODO: Needs fixed */
patch_binding(X,Y) :-
    (   var(X)
    ->  Y=unknown
    ;   (   \+ \+ (X = B^^A,
                   (var(A) ; var(B)))
        ->  Y = unknown
        ;   X = Y)
    ;   X=Y).

patch_bindings([],[]).
patch_bindings([V=X|B0],[V=Y|B1]) :-
    patch_binding(X,Y),
    patch_bindings(B0,B1).

as_vars([],[]).
as_vars([as(_X,Y)|Rest],[Y|Vars]) :-
    as_vars(Rest,Vars).
as_vars([as(_X,Y,_T)|Rest],[Y|Vars]) :-
    as_vars(Rest,Vars).

position_vars([],[]).
position_vars([v(V)|Rest],[v(V)|Vars]) :-
    position_vars(Rest,Vars).

/* indexing_list(Spec,Header,Values,Bindings,Result) is det.
 *
 * A fold over Spec into Result
 */
indexing_as_list([],_,_,_,[]).
indexing_as_list([As_Clause|Rest],Header,Values,Bindings,[Term|Result]) :-
    (   As_Clause = as(N,v(V))
    ->  Type = none
    ;   As_Clause = as(N,v(V),Type)),
    lookup(V,Xe,Bindings),
    Term = (   nth1(Idx,Header,N)
           ->  (   nth1(Idx,Values,Value)
               ->  (   Type = none
                   ->  Value = Xe
                   ;   typecast(Value,Type,[],Xe))
               ;   throw(error(woql_syntax_error(get_header_does_not_match_values(Header, Values, N, Idx)),_))
               )
           ;   throw(error(woql_syntax_error(get_has_no_such_index(Header,Values,N)), _))
           ),
    indexing_as_list(Rest,Header,Values,Bindings,Result).

indexing_position_list([],_,_,_,[]).
indexing_position_list([v(V)|Rest],N,Values,Bindings,[Term|Result]) :-
    lookup(V,Xe,Bindings),
    Term = (   nth0(N,Values,Xe)
           ->  true
           ;   throw(error(woql_syntax_error(no_such_index(Values,N)),_))
           ),
    M is N+1,
    indexing_position_list(Rest,M,Values,Bindings,Result).

indexing_term(Spec,Header,Values,Bindings,Indexing_Term) :-
    (   indexing_as_list(Spec,Header,Values,Bindings,Indexing_List)
    ;   indexing_position_list(Spec,0,Values,Bindings,Indexing_List),
        Header=false),
    list_conjunction(Indexing_List,Indexing_Term).

/*
 * woql_equal(AE,BE) is det.
 */
woql_equal(AE,BE) :-
    nonvar(AE),
    nonvar(BE),
    % Probably strictly should check subsumption
    % TODO: Lang!!! Foo@Bar
    AE = Y^^_T1,
    BE = Y^^_T2,
    !.
woql_equal(AE,BE) :-
    AE=BE.

/*
 * woql_less(AE,BE) is det.
 *
 * TODO: May need other cases.
 */
woql_less(X^^'http://www.w3.org/2001/XMLSchema#dateTime',
          Y^^'http://www.w3.org/2001/XMLSchema#dateTime') :-
    !,
    X @< Y.
woql_less(X^^T1,Y^^T2) :-
    basetype_subsumption_of(T1,'http://www.w3.org/2001/XMLSchema#decimal'),
    basetype_subsumption_of(T2,'http://www.w3.org/2001/XMLSchema#decimal'),
    !,
    X < Y.
woql_less(AE,BE) :-
    % dodgy - should switch on type
    compare((<),AE,BE).

/*
 * woql_greater(AE,BE) is det.
 *
 * TODO: May need other cases.
 */
woql_greater(X^^'http://www.w3.org/2001/XMLSchema#dateTime',
             Y^^'http://www.w3.org/2001/XMLSchema#dateTime') :-
    !,
    X @> Y.
woql_greater(X^^T1,
             Y^^T2) :-
    basetype_subsumption_of(T1,'http://www.w3.org/2001/XMLSchema#decimal'),
    basetype_subsumption_of(T2,'http://www.w3.org/2001/XMLSchema#decimal'),
    !,
    X > Y.
woql_greater(AE,BE) :-
    % dodgy - should switch on type
    compare((>),AE,BE).

/*
 * term_literal(Value, Value_Cast) is det.
 *
 * Casts a bare object from prolog to a typed object
 */
term_literal(Term, Term) :-
    var(Term),
    !.
term_literal(Term,  String^^'http://www.w3.org/2001/XMLSchema#string') :-
    atom(Term),
    !,
    atom_string(Term,String).
term_literal(Term,  Term^^'http://www.w3.org/2001/XMLSchema#string') :-
    string(Term),
    !.
term_literal(Term,  Term^^'http://www.w3.org/2001/XMLSchema#decimal') :-
    number(Term).

/*
 * csv_term(Path,Has_Header,Header,Indexing,Prog,Options) is det.
 *
 * Create a program term Prog for a csv with Header and column reference strategy
 * Indexing.
 */
csv_term(Path,true,Header,Values,Indexing_Term,Prog,Options) :-
    Prog = (
        % header row only
        csv_read_file_row(Path, Header_Row, [line(1)|Options]),
        Header_Row =.. [_|Header]
    ->  csv_read_file_row(Path, Value_Row, [line(Line)|Options]),
        Line > 1,
        Value_Row =.. [_|Pre_Values],
        maplist(term_literal,Pre_Values,Values),
        Indexing_Term
    ),
    !.
csv_term(Path,false,_,Values,Indexing_Term,Prog,Options) :-
    Prog = (
        csv_read_file_row(Path, Value_Row, Options),
        Value_Row =.. [_|Pre_Values],
        maplist(term_literal,Pre_Values,Values),
        Indexing_Term
    ),
    !.
csv_term(Path,Has_Header,Header,Values,Indexing_Term,Prog,Options) :-
    throw(
        error(
            woql_syntax_error(
                unknown_csv_processing_errors(Path,Has_Header,Header,
                                              Values,Indexing_Term,Prog,Options)),
            _)).

json_term(Path,Header,Values,Indexing_Term,Prog,_New_Options) :-
    setup_call_cleanup(
        open(Path,read,In),
        json_read_dict(In,Dict,[]),
        close(In)
    ),
    get_dict(columns,Dict,Pre_Header),
    maplist([Str,Atom]>>atom_string(Atom,Str),Pre_Header,Header),
    get_dict(data,Dict,Rows),
    Prog = (
        member(Row,Rows),
        maplist(term_literal,Row,Values),
        Indexing_Term
    ).


/*
 * bool_convert(+Bool_Id,-Bool) is det.
 * bool_convert(-Bool_Id,+Bool) is nondet.
 *
 * Converts a boolean representation from json.
 */
bool_convert(true,true).
bool_convert("true",true).
bool_convert(1,true).
bool_convert("false",false).
bool_convert(false,false).
bool_convert(0,false).

/*
 * convert_csv_options(+Options, -CSV_Options) is det.
 *
 * We need the various parsing options etc. to be implemented here
 * by converting from URI terms to proper CSV library terms.
 */
convert_csv_options(Options,CSV_Options) :-
    (   memberchk(separator(A),Options)
    ->  atom_codes(A,[C]),
        CSV_Options1 = [separator(C)]
    ;   CSV_Options1 = []),

    (   memberchk(convert(Bool_Str),Options)
    ->  bool_convert(Bool_Str,Bool),
        CSV_Options2 = [convert(Bool)|CSV_Options1]
    ;   CSV_Options2 = [convert(false)|CSV_Options1]),

    CSV_Options = CSV_Options2.

find_resources(t(_,_,_), Collection, DRG, _DWG, Read, Write) :-
    Write = [],
    Read = [resource(Collection,DRG)].
find_resources(t(_,_,_,Type), Collection, _DRG, _DWG, Read, Write) :-
    resolve_filter(Type, DRG),
    Write = [],
    Read = [resource(Collection,DRG)].
find_resources(path(_,_,_), Collection, DRG, _DWG, Read, Write) :-
    Write = [],
    Read = [resource(Collection,DRG)].
find_resources(path(_,_,_,_), Collection, DRG, _DWG, Read, Write) :-
    Write = [],
    Read = [resource(Collection,DRG)].
find_resources(get_document(_,_), Collection, DRG, _DWG, Read, Write) :-
    Write = [],
    Read = [resource(Collection,DRG)].
find_resources(replace_document(_), Collection, _DRG, DWG, Read, Write) :-
    Write = [resource(Collection,DWG)],
    Read = [].
find_resources(replace_document(_,_), Collection, _DRG, DWG, Read, Write) :-
    Write = [resource(Collection,DWG)],
    Read = [].
find_resources(insert_document(_,_), Collection, _DRG, DWG, Read, Write) :-
    Write = [resource(Collection,DWG)],
    Read = [].
find_resources(delete_document(_), Collection, _DRG, DWG, Read, Write) :-
    Write = [resource(Collection,DWG)],
    Read = [].
find_resources(delete(_,_,_), Collection, _DRG, DWG, Read, Write) :-
    Write = [resource(Collection,DWG)],
    Read = [].
find_resources(delete(_,_,_,G), Collection, _DRG, _DWG, Read, Write) :-
    ensure_filter_resolves_to_graph_descriptor(G, Collection, DWG),
    Write = [resource(Collection,DWG)],
    Read = [].
find_resources(insert(_,_,_), Collection, _DRG, DWG, Read, Write) :-
    Write = [resource(Collection,DWG)],
    Read = [].
find_resources(insert(_,_,_,G), Collection, _Default_Read_Graph, _Default_Write_Graph, Read, Write) :-
    ensure_filter_resolves_to_graph_descriptor(G, Collection, DWG),
    Write = [resource(Collection,DWG)],
    Read = [].
find_resources((P,Q), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read_P, Write_P),
    find_resources(Q, Collection, DRG, DWG, Read_Q, Write_Q),
    append(Read_P, Read_Q, Read),
    append(Write_P, Write_Q, Write).
find_resources((P;Q), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read_P, Write_P),
    find_resources(Q, Collection, DRG, DWG, Read_Q, Write_Q),
    append(Read_P, Read_Q, Read),
    append(Write_P, Write_Q, Write).
find_resources(when(P,Q), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read_P, Write_P),
    find_resources(Q, Collection, DRG, DWG, Read_Q, Write_Q),
    append(Read_P, Read_Q, Read),
    append(Write_P, Write_Q, Write).
find_resources(using(Collection_String,P), Collection, DRG, _DWG, Read, Write) :-
    resolve_relative_string_descriptor(Collection, Collection_String, Descriptor),
    % NOTE: Don't we need the collection descriptor default filter?
    collection_descriptor_default_write_graph(Descriptor, DWG),
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(size(Path,_), _, DRG_In, _, [resource(Collection,DRG)], []) :-
    (   resolve_absolute_string_descriptor_and_graph(Path, Collection, DRG)
    ->  true
    ;   resolve_absolute_string_descriptor(Path,Collection)
    ->  DRG_In = DRG).
find_resources(triple_count(Path,_), _, DRG_In, _, [resource(Collection,DRG)], []) :-
    (   resolve_absolute_string_descriptor_and_graph(Path, Collection, DRG)
    ->  true
    ;   resolve_absolute_string_descriptor(Path,Collection)
    ->  DRG_In = DRG).
find_resources(from(G,P), Collection, _, DWG, Read, Write) :-
    resolve_filter(G,DRG),
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(into(G,P), Collection, DRG, _, Read, Write) :-
    (   resolve_absolute_graph_descriptor(G,DWG)
    ->  true
    ;   resolve_filter(G,DWG)),
    find_resources(into(G,P), Collection, DRG, DWG, Read, Write).
find_resources(typeof(_,_), Collection, DRG, _DWG, [resource(Collection,DRG)], []).
find_resources('<<'(_,_), Collection, DRG, _, [resource(Collection,DRG)], []).
find_resources(isa(_,_), Collection, DRG, _, [resource(Collection,DRG)], []).
find_resources(select(_, P), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(count(P, _), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(start(_, P), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(limit(_, P), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(order_by(_, P), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(group_by(_,_,P, _), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(distinct(_,P), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(put(_,P, _), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(once(P), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(opt(P), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(not(P), Collection, DRG, DWG, Read, Write) :-
    find_resources(P, Collection, DRG, DWG, Read, Write).
find_resources(get(_,_,_), _, _, _, [], []).
find_resources(typecast(_,_,_,_), _, _, _, [], []).
find_resources(hash(_,_,_), _, _, _, [], []).
find_resources(random_idgen(_,_,_), _, _, _, [], []).
find_resources(idgen(_,_,_), _, _, _, [], []).
find_resources(asc(_), _, _, _, [], []).
find_resources(desc(_), _, _, _, [], []).
find_resources(debug_log(_, _), _, _, _, [], []).
find_resources(concat(_,_),_, _, _, [], []).
find_resources(trim(_,_),_, _, _, [], []).
find_resources('='(_,_),_, _, _, [], []).
find_resources('<'(_,_),_, _, _, [], []).
find_resources('>'(_,_),_, _, _, [], []).
find_resources(like(_,_),_, _, _, [], []).
find_resources(like(_,_,_),_, _, _, [], []).
find_resources(pad(_,_,_,_),_, _, _, [], []).
find_resources(sub_string(_,_,_,_,_),_, _, _, [], []).
find_resources(re(_,_,_),_, _, _, [], []).
find_resources(split(_,_,_),_, _, _, [], []).
find_resources(upper(_,_),_, _, _, [], []).
find_resources(lower(_,_),_, _, _, [], []).
find_resources(format(_,_,_),_, _, _, [], []).
find_resources('is'(_,_),_, _, _, [], []).
find_resources(dot(_,_,_),_, _, _, [], []).
find_resources(length(_,_),_, _, _, [], []).
find_resources(member(_,_),_, _, _, [], []).
find_resources(join(_,_,_),_, _, _, [], []).
find_resources(sum(_,_),_, _, _, [], []).
find_resources(timestamp_now(_),_, _, _, [], []).
find_resources(false,_, _, _, [], []).
find_resources(true,_, _, _, [], []).

assert_pre_flight_access(Context, _AST) :-
    is_super_user(Context.authorization, Context.prefixes),
    % This probably makes all super user checks redundant.
    !.
assert_pre_flight_access(Context, AST) :-
    find_resources(AST,
                   (Context.default_collection),
                   (Context.filter),
                   (Context.write_graph),
                   Read,
                   Write),
    sort(Read,Read_Sorted),
    sort(Write,Write_Sorted),
    forall(member(resource(Collection,Type),Read_Sorted),
           assert_read_access(Context.system, Context.authorization, Collection, Type)),
    forall(member(resource(Collection, Type),Write_Sorted),
           assert_write_access(Context.system, Context.authorization, Collection, Type)).

/*
 * turtle_term(Path,Values,Prog,Options) is det.
 *
 * Create a program term Prog for a csv with Header and column reference strategy
 * Indexing.
 */
turtle_term(Path,Vars,Prog,Options) :-
    Prog = (turtle:rdf_read_turtle(Path, Triples, [encoding(utf8)|Options]),
            member(Triple,Triples),
            literals:normalise_triple(Triple, rdf(X,P,Y)),
            Vars = [X,P,Y]).

compile_wf(get_document(Doc_ID,Doc),
           get_document(S0, URI, JSON)) -->
    resolve(Doc_ID,URI),
    resolve(Doc,JSON),
    peek(S0).
compile_wf(replace_document(Doc),(
               freeze(Guard,
                      replace_document(S0, DocE, _)))) -->
    resolve(Doc,DocE),
    view(update_guard, Guard),
    peek(S0).
compile_wf(replace_document(Doc,X),(
               freeze(Guard,
                      replace_document(S0, DocE, URI)))) -->
    resolve(X,URI),
    resolve(Doc,DocE),
    view(update_guard, Guard),
    peek(S0).
compile_wf(insert_document(Doc,X),(
               freeze(Guard,
                      insert_document(S0, DocE, URI)))) -->
    resolve(X,URI),
    resolve(Doc,DocE),
    view(update_guard, Guard),
    peek(S0).
compile_wf(delete_document(X),(
               freeze(Guard,
                      delete_document(S0, URI)))) -->
    resolve(X,URI),
    view(update_guard, Guard),
    peek(S0).
% TODO: Need to translate the reference WG to a read-write object.
compile_wf(delete(X,P,Y,G),Goal)
-->
    view(default_collection,Collection_Descriptor),
    {
        ensure_filter_resolves_to_graph_descriptor(G, Collection_Descriptor, Graph_Descriptor)
    },
    update(write_graph,Old_Graph_Descriptor,Graph_Descriptor),
    compile_wf(delete(X,P,Y), Goal),
    update(write_graph, _, Old_Graph_Descriptor).
compile_wf(delete(X,P,Y),(
               freeze(Guard,
                      delete(Read_Write_Object,XE,PE,YE,_)
                     )
           ))
-->
    resolve(X,XE),
    resolve_predicate(P,PE),
    resolve(Y,YE),
    view(write_graph,Graph_Descriptor),
    view(transaction_objects, Transaction_Objects),
    view(update_guard, Guard),
    {
       graph_descriptor_transaction_objects_read_write_object(Graph_Descriptor, Transaction_Objects, Read_Write_Object)
    }.
compile_wf(immediately(Goal),Term)
-->
    update(update_guard, Guard, true),
    compile_wf(Goal, Term),
    update(update_guard, _, Guard).
% TODO: Need to translate the reference WG to a read-write object.
compile_wf(insert(X,P,Y,G),Goal)
-->
    view(default_collection,Collection_Descriptor),
    {
        ensure_filter_resolves_to_graph_descriptor(G, Collection_Descriptor, Graph_Descriptor)
    },
    update(write_graph,Old_Graph_Descriptor,Graph_Descriptor),
    compile_wf(insert(X,P,Y), Goal),
    update(write_graph, _, Old_Graph_Descriptor).
compile_wf(insert(X,P,Y),(
               freeze(Guard,
                      ensure_mode(insert(Read_Write_Object,XE,PE,YE,_),
                                  [ground,ground,ground],
                                  [XE,PE,YE],
                                  [X,P,Y]))
           )
          )
-->
    resolve(X,XE),
    resolve_predicate(P,PE),
    resolve(Y,YE),
    view(write_graph,Graph_Descriptor),
    view(transaction_objects, Transaction_Objects),
    view(update_guard, Guard),
    {
        graph_descriptor_transaction_objects_read_write_object(Graph_Descriptor, Transaction_Objects, Read_Write_Object)
    }.
compile_wf(A=B,woql_equal(AE,BE)) -->
    resolve(A,AE),
    resolve(B,BE).
compile_wf(A<B,woql_less(AE,BE)) -->
    resolve(A,AE),
    resolve(B,BE).
compile_wf(A>B,woql_greater(AE,BE)) -->
    resolve(A,AE),
    resolve(B,BE).
compile_wf(like(A,B,F), Isub) -->
    resolve(A,AE),
    resolve(B,BE),
    resolve(F,FE),
    { marshall_args(isub(AE,BE,true,FE), Isub) }.
compile_wf(isa(X,C),is_instance(Transaction_Object,XE,CE)) -->
    resolve(X,XE),
    resolve_predicate(C,CE),
    view(default_collection,Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    {
        collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                 Transaction_Object)
    }.
compile_wf(A << B,(distinct([AE,BE], class_subsumed(Transaction_Object,AE,BE)))) -->
    resolve(A,AE),
    resolve(B,BE),
    view(default_collection,Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    {
        collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                 Transaction_Object)
    }.
compile_wf(opt(P), optional(Goal)) -->
    compile_wf(P,Goal).
compile_wf(addition(X,P,Y),Goal) -->
    resolve(X,XE),
    resolve_predicate(P,PE),
    resolve(Y,YE),
    view(default_collection, Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    view(filter, Filter),
    {
        collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                 Transaction_Object),
        filter_transaction_object_read_write_objects(Filter, Transaction_Object, RWOs),
        Goal = (not_literal(XE),not_literal(PE),xrdf_added(RWOs, XE, PE, YE))
    }.
compile_wf(addition(X,P,Y,G),Goal) -->
    {
        resolve_filter(G,Filter)
    },
    update(filter, Old_Filter, Filter),
    compile_wf(addition(X,P,Y),Goal),
    update(filter, _, Old_Filter).
compile_wf(removal(X,P,Y),Goal) -->
    resolve(X,XE),
    resolve_predicate(P,PE),
    resolve(Y,YE),
    view(default_collection, Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    view(filter, Filter),
    {
        collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                 Transaction_Object),
        filter_transaction_object_read_write_objects(Filter, Transaction_Object, RWOs),
        Goal = (not_literal(XE),not_literal(PE),xrdf_deleted(RWOs, XE, PE, YE))
    }.
compile_wf(removal(X,P,Y,G),Goal) -->
    {
        resolve_filter(G,Filter)
    },
    update(filter, Old_Filter, Filter),
    compile_wf(removal(X,P,Y), Goal),
    update(filter, _Filter, Old_Filter).
compile_wf(t(X,P,Y),Goal) -->
    resolve(X,XE),
    resolve_predicate(P,PE),
    resolve(Y,YE),
    view(default_collection, Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    view(filter, Filter),
    {
        do_or_die(
            collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                     Transaction_Object),
            error(unresolvable_absolute_descriptor(Collection_Descriptor), _)),
        filter_transaction_object_goal(Filter, Transaction_Object, t(XE, PE, YE), Search_Clause),
        Goal = (not_literal(XE),not_literal(PE),Search_Clause)
    }.
compile_wf(t(X,P,Y,G),Goal) -->
    {
        resolve_filter(G,Filter)
    },
    update(filter, Old_Filter, Filter),
    compile_wf(t(X,P,Y), Goal),
    update(filter, _Filter, Old_Filter).
compile_wf(path(X,Pattern,Y),Goal) -->
    compile_wf(path(X,Pattern,Y,_),Goal).
compile_wf(path(X,Pattern,Y,Path),Goal) -->
    resolve(X,XE),
    resolve(Y,YE),
    resolve(Path,PathE),
    view(default_collection, Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    view(filter, Filter),
    view(prefixes,Prefixes),
    {
        collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                 Transaction_Object),
        filter_transaction(Filter, Transaction_Object, New_Transaction_Object),
        (   compile_pattern(Pattern,Compiled_Pattern,Prefixes,New_Transaction_Object)
        ->  true
        ;   throw(error(woql_syntax_error(bad_path_pattern(Pattern)),_))),
        Goal = (
            calculate_path_solutions(Compiled_Pattern,XE,YE,Full_Path,Filter,New_Transaction_Object),
            % Don't bind PathE until we're done with the full query (for constraints)
            Full_Path = PathE
        )
    }.
compile_wf((A;B),(ProgA;ProgB)) -->
    peek(S0),
    compile_wf(A,ProgA),
    peek(S1),
    return(S0),
    compile_wf(B,ProgB),
    merge(S1). % merges S1 back in to current state.
compile_wf(once(A),once(ProgA)) -->
    compile_wf(A,ProgA).
compile_wf((A,B),(ProgA,ProgB)) -->
    compile_wf(A,ProgA),
    compile_wf(B,ProgB),
    {
        debug(terminus(woql_compile(compile_wf)), 'Conjunctive Program: ~q',[(ProgA,ProgB)])
    }.
compile_wf(when(A,B),((ProgA, ProgB) ; true)) --> % forall(ProgA, ProgB)
    compile_wf(A,ProgA),
    compile_wf(B,ProgB).
compile_wf(select(VL,P), Prog) -->
    visible_vars(Visible),
    compile_wf(P, Prog),
    { union(Visible,VL,Restricted) },
    restrict(Restricted).
compile_wf(using(Collection_String,P),Goal) -->
    update(default_collection,Old_Default_Collection,Default_Collection),
    update(write_graph,Old_Write_Graph,Write_Graph_Descriptor),
    update(prefixes,Old_NS,New_NS),
    {
        do_or_die(
            resolve_string_descriptor(Old_Default_Collection,Collection_String,Default_Collection),
            error(invalid_absolute_path(Collection_String),_)),
        collection_descriptor_default_write_graph(Default_Collection, Write_Graph_Descriptor)
    },
    update_descriptor_transactions(Default_Collection),
    % Setup prefixes for resolution
    view(transaction_objects,Transaction_Objects),
    {
        collection_descriptor_transaction_object(Default_Collection,Transaction_Objects,
                                                 Transaction_Object),
        database_prefixes(Transaction_Object, Prefixes),
        put_dict(Prefixes, Old_NS, New_NS)
    },
    compile_wf(P, Goal),
    update(prefixes,_,Old_NS),
    update(write_graph,_,Old_Write_Graph),
    update(default_collection,_,Old_Default_Collection).
compile_wf(from(Filter_String,P),Goal) -->
    { resolve_filter(Filter_String,Filter) },
    update(filter,Old_Default_Filter,Filter),
    compile_wf(P, Goal),
    update(filter,_,Old_Default_Filter).
compile_wf(prefixes(NS,S), Prog) -->
    % Need to convert the datatype of prefixes here.
    update(prefixes,NS_Old,NS_New),
    { append(NS, NS_Old, NS_New) },
    compile_wf(S, Prog),
    update(prefixes,_,NS_Old).
% NOTE: DEPRECATED
compile_wf(with(GN,GS,Q), (Program, Sub_Query)) -->
    resolve(GN,GName),
    update(default_collection,Old_Default_Collection,Default_Collection),
    view(files,Files),
    % TODO: Extend with options for various file types.
    { file_spec_path_options(GS, Files, Path, _{}, Options),
      extend_database_with_temp_graph(GName,Path,Options,Program,Old_Default_Collection,Default_Collection)
    },
    compile_wf(Q,Sub_Query),
    update(default_collection,_,Old_Default_Collection).
compile_wf(get(Spec,resource(Resource,Format,Options),Has_Header), Prog) -->
    {
        (   as_vars(Spec,Vars)
        ->  true
        ;   position_vars(Spec,Vars)
        )
    },

    % Make sure all variables are given bindings
    mapm(resolve,Vars,BVars),
    view(bindings,Bindings),
    view(files,Files),
    {
        file_spec_path_options(Resource, Files, Path, Options, New_Options),
        convert_csv_options(New_Options,CSV_Options),

        (   Format = csv
        ->  indexing_term(Spec,Header,Values,Bindings,Indexing_Term),
            csv_term(Path,Has_Header,Header,Values,Indexing_Term,Prog,CSV_Options)
        ;   Format = turtle,
            Has_Header = false
        ->  turtle_term(Path,BVars,Prog,CSV_Options)
        ;   Format = panda
        ->  indexing_term(Spec,Header,Values,Bindings,Indexing_Term),
            json_term(Path,Header,Values,Indexing_Term,Prog,New_Options)
        ;   format(atom(M), 'Unknown file type for "get" processing: ~q', [Resource]),
            throw(error(M)))
    }.
compile_wf(put(Spec,Query,resource(File_Spec,_Format,_Opts)), Prog) -->
    {
        maplist([Name as Var,Var,Name]>>(true), Spec, Vars, Names)
    },
    % Make sure all variables are bound
    mapm(resolve,Vars,VarsE),
    compile_wf(Query,Compiled_Query),
    {

        (   File_Spec = file(CSV_Path,_Options),
            Options = []
        ;   File_Spec = file(CSV_Path),
            Options = []),

        Header_Row =.. [row|Names],

        Prog = setup_call_cleanup(
                   open(CSV_Path, write, Out),
                   (
                       csv_write_stream(Out,[Header_Row], Options),
                       forall(
                           (
                               Compiled_Query,
                               maplist([Value,Data]>>(
                                           (   Value=Data@_
                                           ->  true
                                           ;   Value=Data^^_
                                           ->  true
                                           ;   Data=Value)
                                       ),
                                       VarsE, Row_Data),
                               Row_Term =.. [row|Row_Data]
                           ),
                           csv_write_stream(Out,[Row_Term],Options)
                       )
                   ),
                   close(Out)
               )
    }.
compile_wf(typecast(Val,Type,_Hints,Cast),
           (typecast(ValE, TypeE, [], CastE))) -->
    resolve(Val,ValE),
    resolve(Type,TypeE),
    resolve(Cast,CastE).
% Note: Should we not just make a transformer for marshalling?
compile_wf(hash(Base,Args,Id),(
               literally(BaseE,BaseL),
               literally(ArgsE,ArgsL),
               idgen_hash(BaseL,ArgsL,IdS),
               atom_string(IdE,IdS),
               unliterally(BaseL,BaseE),
               unliterally(ArgsL,ArgsE)
           )) -->
    resolve(Base, BaseE),
    mapm(resolve,Args,ArgsE),
    resolve(Id,IdE).
compile_wf(random_idgen(Base,Args,Id),(
               literally(BaseE,BaseL),
               literally(ArgsE,ArgsL),
               idgen_random(BaseL,ArgsL,IdS),
               atom_string(IdE,IdS),
               unliterally(BaseL,BaseE),
               unliterally(ArgsL,ArgsE)
           )) -->
    resolve(Base, BaseE),
    mapm(resolve,Args,ArgsE),
    resolve(Id,IdE).
compile_wf(idgen(Base,Args,Id),(
               literally(BaseE,BaseL),
               literally(ArgsE,ArgsL),
               idgen_lexical(BaseL,ArgsL,IdS),
               atom_string(IdE,IdS),
               unliterally(BaseL,BaseE),
               unliterally(ArgsL,ArgsE)
           )) -->
    resolve(Base, BaseE),
    mapm(resolve,Args,ArgsE), % Note: How can we resolve this properly? Freeze?
    resolve(Id,IdE).
compile_wf(start(N,S),(literally(NE,Num),offset(Num,Prog))) -->
    resolve(N,NE),
    compile_wf(S, Prog).
compile_wf(limit(N,S),(literally(NE,Num),limit(Num,Prog))) -->
    resolve(N,NE),
    compile_wf(S, Prog).
compile_wf(count(P,N), (literally(NE,Num),aggregate_all(count, Prog, Num),unliterally(Num,NE))) -->
    resolve(N, NE),
    visible_vars(Visible),
    compile_wf(P,Prog),
    restrict(Visible).
compile_wf(asc(X),asc(XE)) -->
    resolve(X,XE).
compile_wf(desc(X),desc(XE)) -->
    resolve(X,XE).
compile_wf(order_by(L,S),order_by(LSpec,Prog)) -->
    mapm(compile_wf, L, LSpec),
    compile_wf(S, Prog).
compile_wf(into(G,S),Goal) -->
    % TODO: Resolve G to descriptor
    % swap in new graph
    view(default_collection, Collection_Descriptor),
    view(transaction_objects, Transaction_Objects),
    {
        (   resolve_absolute_string_graph_descriptor(G, Graph_Descriptor)
        ->  true
        ;   resolve_filter(G,Filter),
            collection_descriptor_transaction_object(Collection_Descriptor,Transaction_Objects,
                                                     Transaction_Object),
            (   Filter = type_name_filter{ type : _Type, names : [_Name]}
            ->  filter_transaction_graph_descriptor(Filter, Transaction_Object, Graph_Descriptor)
            ;   throw(error(woql_syntax_error(unresolvable_write_filter(G)),_))
            )
        )
    },
    update(write_graph,OG,Graph_Descriptor),
    compile_wf(S,Goal),
    % swap old graph back in
    update(write_graph,_,OG).
compile_wf(not(P),not(Q)) -->
    compile_wf(P, Q).
compile_wf(concat(L,A),Concat) -->
    resolve(L,LE),
    resolve(A,AE),
    { marshall_args(interpolate_string(LE,AE),Concat) }.
compile_wf(trim(S,A),Trim) -->
    resolve(S,SE),
    resolve(A,AE),
    { marshall_args(trim(SE,AE),Trim) }.
compile_wf(pad(S,C,N,V),Pad) -->
    resolve(S,SE),
    resolve(C,CE),
    resolve(N,NE),
    resolve(V,VE),
    { marshall_args(pad(SE,CE,NE,VE,Pad),Pad) }.
compile_wf(sub_string(S,B,L,A,Sub),Sub_String) -->
    resolve(S,SE),
    resolve(B,BE),
    resolve(L,LE),
    resolve(A,AE),
    resolve(Sub,SubE),
    { marshall_args(utils:sub_string(SE,BE,LE,AE,SubE),Sub_String) }.
compile_wf(re(P,S,L),Re) -->
    resolve(P,PE),
    resolve(S,SE),
    resolve(L,LE),
    { marshall_args(utils:re(PE,SE,LE),Re),
      debug(compilation,"re: ~q",[Re])
    }.
compile_wf(split(S,P,L),Split) -->
    resolve(S,SE),
    resolve(P,PE),
    resolve(L,LE),
    { marshall_args(utils:pattern_string_split(PE,SE,LE),Split) }.
compile_wf(upper(S,A),Upper) -->
    resolve(S,SE),
    resolve(A,AE),
    { marshall_args(string_upper(SE,AE), Upper) }.
compile_wf(lower(S,A),Lower) -->
    resolve(S,SE),
    resolve(A,AE),
    { marshall_args(string_lower(SE,AE),Lower) }.
compile_wf(format(X,A,L),format(atom(XE),A,LE)) -->
    % TODO: You can execute an arbitrary goal!!!!
    resolve(X,XE),
    mapm(resolve,L,LE).
compile_wf(X is Arith, (Pre_Term,
                        XA is ArithE,
                        XE = XA^^'http://www.w3.org/2001/XMLSchema#decimal')) -->
    resolve(X,XE),
    compile_arith(Arith,Pre_Term,ArithE).
compile_wf(dot(Dict,Key,Value), get_dict(KeyE,DictE,ValueE)) -->
    resolve(Dict,DictE),
    resolve(Key,KeyE),
    resolve(Value,ValueE).
compile_wf(group_by(WGroup,WTemplate,WQuery,WAcc),group_by(Group,Template,Query,Acc)) -->
    resolve(WGroup,Group),
    resolve(WTemplate,Template),
    compile_wf(WQuery, Query),
    resolve(WAcc,Acc).
compile_wf(distinct(X,WQuery), distinct(XE,Query)) -->
    resolve(X,XE),
    compile_wf(WQuery,Query).
compile_wf(length(L,N),Length) -->
    resolve(L,LE),
    resolve(N,NE),
    { marshall_args(length(LE,NE), Length) }.
compile_wf(member(X,Y),member(XE,YE)) -->
    resolve(X,XE),
    resolve(Y,YE).
compile_wf(join(X,S,Y),Join) -->
    resolve(X,XE),
    resolve(S,SE),
    resolve(Y,YE),
    {
        marshall_args(utils:join(XE,SE,YE), Goal),
        Join = ensure_mode(Goal,[ground,ground,any],[XE,SE,YE],[X,S,Y])
    }.
compile_wf(sum(X,Y),Sum) -->
    resolve(X,XE),
    resolve(Y,YE),
    {
        marshall_args(sum_list(XE,YE), Goal),
        Sum = ensure_mode(Goal,[ground,any],[XE,YE],[X,Y])
    }.
compile_wf(timestamp_now(X), (get_time(Timestamp)))
-->
    resolve(X,XE),
    {
        XE = Timestamp^^'http://www.w3.org/2001/XMLSchema#decimal'
    }.
compile_wf(size(Path,Size),Goal) -->
    resolve(Size,SizeE),
    {
        (   resolve_absolute_string_descriptor_and_graph(Path, Descriptor, Graph)
        ->  true
        ;   resolve_absolute_string_descriptor(Path, Descriptor),
            Graph = none
        )
    },
    update_descriptor_transactions(Descriptor),
    peek(Context),
    {
        Context_2 = (Context.put(_{ default_collection : Descriptor })),
        Transaction_Objects = (Context_2.transaction_objects),
        (   Graph = none
        ->  collection_descriptor_transaction_object(Descriptor,Transaction_Objects,
                                                     Transaction_Object),
            Goal = (transaction_object_size(Transaction_Object,Numerical_Size),
                    unliterally(Numerical_Size,SizeE))
        ;   graph_descriptor_transaction_objects_read_write_object(Graph, Transaction_Objects, Read_Write_Object),
            Goal = (read_object_size(Read_Write_Object,Numerical_Size),
                    unliterally(Numerical_Size,SizeE))
        )
    }.
compile_wf(triple_count(Path,Count),Goal) -->
    resolve(Count,CountE),
    {
        (   resolve_absolute_string_descriptor_and_graph(Path, Descriptor, Graph)
        ->  true
        ;   resolve_absolute_string_descriptor(Path, Descriptor),
            Graph = none
        )
    },
    update_descriptor_transactions(Descriptor),
    peek(Context),
    {
        Context_2 = (Context.put(_{ default_collection : Descriptor })),
        Transaction_Objects = (Context_2.transaction_objects),
        (   Graph = none
        ->  collection_descriptor_transaction_object(Descriptor,Transaction_Objects,
                                                     Transaction_Object),
            Goal = (transaction_object_triple_count(Transaction_Object,Numerical_Count),
                    unliterally(Numerical_Count,CountE))
        ;   graph_descriptor_transaction_objects_read_write_object(Graph, Transaction_Objects, Read_Write_Object),
            Goal = (read_object_triple_count(Read_Write_Object,Numerical_Count),
                    unliterally(Numerical_Count,CountE))
        )
    }.
compile_wf(debug_log(Format_String, Arguments), json_log_info_formatted(Format_String, ArgumentsE)) -->
    resolve(Arguments, ArgumentsE).
compile_wf(typeof(X,T), typeof(XE,TE)) -->
    resolve(X,XE),
    resolve(T,TE).
compile_wf(false,false) -->
    [].
compile_wf(true,true) -->
    [].

typeof(X,T) :-
    var(X),
    var(T),
    !,
    when(nonvar(X), typeof(X,T)),
    when(nonvar(T), typeof(X,T)).
typeof(X,T) :-
    var(X),
    !,
    when(nonvar(X),
         typeof(X,T)).
typeof(_@T,S^^'http://www.w3.org/2001/XMLSchema#string') :-
    atom_string(T,S),
    !.
typeof(_^^T,T) :-
    !.
typeof(A,T) :-
    atom(A),
    T = 'http://www.w3.org/2002/07/owl#Thing'.

:- meta_predicate ensure_mode(0,+,+,+).
ensure_mode(Goal,Mode,Args,Names) :-
    catch(
        call(Goal),
        error(instantiation_error,_),
        (   find_mode_violations(Mode,Args,Names,Violations),
            throw(error(woql_instantiation_error(Violations),_)))
    ).

find_mode_violations([],[],[],[]).
find_mode_violations([ground|Mode],[Arg|Args],[Name|Names],New_Violations) :-
    find_mode_violations(Mode,Args,Names,Violations),
    (   var(Arg)
    ->  Name = v(Var),
        New_Violations = [Var|Violations]
    ;   New_Violations = Violations).
find_mode_violations([any|Mode],[_|Args],[_|Names],Violations) :-
    find_mode_violations(Mode,Args,Names,Violations).

debug_wf(Lit) -->
    { debug(terminus(woql_compile(compile_wf)), '~w', [Lit]) },
    [].

debug_wf(Fmt, Args) -->
    { debug(terminus(woql_compile(compile_wf)), Fmt, Args) },
    [].

%%
% update_descriptor_transaction(Descriptor, Context1, Context2) is det.
%
% Open a new descriptor and put it on the transaction pile
% making sure not to screw up the uniqueness of each object.
update_descriptor_transactions(Descriptor) -->
    update(transaction_objects, Transaction_Objects, New_Transaction_Objects),
    peek(Context),
    {   (   get_dict(commit_info, Context, Commit_Info)
        ->  true
        ;   Commit_Info = _{}),
        transactions_to_map(Transaction_Objects, Map),
        do_or_die(
            open_descriptor(Descriptor, Commit_Info, Transaction_Object, Map, _Map),
            error(unresolvable_absolute_descriptor(Descriptor),_)),
        union([Transaction_Object], Transaction_Objects, New_Transaction_Objects)
    }.


/*
 * file_spec_path_options(File_Spec,Path,Default, Options) is semidet.
 *
 * Converts a file spec into a referenceable file path which can be opened as a stream.
 */
file_spec_path_options(File_Spec,_Files,Path,Default,New_Options) :-
    (   File_Spec = file(Path,Options)
    ;   File_Spec = file(Path),
        Options = []),
    merge_options(Options,Default,New_Options).
file_spec_path_options(File_Spec,_Files,Path,Default,New_Options) :-
    (   File_Spec = remote(URI,Options)
    ;   File_Spec = remote(URI),
        Options = []),
    merge_options(Options,Default,New_Options),
    copy_remote(URI,URI,Path,New_Options).
file_spec_path_options(File_Spec,Files,Path,Default,New_Options) :-
    (   File_Spec = post(Name,Options)
    ;   File_Spec = post(Name),
        Options = []),
    atom_string(Name_Atom,Name),
    merge_options(Options,Default,New_Options),
    memberchk(Name_Atom=Path, Files).


%%
% marshall_args(M_Pred, Trans) is det.
%
% NOTE: The marshalling of args creates a situation in which incorrect modes
% of underlying predicates report the wrong value.
%
% Better is if we had a registration system, which took allowed modes and types.
%
marshall_args(M_Pred,Goal) :-
    strip_module(M_Pred, M, Pred),
    Pred =.. [Func|ArgsE],
    length(ArgsE,N),
    length(ArgsL,N),
    maplist([AE,AL,literally(AE,AL)]>>true, ArgsE, ArgsL, Pre),
    maplist([AE,AL,unliterally(AL,AE)]>>true, ArgsE, ArgsL, Post),
    Lit_Pred =.. [Func|ArgsL],
    append([Pre,[M:Lit_Pred],Post], Term_List),
    xfy_list(',',Goal,Term_List).

literally(X, _X) :-
    var(X),
    !.
literally(Date^^'http://www.w3.org/2001/XMLSchema#dateTime', String) :-
    Date = date(_Y,_M,_D,_HH,_MM,_SS,_,_,_),
    !,
    date_string(Date,String).
literally(X^^_T, X) :-
    !.
literally(X@_L, X) :-
    !.
literally([],[]) :-
    !.
literally([H|T],[HL|TL]) :-
    !,
    literally(H,HL),
    literally(T,TL).
literally(X, X) :-
    (   atom(X)
    ->  true
    ;   string(X)
    ->  true
    ;   number(X)
    ->  true
    ;   is_dict(X)
    ).

unliterally(X,Y) :-
    string(X),
    !,
    (   Y = YVal^^Type,
        (   var(Type)
        ->  Type = 'http://www.w3.org/2001/XMLSchema#string',
            YVal = X
        ;   Type = 'http://www.w3.org/2001/XMLSchema#dateTime'
        ->  date_string(YVal,X)
        ;   YVal = X)
    ->  true
    ;   Y = X@Lang,
        (   var(Lang)
        ->  Lang = en
        ;   true)
    ).
unliterally(X,Y) :-
    atom(X),
    atom(Y),
    !,
    X = Y.
unliterally(X,Y) :-
    number(X),
    !,
    (   Y = X^^Type,
        (   var(Type)
        ->  Type = 'http://www.w3.org/2001/XMLSchema#decimal'
        ;   % subsumption test here.
            true)
    ->  true
    ;   Y = X@Lang,
        (   var(Lang)
        ->  Lang = en
        ;   true)
    ).
unliterally(X,Y) :-
    is_dict(X),
    !,
    X = Y.
unliterally([],[]).
unliterally([H|T],[HL|TL]) :-
    unliterally(H,HL),
    unliterally(T,TL).

compile_arith(Exp,Pre_Term,ExpE) -->
    {
        Exp =.. [Functor|Args],
        % lazily snarf everything named...
        % probably need to add stuff here.
        member(Functor, ['*','-','+','div','/','floor', '**'])
    },
    !,
    mapm(compile_arith,Args,Pre_Terms,ArgsE),
    {
        ExpE =.. [Functor|ArgsE],
        list_conjunction(Pre_Terms,Pre_Term)
    }.
compile_arith(Exp,literally(ExpE,ExpL),ExpL) -->
    resolve(Exp,ExpE).

visible_vars(VL) -->
    view(bindings, Bindings),
    { maplist([Record,v(Name)]>>get_dict(var_name, Record, Name),
              Bindings,
              VL) }.

order_select_([],_B0,[]).
order_select_([v(V)|Vs],B0,[Record|B1]) :-
    member(Record,B0),
    get_dict(var_name, Record, V),
    !,
    order_select_(Vs,B0,B1).
order_select_([_|Vs],B0,B1) :-
    order_select_(Vs,B0,B1).

order_select(Vs,B0,B1) :-
    order_select_(Vs,B0,B_Out),
    reverse(B_Out,B1).

restrict(VL) -->
    update(bindings,B0,B1),
    {
        order_select(VL,B0,B1)
    }.

% Could be a single fold, but then we always get a conjunction with true
list_conjunction([],true).
list_conjunction(L,Goal) :-
    L = [_|_],
    reverse(L,R),
    R = [A|Rest],
    foldl([X,Y,(X,Y)]>>true, Rest, A, Goal).

list_disjunction([],true).
list_disjunction(L,Goal) :-
    L = [_|_],
    reverse(L,R),
    R = [A|Rest],
    foldl([X,Y,(X;Y)]>>true, Rest, A, Goal).


ensure_filter_resolves_to_graph_descriptor(G, Collection_Descriptor, Graph_Descriptor) :-
    resolve_filter(G,Filter),
    collection_descriptor_graph_filter_graph_descriptor(Collection_Descriptor,
                                                        Filter,
                                                        Graph_Descriptor),
    !.
ensure_filter_resolves_to_graph_descriptor(G, _Collection_Descriptor, _Graph_Descriptor) :-
    throw(error(woql_syntax_error(filter_does_not_resolve_to_unique_graph(G)), _)).

/* NOTE: Should this go in resolve_query_resource.pl? */
filter_transaction_object_read_write_objects(type_filter{ types : Types}, Transaction_Object, Read_Write_Objects) :-
    (   memberchk(instance,Types)
    ->  Instance_Objects = Transaction_Object.instance_objects
    ;   Instance_Objects = []),
    (   memberchk(schema,Types)
    ->  Schema_Objects = Transaction_Object.schema_objects
    ;   Schema_Objects = []),
    append([Instance_Objects,Schema_Objects],Read_Write_Objects).
filter_transaction_object_read_write_objects(type_name_filter{ type : Type}, Transaction_Object, Objs) :-
    (   Type = instance
    ->  Objs = Transaction_Object.instance_objects
    ;   Type = schema
    ->  Objs = Transaction_Object.schema_objects).

filter_transaction_object_goal(type_filter{ types : Types }, Transaction_Object, t(XE, PE, YE), Goal) :-
    (   memberchk(instance,Types)
    ->  Search_1 = [xrdf(Transaction_Object.instance_objects, XE, PE, YE)]
    ;   Search_1 = []),
    (   memberchk(schema,Types)
    ->  Search_2 = [xrdf(Transaction_Object.schema_objects, XE, PE, YE)]
    ;   Search_2 = []),
    append([Search_1,Search_2], Searches),
    list_disjunction(Searches,Goal).
filter_transaction_object_goal(type_name_filter{ type : instance}, Transaction_Object, t(XE, PE, YE), Goal) :-
    Goal = xrdf((Transaction_Object.instance_objects), XE, PE, YE).
filter_transaction_object_goal(type_name_filter{ type : schema}, Transaction_Object, t(XE, PE, YE), Goal) :-
    Goal = xrdf((Transaction_Object.schema_objects), XE, PE, YE).

filter_transaction_graph_descriptor(type_name_filter{ type : Type},Transaction,Graph_Descriptor) :-
    (   Type = instance
    ->  Objects = Transaction.instance_objects
    ;   Type = schema
    ->  Objects = Transaction.schema_objects),
    find({Name}/[Obj]>>read_write_object_to_name(Obj,Name), Objects, Found),
    Graph_Descriptor = Found.get(descriptor).

filter_transaction(type_filter{ types : _Types }, Transaction, Transaction).
filter_transaction(type_name_filter{ type : instance}, Transaction, New_Transaction) :-
    New_Transaction = transaction_object{
                          parent : (Transaction.parent),
                          instance_objects : (Transaction.instance_objects),
                          schema_objects : (Transaction.schema_objects)
                      }.
filter_transaction(type_name_filter{ type : schema}, Transaction, New_Transaction) :-
    New_Transaction = transaction_object{
                          parent : Transaction.parent,
                          instance_objects : [],
                          schema_objects : (Transaction.schema_objects)
                      }.

:- begin_tests(woql).

% At some point this should be exhaustive. Currently we add as we find bugs.

:- use_module(ask,[ask/2,create_context/2, create_context/3, context_extend_prefixes/3]).
% NOTE: This circularity is very irritating...
% We are merely hoping that query_response is loaded before we run this test.
%:- use_module(query_response, [run_context_ast_jsonld_response/3]).
:- use_module(library(ordsets)).
:- use_module(core(util/test_utils)).
:- use_module(core(api)).
:- use_module(core(transaction)).

query_test_response_test_branch(Query, Response) :-
    make_branch_descriptor('admin', 'test', Descriptor),
    query_test_response(Descriptor, Query, Response).

save_and_retrieve_woql(Query_In, Query_Out) :-
    random(0,10000,Random),
    format(atom(Label), "woql_~q", [Random]),
    test_woql_label_descriptor(Label, Descriptor),
    run_insert_document(Descriptor, commit_object{ author : "automated test framework",
                                                   message : "testing"}, Query_In, Id),
    * print_all_triples(Descriptor),
    get_document(Descriptor, Id, Query_Out).

query_test_response(Descriptor, Query, Response) :-
    create_context(Descriptor,commit_info{ author : "automated test framework",
                                           message : "testing"}, Context),
    json_woql(Query, AST),
    query_response:run_context_ast_jsonld_response(Context, AST, Response).

test(subsumption, [setup(setup_temp_store(State)),
                   cleanup(teardown_temp_store(State))
                  ])
:-
    Query = _{'@type' : "Subsumption",
              'child' : _{ '@type' : "NodeValue",
                           'node' : "Organization"},
              'parent' : _{'@type' : "NodeValue",
                           'variable' : "Parent"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(system_descriptor{}, Query_Out, JSON),
    % Tag the dicts so we can sort them
    maplist([D,D]>>(json{} :< D), JSON.bindings, Orderable),
    Orderable = [json{'Parent':'Organization'}].

test(substring, [
         setup((setup_temp_store(State),
                create_db_without_schema(admin,test))),
         cleanup(teardown_temp_store(State))
     ])
:-
    Query = _{'@type' : "Substring",
              'string' : _{ '@type' : "DataValue",
                            data : _{'@type' : "xsd:string",
                                     '@value' : "Test"}},
              'before' : _{ '@type' : "DataValue",
                            data : _{'@type' : "xsd:integer",
                                     '@value' : 1}},
              'length' : _{'@type' : "DataValue",
                           variable : "Length"},
              'after' : _{ '@type' : "DataValue",
                           data : _{'@type' : "xsd:integer",
                                    '@value' : 1}},
              'substring' : _{'@type' : "DataValue",
                              variable : "Substring"}
             },

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),
    [Res] = JSON.bindings,
    _{'Length':_{'@type':'xsd:decimal','@value':2},
      'Substring':_{'@type':'xsd:string','@value':"es"}
     } :< Res.

test(typecast_string_integer, [
         setup((setup_temp_store(State),
                create_db_without_schema(admin,test))),
         cleanup(teardown_temp_store(State))
     ])
:-
    Query = _{'@type' : "Typecast",
              value : _{ '@type' : "Value",
                         data : _{'@type' : "xsd:string",
                                  '@value' : "202"}},
              type : _{ '@type' : "NodeValue",
                        node : "xsd:integer"},
              result : _{'@type' : "Value",
                         variable : "Casted"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),
    [Res] = JSON.bindings,
    _{'Casted':_{'@type':'xsd:integer',
                 '@value':202}} :< Res.

test(eval, [
         setup((setup_temp_store(State),
                create_db_without_schema(admin,test))),
         cleanup(teardown_temp_store(State))
     ])
:-
    Query = _{'@type' : "Eval",
              expression :
              _{ '@type' : "Plus",
                 left : _{ '@type' : "ArithmeticValue",
                           data : _{'@type' : "xsd:integer",
                                    '@value' : 2}},
                 right : _{ '@type' : "ArithmeticValue",
                            data : _{'@type' : "xsd:integer",
                                     '@value' : 2}}},
              result : _{'@type' : "ArithmeticValue",
                         variable : "Sum"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),

    [Res] = JSON.bindings,
    _{'Sum':_{'@type':'xsd:decimal',
              '@value':4}} :< Res.


test(add_triple, [
         setup((setup_temp_store(State),
                create_db_without_schema(admin,test))),
         cleanup(teardown_temp_store(State))
     ])
:-
    Query = _{'@type' : "AddTriple",
              'subject' : _{ '@type' : "NodeValue",
                             'node' : "DBadmin"},
              'predicate' : _{ '@type' : "NodeValue",
                               'node' : "rdfs:label"},
              'object' : _{ '@type' : "Value",
                            'node' : "xxx"}},

    make_branch_descriptor('admin', 'test', Descriptor),

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(Descriptor, Query_Out, JSON),
    JSON.inserts = 1.

test(add_quad, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ])
:-
    Query = _{'@type' : "AddTriple",
              'subject' : _{ '@type' : "NodeValue",
                             'node' : "DBadmin"},
              'predicate' : _{ '@type' : "NodeValue",
                               'node' : "rdfs:label"},
              'object' : _{ '@type' : "Value",
                            'node' : "xxx"},
              'graph' : "instance"
             },

    make_branch_descriptor('admin', 'test', Descriptor),
    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(Descriptor, Query_Out, JSON),
    JSON.inserts = 1.

test(upper, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Query = _{'@type' : "Upper",
              mixed : _{ '@type' : "DataValue",
                         data : _{ '@type' : "xsd:string",
                                   '@value' : "Aaaa"}},
              upper : _{'@type' : "DataValue",
                        variable : "Upcased"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),
    [Res] = JSON.bindings,
    _{'Upcased':_{'@type':'xsd:string',
                  '@value': "AAAA"}} :< Res.


test(unique, [
         setup((setup_temp_store(State),
                create_db_without_schema(admin,test))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Query = _{'@type' : "HashKey",
              'base' : _{ '@type' : "DataValue",
                          data : _{ '@type' : "xsd:string",
                                    '@value' : "http://foo.com/"}},
              'key_list' : [_{ '@type' : "DataValue",
                               data : _{ '@type' : "xsd:string",
                                         '@value' : "a"}},
                            _{ '@type' : "DataValue",
                               data : _{ '@type' : "xsd:string",
                                         '@value' : "b"}},
                            _{ '@type' : "DataValue",
                               data : _{ '@type' : "xsd:string",
                                         '@value' : "c"}}],
              'uri' : _{'@type' : "NodeValue",
                        variable : "URI"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),

    [Res] = JSON.bindings,
    _{ 'URI':'http://foo.com/ff02308b1ff78b66ab564140c91419e94e47644d3e94addcc8b0864058ca4028'} :< Res.

test(split, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Query = _{'@type' : "Split",
              'string' : _{ '@type' : "DataValue",
                            data : _{ '@type' : "xsd:string",
                                      '@value' : "you_should_be_split"}},
              'pattern' : _{ '@type' : "DataValue",
                             data : _{ '@type' : "xsd:string",
                                       '@value' : "_"}},
              'list' : _{'@type' : "DataValue",
                         variable : "Split"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),
    [Res] = JSON.bindings,
    _{'Split': [_{'@type':'xsd:string','@value':"you"},
                _{'@type':'xsd:string','@value':"should"},
                _{'@type':'xsd:string','@value':"be"},
                _{'@type':'xsd:string','@value':"split"}]}
                 :< Res.


test(join, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Query = _{'@type' : "Join",
              'list' : _{ '@type' : 'DataValue',
                          'list' : [_{ '@type' : "DataValue",
                                       data : _{ '@type' : "xsd:string",
                                                 '@value' : "you"}},
                                    _{ '@type' : "DataValue",
                                       data : _{ '@type' : "xsd:string",
                                                 '@value' : "should"}},
                                    _{ '@type' : "DataValue",
                                       data : _{ '@type' : "xsd:string",
                                                 '@value' : "be"}},
                                    _{ '@type' : "DataValue",
                                       data : _{ '@type' : "xsd:string",
                                                 '@value' : "joined"}}]
                        },
              'separator' : _{ '@type' : "DataValue",
                               data : _{ '@type' : "xsd:string",
                                         '@value' : "_"}},
              'result' : _{'@type' : "DataValue",
                           variable : "Join"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),
    [Res] = JSON.bindings,
    _{'Join': _{'@type':'xsd:string',
                '@value':"you_should_be_joined"}} :< Res.

test(like, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Query = _{'@type' : "Like",
              'left' : _{ '@type' : "DataValue",
                          data : _{ '@type' : "xsd:string",
                                    '@value' : "joined"}},
              'right' : _{ '@type' : "DataValue",
                           data : _{ '@type' : "xsd:string",
                                     '@value' : "joined"}},
              'similarity' : _{'@type' : "DataValue",
                               variable : "Similarity"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),
    [Res] = JSON.bindings,
    _{'Similarity':_{'@type':'xsd:decimal',
                     '@value':1.0}} :< Res.

test(exp, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    Query = _{'@type' : "Eval",
              expression :
              _{ '@type' : "Exp",
                 left : _{ '@type' : "ArithmeticValue",
                           data : _{'@type' : "xsd:integer",
                                    '@value' : 2}},
                 right : _{ '@type' : "ArithmeticValue",
                            data : _{'@type' : "xsd:integer",
                                     '@value' : 2}}},
              result : _{'@type' : "ArithmeticValue",
                         variable : "Exp"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),
    [Res] = JSON.bindings,
    _{'Exp':_{'@type':'xsd:decimal',
              '@value':4}} :< Res.

test(limit, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    make_branch_descriptor('admin', 'test', Descriptor),
    create_context(Descriptor, commit_info{ author : "test",
                                            message : "testing"}, Context),

    with_transaction(
        Context,
        ask(Context, (insert('x','y','z'),
                      insert('x','y','w'),
                      insert('x','y','q'))),
        _Meta),

    Query = _{'@type' : "Limit",
              limit :  2,
              query : _{ '@type' : "Triple",
                         'subject' : _{'@type' : "NodeValue",
                                       variable : "Subject"},
                         'predicate' : _{'@type' : "NodeValue",
                                         variable : "Predicate"},
                         'object' : _{'@type' : "Value",
                                      variable : "Object"}
                       }},
    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(Descriptor, Query_Out, JSON),
    maplist([D,D]>>(json{} :< D), JSON.bindings, Orderable),

    list_to_ord_set(Orderable,Bindings_Set),
    list_to_ord_set([json{'Object':q,'Predicate':'@schema:y','Subject':x},
                     json{'Object':w,'Predicate':'@schema:y','Subject':x}],
                    Expected),
    ord_seteq(Bindings_Set,Expected).

test(indexed_get,
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State)),
         fixme('Depends on external URL')
    )
:-
    Query =
    _{'@type' : 'Get',
      columns : [
          _{'@type' : 'Column',
            indicator : _{ '@type' : "Indicator",
                           index: 0},
            variable: "First"},
          _{'@type' : 'Column',
            indicator : _{ '@type' : "Indicator",
                           index: 1},
            variable : "Second"}],
      resource :
      _{'@type' : 'QueryResource',
        format : "csv",
        source : _{ '@type' : "Source",
                    url : "https://terminusdb.com/t/data/bike_tutorial.csv"}}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),
    [Res|_] = JSON.bindings,
    % Should this really be without a header?
    _{'First':_{'@type':'xsd:string','@value':"Duration"},
      'Second':_{'@type':'xsd:string','@value':"Start date"}} :< Res.

test(named_get, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State)),
         fixme('Depends on external URL')
     ])
:-
    Query =
    _{'@type' : 'Get',
      columns : [
          _{'@type' : 'Column',
            indicator : _{ '@type' : "Indicator",
                           name : "Duration"},
            variable : "Duration"},
          _{'@type' : 'Column',
            indicator : _{ '@type' : "Indicator",
                           name : "Bike number"},
            variable : "Bike_Number"}
      ],
      resource :
      _{'@type' : 'QueryResource',
        format: "csv",
        source: _{ '@type' : "Source",
                   url: "https://terminusdb.com/t/data/bike_tutorial.csv"}}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),
    [First|_] = JSON.bindings,

    _{'Bike_Number': _{'@type':'xsd:string',
                      '@value':"W21477"},
      'Duration': _{'@type':'xsd:string',
                    '@value':"790"}
     } :< First.

test(named_get_two, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State)),
         fixme('Depends on external URL')
     ])
:-
    Query =
    _{
        '@type': "Get",
        columns: [
            _{ '@type': "Column",
               indicator: _{ '@type' : "Indicator",
                           name : "Start station" },
               variable: "Start_Station"
             },
            _{ '@type': "Column",
               indicator: _{ '@type': "Indicator",
                             name: "End station" },
               variable: "End_Station"
             },
            _{ '@type': "Column",
               indicator: _{ '@type': "Indicator",
                             name: "Start date" },
               variable: "Start_Time"
             },
            _{ '@type': "Column",
               indicator: _{ '@type': "Indicator",
                             name: "End date" },
               variable: "End_Time"
            },
            _{ '@type': "Column",
               indicator: _{ '@type': "Indicator",
                             name: "Duration" },
                variable: "Duration"
            },
            _{ '@type': "Column",
               indicator: _{ '@type': "Indicator",
                             name: "Start station number" },
               variable: "Start_ID"
             },
            _{ '@type': "Column",
               indicator: _{ '@type': "Indicator",
                             name: "End station number" },
               variable: "End_ID"
             },
            _{ '@type': "Column",
               indicator: _{ '@type': "Indicator",
                             name: "Bike number"},
               variable: "Bike"
             },
            _{ '@type': "Column",
               indicator: _{ '@type': "Indicator",
                             name: "Member type" },
               variable: "Member_Type"
             }
        ],
        resource:
        _{ '@type': "QueryResource",
           format : "csv",
           source : _{'@type': "Source",
                      url: "https://terminusdb.com/t/data/bikeshare/2011-capitalbikeshare-tripdata.csv"
                     }
         }
    },

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),

    [Res|_] = JSON.bindings,
    _{'Bike':_{'@type':'xsd:string',
               '@value':"W00247"},
      'Duration':_{'@type':'xsd:string',
                   '@value':"3548"},
      'End_ID':_{'@type':'xsd:string',
                 '@value':"31620"},
      'End_Station':_{'@type':'xsd:string',
                      '@value':"5th & F St NW"},
      'End_Time':_{'@type':'xsd:string',
                   '@value':"2011-01-01 01:00:37"},
      'Member_Type':_{'@type':'xsd:string',
                      '@value':"Member"},
      'Start_ID':_{'@type':'xsd:string',
                   '@value':"31620"},
      'Start_Station':_{'@type':'xsd:string',
                        '@value':"5th & F St NW"},
      'Start_Time':_{'@type':'xsd:string',
                     '@value':"2011-01-01 00:01:29"}} :< Res.

test(concat, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ])
:-
    Query =
    _{'@type' : 'Concatenate',
      list : _{'@type' : 'DataValue',
               list: [
                   _{'@type' : 'DataValue',
                     data : _{ '@type' : "xsd:string",
                               '@value' : "First"}},
                   _{'@type' : 'DataValue',
                     data : _{ '@type' : "xsd:string",
                               '@value' : "Second"}}
               ]
              },
      result :
      _{'@type' : 'DataValue',
        variable : "Concatenated" }},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(system_descriptor{}, Query_Out, JSON),
    [Res] = JSON.bindings,
    _{'Concatenated':_{'@type':'xsd:string',
                       '@value':"FirstSecond"}} :< Res.

test(sum, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ])
:-
    Query =
    _{'@type' : 'Sum',
      list:  _{'@type' : 'DataValue',
               list: [
                   _{'@type' : 'DataValue',
                     data : _{ '@type' : "xsd:integer",
                               '@value' : 1}},
                   _{'@type' : 'DataValue',
                     data : _{ '@type' : "xsd:integer",
                               '@value' : 2}}
               ]
              },
      result :
      _{'@type' : 'DataValue',
        variable : "Sum" }},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),
    [Res] = JSON.bindings,
    _{'Sum':_{'@type':'xsd:decimal',
              '@value': 3}} :< Res.

test(length, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ])
:-
    Query = _{'@type' : "Length",
              list : _{'@type' : 'DataValue',
                       list : [
                           _{'@type' : 'DataValue',
                             data : _{ '@type' : "xsd:integer",
                                       '@value' : 1}},
                           _{'@type' : 'DataValue',
                             data : _{ '@type' : "xsd:integer",
                                       '@value' : 2}}
                       ]},
              length : _{ '@type' : "DataValue",
                          variable : "Length"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),
    [Res] = JSON.bindings,
    _{'Length':_{'@type':'xsd:decimal',
                 '@value': 2}} :< Res.


test(length_of_var, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ])
:-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = ((v('X')=[1^^'xsd:integer',
                    2^^'xsd:integer',
                    3^^'xsd:integer']),
           length(v('X'), v('N'))),

    create_context(system_descriptor{},Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, Result),
    [First] = (Result.bindings),
    (First.'N'.'@value') = 3.


test(order_by, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    Query = _{'@type' : "OrderBy",
              ordering: [
                  _{ '@type' : "OrderTemplate",
                     order : "asc",
                     variable : "X"}
              ],
              query :
              _{ '@type' : 'Or',
                 or :
                 [_{ '@type' : "Equals",
                     left: _{'@type' : "DataValue",
                             variable : "X"},
                     right: _{'@type' : "DataValue",
                              data:_{'@type' : "xsd:integer",
                                     '@value' : 10}}},
                  _{ '@type' : "Equals",
                     left : _{'@type' : "DataValue",
                              variable : "X"},
                     right : _{'@type' : "DataValue",
                               data:_{'@type' : "xsd:integer",
                                      '@value' : 20}}}
                 ]}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),

    JSON.bindings = [_{'X':_{'@type':'xsd:integer',
                             '@value':10}},
                     _{'X':_{'@type':'xsd:integer',
                             '@value':20}}].

test(order_by_desc, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    Query = _{'@type' : "OrderBy",
              ordering : [_{ '@type' : "OrderTemplate",
                             order : "desc",
                             variable : "X"
                           }],
              query :
              _{ '@type' : 'Or',
                 or :
                 [_{ '@type' : "Equals",
                     left : _{'@type' : "DataValue",
                              variable: "X"},
                     right: _{'@type' : "DataValue",
                              data: _{'@type' : "xsd:integer",
                                      '@value' : 10}}
                   },
                  _{ '@type' : "Equals",
                     left : _{'@type' : "DataValue",
                              variable : "X"},
                     right : _{'@type' : "DataValue",
                               data:_{'@type' : "xsd:integer",
                                      '@value' : 20}}}
                 ]}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(system_descriptor{}, Query_Out, JSON),
    JSON.bindings = [_{'X':_{'@type':'xsd:integer',
                             '@value':20}},
                     _{'X':_{'@type':'xsd:integer',
                             '@value':10}}].

test(path_star, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    make_branch_descriptor('admin', 'test', Descriptor),
    Commit_Info = commit_info{ author : "me",
                               message : "Graph creation"},

    create_context(Descriptor,
                   Commit_Info,
                   Context),

    with_transaction(
        Context,
        ask(Context,
            (
                insert(node, rdf:type, owl:'Class', schema),
                insert(p, rdf:type, owl:'ObjectProperty', schema),
                insert(p, rdfs:domain, node, schema),
                insert(p, rdfs:range, node, schema),
                insert(a, rdf:type, node),
                insert(b, rdf:type, node),
                insert(c, rdf:type, node),
                insert(a, p, b),
                insert(b, p, c),
                insert(c, p, a)
            )),
        _Meta),

    findall((a-Y=Simple_Path),
            (   ask(Descriptor,
                    path(a, star(p(p)), Y, Path)),
                maplist([Edge,(A,B,C)]>>(
                            get_dict('http://terminusdb.com/schema/woql#subject',Edge, A),
                            get_dict('http://terminusdb.com/schema/woql#predicate',Edge, B),
                            get_dict('http://terminusdb.com/schema/woql#object',Edge, C)
                        ), Path, Simple_Path)
            ),
            Solutions),

    Solutions = [a-A=[],
                 a-B=[(A,P,B)],
                 a-C=[(A,P,B),(B,P,C)],
                 a-A=[(A,P,B),(B,P,C),(C,P,A)]].

test(path_num, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    make_branch_descriptor('admin', 'test', Descriptor),
    Commit_Info = commit_info{ author : "me",
                               message : "Graph creation"},

    create_context(Descriptor,
                   Commit_Info,
                   Context),

    with_transaction(
        Context,
        ask(Context,
            (
                insert(node, rdf:type, owl:'Class', schema),
                insert(p, rdf:type, owl:'ObjectProperty', schema),
                insert(p, rdfs:domain, node, schema),
                insert(p, rdfs:range, node, schema),
                insert(a, rdf:type, node),
                insert(b, rdf:type, node),
                insert(c, rdf:type, node),
                insert(a, p, b),
                insert(b, p, c),
                insert(c, p, a)
            )),
        _Meta),

    findall((a-Y=Simple_Path),
            (   ask(Descriptor,
                    path(a, times(p(p),1,1), Y, Path)),
                maplist([Edge,(A,B,C)]>>(
                            get_dict('http://terminusdb.com/schema/woql#subject',Edge, A),
                            get_dict('http://terminusdb.com/schema/woql#predicate',Edge, B),
                            get_dict('http://terminusdb.com/schema/woql#object',Edge, C)
                        ), Path, Simple_Path)
            ),
            Solutions),

    Solutions = [a-B=[(_,_,B)]].

test(complex_path, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    make_branch_descriptor('admin', 'test', Descriptor),
    Commit_Info = commit_info{ author : "me",
                               message : "Graph creation"},

    create_context(Descriptor,
                   Commit_Info,
                   Context),

    with_transaction(
        Context,
        ask(Context,
            (
                insert(node, rdf:type, owl:'Class', schema),
                insert(p, rdf:type, owl:'ObjectProperty', schema),
                insert(p, rdfs:domain, node, schema),
                insert(p, rdfs:range, node, schema),
                insert(q, rdf:type, owl:'ObjectProperty', schema),
                insert(q, rdfs:domain, node, schema),
                insert(q, rdfs:range, node, schema),
                insert(a, rdf:type, node),
                insert(b, rdf:type, node),
                insert(c, rdf:type, node),
                insert(d, rdf:type, node),
                insert(e, rdf:type, node),
                insert(f, rdf:type, node),
                insert(a, p, b),
                insert(b, p, c),
                insert(c, p, a),
                insert(a, p, d),
                insert(d, p, e),
                insert(e, p, a),
                insert(a, q, f)
            )),
        _Meta),

    findall((a-Y=Simple_Path),
            (   ask(Descriptor,
                    path(a, (star(p(p));plus(p(q))), Y, Path)),
                maplist([Edge,(A,B,C)]>>(
                            get_dict('http://terminusdb.com/schema/woql#subject',Edge, A),
                            get_dict('http://terminusdb.com/schema/woql#predicate',Edge, B),
                            get_dict('http://terminusdb.com/schema/woql#object',Edge, C)
                        ), Path, Simple_Path)
            ),
            Solutions),

    Solutions = [a-A=[],
                 a-B=[(A,P,B)],
                 a-D=[(A,P,D)],
                 a-C=[(A,P,B),(B,P,C)],
                 a-A=[(A,P,B),(B,P,C),(C,P,A)],
                 a-E=[(A,P,D),(D,P,E)],
                 a-A=[(A,P,D),(D,P,E),(E,P,A)],
                 a-F=[(A,_Q,F)]].

test(group_by, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ])
:-
    make_branch_descriptor('admin', 'test', Descriptor),
    create_context(Descriptor, commit_info{ author : "test",
                                            message : "testing"}, Context),

    with_transaction(
        Context,
        ask(Context, (insert(x,p,z),
                      insert(x,p,w),
                      insert(x,p,q),
                      insert(y,p,z),
                      insert(y,p,w))),
        _Meta),

    Query = _{'@type' : "GroupBy",
              group_by : ["Subject"],
              template:  ["Predicate",
                          "Object"],
              query : _{ '@type' : "Triple",
                         subject: _{'@type' : "NodeValue",
                                    variable : "Subject"},
                         predicate: _{'@type' : "NodeValue",
                                      variable : "Predicate"},
                         object: _{'@type' : "Value",
                                      variable : "Object"}
                       },
              grouped : _{'@type' : "Value",
                          variable : "Grouped"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(Descriptor, Query_Out, JSON),

    [_{'Grouped': [['@schema:p',q],
                   ['@schema:p',w],
                   ['@schema:p',z]],
       'Object':"system:unknown",'Predicate':"system:unknown",'Subject':x},
     _{'Grouped': [['@schema:p',w],
                   ['@schema:p',z]],
       'Object':"system:unknown",'Predicate':"system:unknown",'Subject':y}] = JSON.bindings.

test(group_by_simple_template, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ])
:-
    make_branch_descriptor('admin', 'test', Descriptor),
    create_context(Descriptor, commit_info{ author : "test",
                                            message : "testing"}, Context),

    with_transaction(
        Context,
        ask(Context, (insert(x,p,z),
                      insert(x,p,w),
                      insert(x,p,q),
                      insert(y,p,z),
                      insert(y,p,w))),
        _Meta),

    Query = _{'@type' : "GroupBy",
              group_by : ["Subject"],
              template:  ["Predicate"],
              query : _{ '@type' : "Triple",
                         subject : _{'@type' : "NodeValue",
                                     variable : "Subject"},
                         predicate : _{'@type' : "NodeValue",
                                       variable : "Predicate"},
                         object : _{'@type' : "Value",
                                    variable : "Object"}
                       },
              grouped: _{'@type' : "Value",
                         variable : "Grouped"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(Descriptor, Query_Out, JSON),

    [_{'Grouped': ['@schema:p','@schema:p','@schema:p'],
       'Object':"system:unknown",'Predicate':"system:unknown",'Subject':x},
     _{'Grouped': ['@schema:p','@schema:p'],
       'Object':"system:unknown",'Predicate':"system:unknown",'Subject':y}] = JSON.bindings.

test(select, [setup(setup_temp_store(State)),
              cleanup(teardown_temp_store(State))
             ]) :-

    Query = _{'@type' : "Limit",
              limit : 1,
              query: _{'@type' : "Select",
                       variables : ["Subject"],
                       query : _{ '@type' : "Triple",
                                  subject: _{'@type' : "NodeValue",
                                             variable : "Subject"},
                                  predicate: _{'@type' : "NodeValue",
                                               variable : "Predicate"},
                                  object: _{'@type' : "Value",
                                            node : "@schema:User"}
                                }}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(system_descriptor{}, Query_Out, JSON),

    [_{'Subject':'User/admin'}] = JSON.bindings.


test(double_select, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    Query = _{ '@type': "Using",
               collection: "_system",
               query:
               _{ '@type': "And",
                  and:
                  [_{ '@type': "Select",
                      variables: ["X"],
                      query:
                      _{ '@type': "Triple",
                         subject:
                         _{ '@type': "NodeValue",
                            variable: "X"
                          },
                         predicate:
                         _{ '@type': "NodeValue",
                            variable: "P"
                          },
                         object:
                         _{ '@type': "Value",
                            data: _{ '@type': "xsd:string",
                                     '@value': "admin"
                                   }
                          }
                       }
                    },
                   _{ '@type': "Select",
                      variables: ["Y"],
                      query:
                         _{
                             '@type': "Triple",
                             subject:
                             _{ '@type': "NodeValue",
                                variable: "Y"
                              },
                             predicate:
                             _{ '@type': "NodeValue",
                                variable: "P"
                              },
                             object:
                             _{ '@type': "Value",
                                data: _{ '@type': "xsd:string",
                                         '@value': "admin"
                                       }
                              }
                         }
                    }
                  ]
                }
             },

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, JSON),
    forall(
        member(Elt,JSON.bindings),
        (   get_dict('X',Elt, _),
            get_dict('Y',Elt, _))
    ).

test(transaction_semantics_after, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),


    with_transaction(
        Context,
        forall(ask(Context,
                   (
                       X = 1^^xsd:integer,
                       insert(a, b, X),
                       X = 2^^xsd:integer
                   )),
               true),
        _Meta_Data
    ),

    \+ once(ask(Descriptor,
                t(a, b, 1^^xsd:integer))).


test(transaction_semantics_disjunct, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),

    with_transaction(
        Context,
        forall(ask(Context,
                   (
                       (   X = 1^^xsd:integer
                       ;   X = 2^^xsd:integer),
                       insert(a, b, X),
                       X = 2^^xsd:integer
                   )),
               true),
        _Meta_Data
    ),

    once(ask(Descriptor,
             (   not(t(a, b, 1^^xsd:integer)),
                 t(a, b, 2^^xsd:integer)))).


test(transaction_semantics_conditional, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),

    with_transaction(
        Context,
        forall(ask(Context,
                   (
                       (   X = 1^^xsd:integer
                       ;   X = 2^^xsd:integer),
                       insert(a, b, X),
                       (   X = 1^^xsd:integer
                       ;   X = 2^^xsd:integer)
                   )),
               true),
        _Meta_Data
    ),

    once(ask(Descriptor,
             (   t(a, b, 1^^xsd:integer),
                 t(a, b, 2^^xsd:integer)))).


test(disjunction_equality, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),

    with_transaction(
        Context,
        ask(Context,
            (
                insert(a, public, c),
                insert(a, private, f)
            )),
        _Meta_Data
    ),

    findall(
        Elt-Status,
        ask(Descriptor,
            (
                (   t(a, private, Elt),
                    Status = private
                ;   t(a, public, Elt),
                    Status = public)
            )),
        Statuses),

    Statuses = [f-'http://somewhere.for.now/document/private',
                c-'http://somewhere.for.now/document/public'].

test(metadata_branch, [
         setup((setup_temp_store(State),
                State = _-Path,
                metadata:set_current_db_path(Path),
                create_db_without_schema("admin", "test"))),
         cleanup((metadata:unset_current_db_path,
                  teardown_temp_store(State)))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, b, c),
                      insert(d, e, f),
                      insert(d, e, a),
                      insert(f, g, h),
                      insert(h, j, k))),
        _Meta_Data
    ),

    ask(Descriptor,
        (   size('admin/test',Size_Lit),
            triple_count('admin/test', Count_Lit)
        )),
    Size_Lit = Size^^xsd:decimal,
    Count_Lit = 13^^xsd:decimal,
    Size < 2000,
    Size > 0.

test(metadata_graph, [
         setup((setup_temp_store(State),
                State = _-Path,
                metadata:set_current_db_path(Path),
                create_db_without_schema("admin", "test"))),
         cleanup((metadata:unset_current_db_path,
                  teardown_temp_store(State)))
     ]
    ) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, b, c),
                      insert(d, e, f),
                      insert(d, e, a),
                      insert(f, g, h),
                      insert(h, j, k))),
        _Meta_Data
    ),

    ask(Descriptor,
        (   size('admin/test/local/branch/main/instance',Size_Lit),
            triple_count('admin/test/local/branch/main/instance', Count_Lit)
        )),

    Size_Lit = Size^^xsd:decimal,
    Count_Lit = 5^^xsd:decimal,
    Size < 1000,
    Size > 0.

test(metadata_triple_count_json, [
         setup((setup_temp_store(State),
                State = _-Path,
                metadata:set_current_db_path(Path),
                create_db_without_schema("admin", "test"))),
         cleanup((metadata:unset_current_db_path,
                  teardown_temp_store(State)))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, b, c),
                      insert(d, e, f),
                      insert(d, e, a),
                      insert(f, g, h),
                      insert(h, j, k))),
        _Meta_Data
    ),

    Query = _{'@type' : "TripleCount",
              resource : "admin/test",
              count : _{'@type' : "DataValue",
                        variable : "Count"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(Descriptor, Query_Out, JSON),
    [Binding] = (JSON.bindings),

    (Binding.'Count'.'@value' = 13).


test(metadata_size_count_json, [
         setup((setup_temp_store(State),
                State = _-Path,
                metadata:set_current_db_path(Path),
                create_db_without_schema("admin", "test"))),
         cleanup((metadata:unset_current_db_path,
                  teardown_temp_store(State)))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, b, c),
                      insert(d, e, f),
                      insert(d, e, a),
                      insert(f, g, h),
                      insert(h, j, k))),
        _Meta_Data
    ),

    Query = _{'@type' : "Size",
              resource: "admin/test",
              size: _{'@type' : "DataValue",
                      variable : "Size"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(Descriptor, Query_Out, JSON),
    [Binding] = (JSON.bindings),

    (Binding.'Size'.'@value' = Val),
    Val > 0,
    Val < 2000.

test(metadata_size_commits_json, [
         setup((setup_temp_store(State),
                State = _-Path,
                metadata:set_current_db_path(Path),
                create_db_without_schema("admin", "test"))),
         cleanup((metadata:unset_current_db_path,
                  teardown_temp_store(State)))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, b, c),
                      insert(d, e, f),
                      insert(d, e, a),
                      insert(f, g, h),
                      insert(h, j, k))),
        _Meta_Data
    ),

    Query = _{'@type' : "Size",
              resource: "admin/test/local/_commits",
              size : _{'@type' : "DataValue",
                       variable : "Size"}},

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(Descriptor, Query_Out, JSON),
    [Binding] = (JSON.bindings),
    (Binding.'Size'.'@value' = Val),
    Val > 0,
    Val < 15000.

test(ast_disjunction_test, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(account1, account_owner, user1),
                      insert(account1, public_databases, my_database1),
                      insert(account1, private_databases, my_database2))),
        _Meta_Data
    ),

    findall(AID-UID-DBID-Public_Or_Private,
            ask(Descriptor,
                (   (t(AID, account_owner, UID),
                     (   (   t(AID, public_databases, DBID),
                             Public_Or_Private = "public"^^xsd:string)
                     ;   (   t(AID, private_databases, DBID),
                             Public_Or_Private = "private"^^xsd:string)
                     )))),
            Results),

    Results = [account1-user1-my_database1-("public"^^xsd:string),
               account1-user1-my_database2-("private"^^xsd:string)].


test(json_disjunction_test, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(account1, account_owner, user1),
                      insert(account1, public_databases, my_database1),
                      insert(account1, private_databases, my_database2))),
        _Meta_Data
    ),

    Query = _{'@type' : "And",
              and:
              [_{'@type' : "Triple",
                 subject : _{'@type' : "NodeValue",
                             variable : "AID"},
                 predicate : _{'@type' : "NodeValue",
                               'node' : "@schema:account_owner"},
                 object : _{'@type' : "Value",
                            variable : "UID"}},
               _{'@type' : "Or",
                 or:
                   [_{'@type' : "And",
                      and:
                      [_{'@type' : "Triple",
                         subject: _{'@type' : "NodeValue",
                                    variable : "AID"},
                         predicate: _{'@type' : "NodeValue",
                                      node : "@schema:public_databases"},
                         object: _{'@type' : "Value",
                                   variable : "DBID"}},
                       _{'@type' : "Equals",
                         left: _{'@type' : "DataValue",
                                 variable: "Public_Or_Private"},
                         right: _{'@type' : "DataValue",
                                  data : _{'@type' : "xsd:string",
                                           '@value' : "public"}}
                        }
                      ]},
                    _{'@type' : "And",
                      and :
                      [_{'@type' : "Triple",
                         subject : _{'@type' : "NodeValue",
                                     variable: "AID"},
                         predicate : _{'@type' : "NodeValue",
                                       node: "@schema:private_databases"},
                         object : _{'@type' : "Value",
                                    variable : "DBID"}},
                       _{'@type' : "Equals",
                         left : _{'@type' : "DataValue",
                                  variable : "Public_Or_Private"},
                         right : _{'@type' : "DataValue",
                                   data : _{'@type' : "xsd:string",
                                            '@value' : "private"}}}
                      ]
                     }
                   ]
                }
              ]
             },

    save_and_retrieve_woql(Query, Query_Out),

    json_woql(Query, AST),

    AST = (
        t(v('AID'),'@schema':account_owner,v('UID')),
        (   t(v('AID'),'@schema':public_databases,v('DBID')),
            v('Public_Or_Private')="public"^^'http://www.w3.org/2001/XMLSchema#string'
        ;   t(v('AID'),'@schema':private_databases,v('DBID')),
            v('Public_Or_Private')="private"^^'http://www.w3.org/2001/XMLSchema#string')
    ),

    query_test_response(Descriptor, Query_Out, Response),

    Bindings = (Response.bindings),
    Bindings = [_{'AID':account1,
                  'DBID':my_database1,
                  'Public_Or_Private':
                  _{'@type':_,
                    '@value':"public"},
                  'UID':user1},
                _{'AID':account1,
                  'DBID':my_database2,
                  'Public_Or_Private':
                  _{'@type':_,
                    '@value':"private"},
                  'UID':user1}].


test(ast_when_test, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, b, c),
                      insert(a, b, d),
                      insert(a, b, e))),
        _Meta_Data1
    ),

    create_context(Descriptor, Commit_Info, Context2),

    AST = when(t(a,b,v('X')),
               insert(e, f, v('X'))),
    query_response:run_context_ast_jsonld_response(Context2, AST, _JSON),

    findall(t(X,P,Y),
            ask(Descriptor, t(X, P, Y)),
            Triples),

    Triples = [t(a,b,c),t(a,b,d),t(a,b,e),t(e,f,c),t(e,f,d),t(e,f,e)].

test(ast_when_update, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, p, c),
                      insert(a, q, c),
                      insert(a, r, e))),
        _Meta_Data1
    ),

    create_context(Descriptor, Commit_Info, Context2),

    AST = ((   v('P') = '@schema':p
           ;   v('P') = '@schema':q),
           when(t(a,v('P'),v('X')),
                (   delete(a, v('P'), v('X')),
                    insert(a, v('P'), g)))),

    query_response:run_context_ast_jsonld_response(Context2, AST, _JSON),

    findall(t(X,P,Y),
            ask(Descriptor, t(X, P, Y)),
            Triples),

    Triples = [t(a,p,g),t(a,q,g),t(a,r,e)].


test(get_put, [
         setup((setup_temp_store(State),
                tmp_file('test.csv', TestFile),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State)),
         fixme('Depends on external URL')
     ]) :-

    Query = _{ '@type': "Put",
               columns:
               [ _{ '@type': "Column",
                    indicator: _{ '@type': "Indicator",
                                  name: "End Station"
                                },
                    variable: "End_Station"
                  }
               ],
               query: _{ '@type': "Get",
                         columns:
                         [ _{ '@type': "Column",
                              indicator: _{ '@type': "Indicator",
                                            name: "Start station" },
                              variable: "Start_Station"
                            },
                           _{ '@type': "Column",
                              indicator: _{ '@type': "Indicator",
                                            name: "End station" },
                              variable: "End_Station"
                            },
                           _{ '@type': "Column",
                              indicator: _{ '@type': "Indicator",
                                            name: "Start date" },
                              variable: "Start_Time"
                            },
                           _{ '@type': "Column",
                              indicator: _{ '@type': "Indicator",
                                            name: "End date" },
                              variable: "End_Time"
                            },
                           _{ '@type': "Column",
                              indicator: _{ '@type': "Indicator",
                                            name: "Duration"
                                          },
                              variable: "Duration"
                            },
                           _{ '@type': "Column",
                              indicator: _{ '@type': "Indicator",
                                            name: "Start station number"
                                          },
                              variable: "Start_ID"
                            },
                           _{ '@type': "Column",
                              indicator: _{ '@type': "Indicator",
                                            name: "End station number"
                                          },
                              variable: "End_ID"
                            },
                           _{ '@type': "Column",
                              indicator: _{ '@type': "Indicator",
                                            name: "Bike number"
                                          },
                              variable: "Bike"
                            },
                           _{ '@type': "Column",
                              indicator: _{ '@type': "Indicator",
                                            name: "Member type"
                                          },
                              variable: "Member_Type"
                            }
                         ],
                         resource: _{ '@type': "QueryResource",
                                      source: _{ '@type': "Source",
                                                 url: "https://terminusdb.com/t/data/bike_tutorial.csv"
                                               },
                                      format: "csv"
                                   }
                       },
               resource: _{ '@type': "QueryResource",
                            source : _{ '@type' : "Source",
                                        file: TestFile },
                            format: "csv"
                          }
             },

    save_and_retrieve_woql(Query, Query_Out),
    query_test_response_test_branch(Query_Out, _JSON),
    exists_file(TestFile).

test(idgen, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Atom = '{
  "@type": "LexicalKey",
  "base": {
    "@type": "Value",
    "node": "Journey/"
  },
  "key_list": [
      { "@type": "DataValue",
        "data": {
          "@type": "xsd:string",
          "@value": "test"
        }
      }
    ],
  "uri": {
    "@type": "Value",
    "variable": "Journey_ID"
    }
  }',
    atom_json_dict(Atom, Query, []),
    query_test_response_test_branch(Query, JSON),

    [Value] = (JSON.bindings),
    (Value.'Journey_ID') = 'Journey/test'.

test(isa_literal, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Atom = '{
  "@type": "IsA",
  "element": {
    "@type": "DataValue",
    "data": {
      "@type": "xsd:string",
      "@value": "test"
    }
  },
  "of_type": {
    "@type": "DataValue",
    "variable": "Type"
    }
  }',
    atom_json_dict(Atom, Query, []),
    query_test_response_test_branch(Query, JSON),
    [Value] = (JSON.bindings),
    (Value.'Type') = 'xsd:string'.

test(isa_node, [setup(setup_temp_store(State)),
                cleanup(teardown_temp_store(State))
               ]) :-
    Atom = '{
  "@type": "IsA",
  "element": {
    "@type": "NodeValue",
    "node": "User/admin"
  },
  "of_type": {
    "@type": "NodeValue",
    "variable": "Type"
  }
}',
    atom_json_dict(Atom, Query, []),
    resolve_absolute_string_descriptor("_system", Descriptor),
    query_test_response(Descriptor, Query, JSON),

    [Value] = (JSON.bindings),
    (Value.'Type') = '@schema:User'.

test(date_marshall, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State)),
         fixme('Need to process Using prefixes')
     ]) :-

    AST = (get([as('Start date', v('Start date'), 'http://www.w3.org/2001/XMLSchema#dateTime')],
               resource(remote("https://terminusdb.com/t/data/bike_tutorial.csv"), csv, _{}),
               true)),
    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,commit_info{ author : "automated test framework",
                                           message : "testing"}, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, Response),

    [_{'Start date':
       _{'@type':'xsd:dateTime',
         '@value':"2018-12-01T00:00:44Z"}}
     |_] = (Response.bindings),
    length(Response.bindings, 49).

test(into_absolute_descriptor, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    AST = into("admin/test/local/branch/main/instance",
               (insert('a','b','c'))),
    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,commit_info{ author : "automated test framework",
                                           message : "testing"}, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, Response),
    Response.inserts = 1.

test(one_witness, [
         setup((setup_temp_store(State),
                create_db_with_test_schema("admin", "test"))),
         cleanup(teardown_temp_store(State)),
         throws(error(schema_check_failure([_]),_))
     ]) :-
    AST = (insert(a,b,c),
           insert(d,e,f)),
    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,commit_info{ author : "automated test framework",
                                           message : "testing"}, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _Response).

test(using_insert_default_graph, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},
    AST = using("admin/test/local/branch/new",
                (insert('a','b','c'))),

    create_context(system_descriptor{},Commit_Info,System_Context),
    % Need to get a "no schema"...
    branch_create(System_Context,'User/admin',"admin/test/local/branch/new",
                  branch("admin/test"),_),

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _Response),

    resolve_absolute_string_descriptor("admin/test/local/branch/new",
                                       New_Descriptor),
    once(ask(New_Descriptor,
             t(a,b,c))).

test(count_test, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},
    AST = (insert('a','b','c'),
           insert('e','f','g')),

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _Response),

    resolve_absolute_string_descriptor("admin/test", New_Descriptor),

    New_AST = count(t(v('X'),v('Y'),v('Z')), v('Count')),
    create_context(New_Descriptor,Commit_Info,New_Context),

    query_response:run_context_ast_jsonld_response(New_Context, New_AST, New_Response),
    [Binding] = (New_Response.bindings),
    2 = (Binding.'Count'.'@value').

test(unbound_test, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State)),
         error(woql_instantiation_error([a,b,c]),_)
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = insert(v('a'),v('b'),v('c')),
    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _Response).

test(distinct, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = distinct([v('a'),v('b')],
                   (   member(v('a'), [1,2]),
                       member(v('b'), [1,2]))),

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, Response),
    Bindings = (Response.bindings),
    findall(X-Y,
            (   member(B,Bindings),
                get_dict(a,B,X),
                get_dict(b,B,Y)),
            Result),
    sort(Result, Sorted),
    sort([1-1,1-2,2-1,2-2], Expected),
    ord_seteq(Sorted,Expected).

test(immediately, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = opt((immediately(insert(a,b,c)),
               false)),

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _),

    once(ask(Descriptor,
             t(a,b,c))).

test(immediately_doesnt_go, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = opt((insert(a,b,c),
               false)),

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _),

    \+ once(ask(Descriptor,
                t(a,b,c))).

test(negative_path_pattern, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = (insert(a,b,c),
           insert(d,b,c),
           insert(d,b,e),
           insert(f,b,e)),

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _),

    once(ask(Descriptor,
             path(a, plus((p(b),n(b))), f, _Path))).

test(using_sequence, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Atom = '{
  "@type": "And",
  "and": [
    {
        "@type": "Using",
        "collection": "_system",
        "query" : {
          "@type": "Triple",
          "subject": {
            "@type": "NodeValue",
            "variable": "DA"
          },
          "predicate": {
            "@type": "NodeValue",
            "node": "resource_name"
          },
          "object": {
            "@type": "Value",
            "variable": "o"
          }
        }
    },
    {
        "@type": "Using",
        "collection": "admin/test",
        "query": {
          "@type": "Triple",
          "subject": {
            "@type": "NodeValue",
            "variable": "D"
          },
          "predicate": {
            "@type": "NodeValue",
            "node": "database_name"
          },
          "object": {
            "@type": "Value",
            "variable": "o"
          }
        }
      }
    ]
  }',

    atom_json_dict(Atom,Query,[]),
    resolve_absolute_string_descriptor("admin/test", Descriptor),
    query_test_response(Descriptor, Query, JSON),
    % Not failing is good enough
    * json_write_dict(current_output, JSON, []).

test(added_deleted_triple, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = (insert(a,b,c),
           insert(d,b,c),
           insert(d,b,e),
           insert(f,b,e)),

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _),


    AST2 = (insert(h,i,j),
            delete(a,b,c)),

    create_context(Descriptor,Commit_Info, Context2),

    query_response:run_context_ast_jsonld_response(Context2, AST2, _),

    once(ask(Descriptor,
             (   addition(h,i,j),
                 removal(a,b,c)))
        ).

test(added_deleted_quad, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = (insert(a,b,c),
           insert(d,b,c),
           insert(d,b,e),
           insert(f,b,e)),


    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _),

    AST2 = (insert(h,i,j),
            delete(a,b,c)),

    create_context(Descriptor,Commit_Info, Context2),

    query_response:run_context_ast_jsonld_response(Context2, AST2, _),

    once(ask(Descriptor,
             (   addition(h,i,j, instance),
                 removal(a,b,c, instance)))
        ).


test(guard_interspersed_insertions, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = (insert(a,b,c),
           t(a,b,c),
           insert(d,b,c)),

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _),

    \+ ask(Descriptor,
           (   t(a,b,c))).

test(guard_safe_intersperesed_insertions, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = insert(a,b,c),

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _),


    AST2 = (insert(e,f,g),
            t(a,b,c),
            insert(d,b,c)),

    create_context(Descriptor,Commit_Info, Context2),

    query_response:run_context_ast_jsonld_response(Context2, AST2, _),

    once(ask(Descriptor,
             (   t(a,b,c),
                 t(e,f,g),
                 t(d,b,c)))).

test(guard_safe_insertions, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = (insert(a,b,c)),

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _),

    create_context(Descriptor,Commit_Info, Context2),

    AST2 = (
        t(a,b,c),
        insert(e,f,g)),

    query_response:run_context_ast_jsonld_response(Context2, AST2, _),

    once(ask(Descriptor,
             (   t(a,b,c),
                 t(e,f,g)))).

test(guard_disjunctive_insertions, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = insert(a,b,c),

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _),

    create_context(Descriptor,Commit_Info, Context2),

    AST2 = (   t(a,b,c),
               insert(e,f,g)
           ;   not(t(a,b,c)),
               insert(x,y,z)),

    query_response:run_context_ast_jsonld_response(Context2, AST2, _),

    once(ask(Descriptor,
             t(e,f,g))),

    \+ once(ask(Descriptor,
             t(x,y,z))).

test(guard_deep_insertions, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = insert(a,b,c),

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _),

    create_context(Descriptor,Commit_Info, Context2),

    AST2 = (   t(a,b,c),
               (   insert(e,f,g),
                   (   insert(x,y,z)),
                   insert(h,i,j)
               ),
               insert(l,m,n)),

    query_response:run_context_ast_jsonld_response(Context2, AST2, _),

    once(ask(Descriptor,
             (   t(e,f,g),
                 t(x,y,z),
                 t(h,i,j),
                 t(l,m,n),
                 t(e,f,g)))).

test(using_multiple_prefixes, [
         setup((setup_temp_store(State),
                create_db_with_test_schema("admin", "schema_db"),
                create_db_without_schema("admin", "schemaless_db"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = using("admin/schema_db",
                (insert('Dublin', rdf:type, '@schema':'City'),
                 insert('Dublin', name, "Dublin"^^xsd:string))),

    resolve_absolute_string_descriptor("admin/schemaless_db", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _).

test(bad_class_vio, [
         setup((setup_temp_store(State),
                create_db_with_test_schema("admin", "schema_db"))),
         cleanup(teardown_temp_store(State)),
         error(schema_check_failure(
                   [
                       json{'@type':invalid_predicate,
                            class:_Class,
                           predicate:_Name,
                           subject:_Dublin}
                   ]), _)
     ]) :-

    Commit_Info = commit_info{ author : "automated test framework",
                               message : "testing"},

    AST = (insert('Dublin', rdf:type, '@schema':'City_State'),
           insert('Dublin', name, "Dublin"^^xsd:string)),

    resolve_absolute_string_descriptor("admin/schema_db", Descriptor),
    create_context(Descriptor,Commit_Info, Context),

    query_response:run_context_ast_jsonld_response(Context, AST, _Result).


test(typeof, [
         setup(setup_temp_store(State)),
         cleanup(teardown_temp_store(State))
     ]) :-

    Query = _{'@type' : "And",
              and :
              [_{'@type' : "Equals",
                 left: _{'@type' : "DataValue",
                         data: _{'@type' : "xsd:string",
                                 '@value' : "test"}},
                 right: _{'@type' : "DataValue",
                          variable : "X"}},
               _{'@type' : "TypeOf",
                 type: _{'@type' : "Value",
                         variable : "Type"},
                 value: _{'@type' : "Value",
                          variable : "X"}}]},

    query_test_response(system_descriptor{}, Query, JSON),
    [Result] = (JSON.bindings),
    Result.'Type' = 'xsd:string'.


test(once, [
         setup(setup_temp_store(State)),
         cleanup(teardown_temp_store(State))
     ]) :-

    Query = _{'@type' : "Once",
              'query': _{'@type' : "Or",
                         or:
                         [_{'@type' : "Equals",
                            left: _{'@type' : "DataValue",
                                    data:_{'@type' : "xsd:string",
                                           '@value' : "foo"}},
                            right: _{'@type' : "DataValue",
                                     variable : "X"}},
                         _{'@type' : "Equals",
                           left: _{'@type' : "DataValue",
                                   data:_{'@type' : "xsd:string",
                                          '@value' : "bar"}},
                           right: _{'@type' : "DataValue",
                                    variable : "X"}}]
                        }
             },
    query_test_response(system_descriptor{}, Query, JSON),
    [Result] = (JSON.bindings),
    Result.'X'.'@value' = "foo".

test(literal_datetime, [
         setup((setup_temp_store(State),
                create_db_with_test_schema("admin", "schema_db"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    Query = _{ '@type': "Equals",
               left: _{ '@type': "DataValue",
                        variable: "X" },
               right: _{ '@type': "DataValue",
                         data: _{ '@value': "2021-02-23T21:12:58Z",
                                  '@type': "xsd:dateTime" } }
             },

    query_test_response(system_descriptor{}, Query, _JSON),
    !.

test(language_en_variable, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "db"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    Query = _{ '@type': "Triple",
               'subject':
               _{ '@type': "NodeValue",
                  variable: "s"
                },
               'predicate':
               _{ '@type': "NodeValue",
                  'node': "title"
                },
               'object':
               _{ '@type': "Value",
                  variable: "title"
                }
             },
    resolve_absolute_string_descriptor("admin/db", Descriptor),

    create_context(Descriptor, commit_info{author:"test", message:"test"}, Context),
    with_transaction(
        Context,
        ask(Context,
            (   insert(a, title, c),
                insert(d, title, f))),
        _),

    query_test_response(Descriptor, Query, JSON),
    !,
    forall(member(Elt,(JSON.bindings)),
           member(Elt, [_{s:a,title:c},_{s:d,title:f}])).

test(language_en_variable, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "db"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    Query = _{ '@type': "Triple",
               'subject':
               _{ '@type': "NodeValue",
                  variable: "s"
                },
               'predicate':
               _{ '@type': "NodeValue",
                  'node': "title"
                },
               'object':
               _{ '@type': "Value",
                  variable: "title"
                }
             },
    resolve_absolute_string_descriptor("admin/db", Descriptor),

    create_context(Descriptor, commit_info{author:"test", message:"test"}, Context),
    with_transaction(
        Context,
        ask(Context,
            (   insert(a, title, "asdf"@en),
                insert(d, title, "fdsa"@fr))),
        _),

    query_test_response(Descriptor, Query, JSON),
    !,
    Bindings = (JSON.bindings),

    forall(member(Elt, Bindings),
           member(Elt, [_{s:a,title: _{'@language' : en, '@value' : "asdf"}},_{s:d,title: _{'@language' : fr, '@value' : "fdsa"}}])).


test(and_type, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "db"))),
         cleanup(teardown_temp_store(State))
     ]) :-
    And_Type = '{ "@type": "And",
  "and": [
   {"@type": "Triple",
    "subject": {
      "@type": "NodeValue",
      "variable": "X"},
    "predicate": {
          "@type": "NodeValue",
          "variable": "P"
        },
    "object": {
          "@type": "Value",
          "variable": "Z"
        }
      },
    { "@type": "TypeOf",
      "value": {
          "@type": "DataValue",
          "variable": "Z"
        },
      "type": {
          "@type": "DataValue",
          "data" : { "@type": "xsd:string",
                    "@value": "en" }
        }
    }]}',
    atom_json_dict(And_Type, Query, []),

    resolve_absolute_string_descriptor("admin/db", Descriptor),

    create_context(Descriptor, commit_info{author:"test", message:"test"}, Context),
    with_transaction(
        Context,
        ask(Context,
            (   insert(a, title, "asdf"@en),
                insert(d, title, "fdsa"@fr))),
        _),

    query_test_response(Descriptor, Query, JSON),
    [Binding] = (JSON.bindings),
    "asdf" = (Binding.'Z'.'@value').



test(gyear_cast, [
         setup(setup_temp_store(State)),
         cleanup(teardown_temp_store(State))
     ]) :-
    Typecast = '{
  "@type": "Typecast",
  "value": {
    "@type": "Value",
    "data": {
      "@type": "xsd:string",
      "@value": "1999"
    }
  },
  "type": {
    "@type": "NodeValue",
    "node": "xsd:gYear"
  },
  "result": {
    "@type": "Value",
    "variable": "V"
  }
}',

    atom_json_dict(Typecast, Query, []),
    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(system_descriptor{}, Query_Out, JSON),
    [Binding] = (JSON.bindings),
    Binding = _{'V':_{'@type':'xsd:gYear',
                      '@value':"1999"}}.

test(schema_prefix, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State)),
         fixme('Need to process Using prefixes')
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{ author : "test", message : "testing semantics"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, (insert(a, rdf:type, '@schema':test))),
        _Meta_Data
    ),

    Atom = '{
  "@type": "Using",
  "collection": "_commits",
  "query": {
    "@type": "Triple",
    "subject": {
      "@type": "NodeValue",
      "variable": "a"
    },
    "predicate": {
      "@type": "NodeValue",
      "node": "rdf:type"
    },
    "object": {
      "@type": "Value",
      "node": "ref:Branch"
    }
  }
}',

    atom_json_dict(Atom, Query, []),
    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(Descriptor, Query_Out, JSON),
    JSON = false.


test(commit_graph, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor, commit_info{ author : "test", message: "message1"}, Context),

    with_transaction(
        Context,
        ask(Context, (insert(a, rdf:type, '@schema':test))),
        _
    ),

    create_context(Descriptor, commit_info{ author : "test", message: "message2"}, Context2),
    with_transaction(
        Context2,
        ask(Context2, (insert(b, rdf:type, '@schema':test))),
        _
    ),

    AST = using('_commits',
                limit(499^^xsd:decimal,
                      (   t(v(branch),name,"main"^^xsd:string),
                          t(v(branch),head,v(commit)),
                          path(v(commit),star(p(parent)),v(target_commit)),
                          t(v(target_commit),identifier,v(cid)),
                          t(v(target_commit),author,v(author)),
                          t(v(target_commit),message,v(message)),
                          t(v(target_commit),timestamp,v(timestamp))))),

    create_context(Descriptor, commit_info{ author : "test", message: "message3"}, Context3),
    query_response:run_context_ast_jsonld_response(Context3, AST, Response),
    [Commit1,Commit2] = (Response.bindings),
    (Commit1.message.'@value') = "message2",
    (Commit2.message.'@value') = "message1".


test(commit_graph_json, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor, commit_info{ author : "test", message: "message1"}, Context),

    with_transaction(
        Context,
        ask(Context, (insert(a, rdf:type, '@schema':test))),
        _
    ),

    create_context(Descriptor, commit_info{ author : "test", message: "message2"}, Context2),
    with_transaction(
        Context2,
        ask(Context2, (insert(b, rdf:type, '@schema':test))),
        _
    ),

    Commit_Query = '{"@type": "Using", "collection": "_commits", "query": {"@type": "Limit", "limit": 499, "query": {"@type": "And", "and": [{"@type": "Triple", "subject": {"@type": "NodeValue", "variable": "branch"}, "predicate": {"@type": "NodeValue", "node": "name"}, "object": {"@type": "Value", "data": {"@type": "xsd:string", "@value": "main"}}}, {"@type": "And", "and": [{"@type": "Triple", "subject": {"@type": "NodeValue", "variable": "branch"}, "predicate": {"@type": "NodeValue", "node": "head"}, "object": {"@type": "Value", "variable": "commit"}}, {"@type": "And", "and": [{"@type": "Path", "subject": {"@type": "NodeValue", "variable": "commit"}, "pattern": {"@type": "PathStar", "star": {"@type": "PathPredicate", "predicate": "parent"}}, "object": {"@type": "Value", "variable": "target_commit"}}, {"@type": "And", "and": [{"@type": "Triple", "subject": {"@type": "NodeValue", "variable": "target_commit"}, "predicate": {"@type": "NodeValue", "node": "identifier"}, "object": {"@type": "Value", "variable": "cid"}}, {"@type": "And", "and": [{"@type": "Triple", "subject": {"@type": "NodeValue", "variable": "target_commit"}, "predicate": {"@type": "NodeValue", "node": "author"}, "object": {"@type": "Value", "variable": "author"}}, {"@type": "And", "and": [{"@type": "Triple", "subject": {"@type": "NodeValue", "variable": "target_commit"}, "predicate": {"@type": "NodeValue", "node": "message"}, "object": {"@type": "Value", "variable": "message"}}, {"@type": "Triple", "subject": {"@type": "NodeValue", "variable": "target_commit"}, "predicate": {"@type": "NodeValue", "node": "timestamp"}, "object": {"@type": "Value", "variable": "timestamp"}}]}]}]}]}]}]}}}',

    atom_json_dict(Commit_Query, Query, []),
    query_test_response(Descriptor, Query, JSON),
    [_Commit1,_Commit2] = (JSON.bindings).

test(target_commit, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor, commit_info{ author : "test", message: "message1"}, Context),

    with_transaction(
        Context,
        ask(Context, (insert(a, rdf:type, '@schema':test))),
        _
    ),

    create_context(Descriptor, commit_info{ author : "test", message: "message2"}, Context2),
    with_transaction(
        Context2,
        ask(Context2, (insert(b, rdf:type, '@schema':test))),
        _
    ),

    Commit_Query =
    '{"@type": "Using",
      "collection": "_commits",
      "query": {"@type": "And",
                "and": [{"@type": "Path",
                         "subject": {"@type": "NodeValue", "variable": "commit"},
                         "pattern": {"@type": "PathTimes",
                                     "from": 1,
                                     "to": 1,
                                     "times": {"@type": "PathPredicate",
                                               "predicate": "parent"}},
                     "object": {"@type": "Value", "variable": "target_commit"}},
                    {"@type": "And",
                     "and": [{"@type": "Triple",
                              "subject": {"@type": "NodeValue", "variable": "branch"},
                              "predicate": {"@type": "NodeValue", "node": "name"},
                              "object": {"@type": "Value", "data": {"@type": "xsd:string", "@value": "main"}}},
                             {"@type": "And",
                              "and": [{"@type": "Triple",
                                       "subject": {"@type": "NodeValue", "variable": "branch"},
                                       "predicate": {"@type": "NodeValue", "node": "head"},
                                       "object": {"@type": "Value", "variable": "commit"}},
                                      {"@type": "Triple",
                                       "subject": {"@type": "NodeValue", "variable": "target_commit"},
                                       "predicate": {"@type": "NodeValue", "node": "identifier"},
                                       "object": {"@type": "Value", "variable": "cid"}}]}]}]}}',

    atom_json_dict(Commit_Query, Query, []),
    query_test_response(Descriptor, Query, JSON),
    [_Commit] = (JSON.bindings).


test(jobs_group_by, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    create_context(Descriptor, commit_info{ author : "test", message: "message"}, Context),
    with_transaction(
        Context,
        ask(Context, (
                insert(a, 'Id', 'foo'^^xsd:string),
                insert(a, 'JobInfo', ji),
                insert(b, 'Id', 'bar'^^xsd:string),
                insert(b, 'JobInfo', ji),
                insert(ji, 'JobInterest', 'Something'^^xsd:string),
                insert(c, 'Id', 'baz'^^xsd:string),
                insert(c, 'JobInfo', jj),
                insert(d, 'Id', 'quux'^^xsd:string),
                insert(d, 'JobInfo', jj),
                insert(jj, 'JobInterest', 'SomethingElse'^^xsd:string)

            )),
        _
    ),

    AST = limit(10^^xsd:decimal,
                select([v('JobInterest'),v('TheCount'),v('JobRoleInterestGroup')],
                       (group_by(v('JobInterest'),
                                 v('Id'),
                                 (t(v('Coder'),'Id',v('Id')),
                                  t(v('Coder'),'JobInfo',v('JobInfo')),
                                  t(v('JobInfo'),'JobInterest',v('JobInterest'))),
                                 v('JobRoleInterestGroup')),
                        length(v('JobRoleInterestGroup'),v('TheCount'))))),
    create_context(Descriptor, commit_info{ author : "test", message: "message2"},
                   Context2),
    query_response:run_context_ast_jsonld_response(Context2, AST, Response),
    [_{'JobInterest':json{'@type':'xsd:string','@value':"Something"},
       'JobRoleInterestGroup':[json{'@type':'xsd:string','@value':"foo"},
                               json{'@type':'xsd:string','@value':"bar"}],
       'TheCount':json{'@type':'xsd:decimal','@value':2}},
     _{'JobInterest':json{'@type':'xsd:string','@value':"SomethingElse"},
       'JobRoleInterestGroup':[json{'@type':'xsd:string','@value':"baz"},
                               json{'@type':'xsd:string','@value':"quux"}],
       'TheCount':json{'@type':'xsd:decimal','@value':2}}] = (Response.bindings).

test(triple_graph, [
         setup((setup_temp_store(State),
                create_db_with_test_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    Query = _{'@type': "Triple",
              'subject': _{'@type': "NodeValue", 'variable': "A"},
              'predicate': _{'@type': "NodeValue", 'variable': "B"},
              'object': _{'@type': "Value", 'variable': "C"},
              'graph': "schema"},
    resolve_absolute_string_descriptor("admin/test", Descriptor),
    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(Descriptor, Query_Out, JSON),
    _{ 'api:status': 'api:success' } :< JSON.

test(delete_triple1, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{author: "a", message: "m"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, insert(a, b, c)),
        _Meta_Data
    ),

    Query = _{'@type' : "DeleteTriple",
              'subject' : _{'@type' : "NodeValue", 'node' : "a"},
              'predicate' : _{'@type' : "NodeValue", 'node' : "b"},
              'object' : _{'@type' : "Value", 'node' : "c"}},
    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(Descriptor, Query_Out, JSON),
    JSON.deletes = 1.

test(delete_triple2, [
         setup((setup_temp_store(State),
                create_db_without_schema("admin", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    resolve_absolute_string_descriptor("admin/test", Descriptor),
    Commit_Info = commit_info{author: "a", message: "m"},
    create_context(Descriptor, Commit_Info, Context),
    with_transaction(
        Context,
        ask(Context, insert(a, b, c, instance)),
        _Meta_Data
    ),

    Query = _{'@type' : "DeleteTriple",
              'subject' : _{'@type' : "NodeValue", 'node' : "a"},
              'predicate' : _{'@type' : "NodeValue", 'node' : "b"},
              'object' : _{'@type' : "Value", 'node' : "c"},
              'graph' : "instance"},
    save_and_retrieve_woql(Query, Query_Out),
    query_test_response(Descriptor, Query_Out, JSON),
    JSON.deletes = 1.

test(less_than, [
         setup((setup_temp_store(State),
                add_user("TERMINUSQA",some('password'),Auth),
                create_db_without_schema("TERMINUSQA", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    Query = _{ '@type' : "Less",
               left : _{'@type' : "DataValue", 'data' : 0},
               right : _{'@type' : "DataValue", 'data' : 1}
             },

    Commit_Info = commit_info{author: "TERMINUSQA", message: "less than"},

    woql_query_json(system_descriptor{},
                    Auth,
                    some("TERMINUSQA/test"),
                    Query,
                    Commit_Info,
                    [],
                    false,
                    JSON),
    [_] = (JSON.bindings).


test(using_resource_works, [
         setup((setup_temp_store(State),
                add_user("TERMINUSQA",some('password'),Auth),
                create_db_without_schema("TERMINUSQA", "test"))),
         cleanup(teardown_temp_store(State))
     ]) :-

    Query_Atom = '{ "@type": "Using", "collection": "_commits",
    "query": { "@type": "Limit", "limit": 10, "query": { "@type":
    "Select", "variables": [ "Parent ID", "Commit ID", "Time",
    "Author", "Branch ID", "Message" ], "query": { "@type": "And",
    "and": [ { "@type": "Triple", "subject": { "@type": "NodeValue",
    "variable": "Branch" }, "predicate": { "@type": "NodeValue",
    "node": "name" }, "object": { "@type": "Value", "data": { "@type":
    "xsd:string", "@value": "main" } } }, { "@type": "Triple",
    "subject": { "@type": "NodeValue", "variable": "Branch" },
    "predicate": { "@type": "NodeValue", "node": "head" }, "object": {
    "@type": "Value", "variable": "Active Commit ID" } }, { "@type":
    "Path", "subject": { "@type": "NodeValue", "variable": "Active
    Commit ID" }, "pattern": { "@type": "PathStar", "star": { "@type":
    "PathPredicate", "predicate": "parent" } }, "object": { "@type":
    "Value", "variable": "Parent" }, "path": { "@type": "Value",
    "variable": "Path" } }, { "@type": "Triple", "subject": { "@type":
    "NodeValue", "variable": "Parent" }, "predicate": { "@type":
    "NodeValue", "node": "timestamp" }, "object": { "@type": "Value",
    "variable": "Time" } }, { "@type": "Triple", "subject": { "@type":
    "NodeValue", "variable": "Parent" }, "predicate": { "@type":
    "NodeValue", "node": "identifier" }, "object": { "@type": "Value",
    "variable": "Commit ID" } }, { "@type": "Triple", "subject": {
    "@type": "NodeValue", "variable": "Parent" }, "predicate": {
    "@type": "NodeValue", "node": "author" }, "object": { "@type":
    "Value", "variable": "Author" } }, { "@type": "Triple", "subject":
    { "@type": "NodeValue", "variable": "Parent" }, "predicate": {
    "@type": "NodeValue", "node": "message" }, "object": { "@type":
    "Value", "variable": "Message" } } ] } } } }',

    atom_json_dict(Query_Atom, Query,[]),

    Commit_Info = commit_info{author: "TERMINUSQA", message: "less than"},

    woql_query_json(system_descriptor{},
                    Auth,
                    some("TERMINUSQA/test"),
                    Query,
                    Commit_Info,
                    [],
                    false,
                    _JSON).

:- end_tests(woql).

:- begin_tests(store_load_data).
:- use_module(core(util/test_utils)).
:- use_module(core(api)).
:- use_module(core(query)).
:- use_module(core(triple)).
:- use_module(core(transaction)).
:- use_module(library(terminus_store)).

store_get_lit(Data, Literal) :-
    setup_call_cleanup(
        (   setup_temp_store(State),
            create_db_without_schema(admin, test)),
        (
            resolve_absolute_string_descriptor("admin/test", Descriptor),
            create_context(Descriptor, commit_info{author:"test", message:"test"}, Context),
            with_transaction(Context,
                             ask(Context,
                                 insert(a,b, Data)),
                             _),

            open_descriptor(Descriptor, Transaction),
            [RWO] = (Transaction.instance_objects),
            Layer = (RWO.read),
            once(triple(Layer,_,_,value(Literal)))
        ),
        teardown_temp_store(State)).

load_get_lit(Literal, Data) :-
    setup_call_cleanup(
        (   setup_temp_store(State),
            create_db_without_schema(admin, test)),
        (
            resolve_absolute_string_descriptor("admin/test", Descriptor),

            create_context(Descriptor, commit_info{author:"test", message:"test"}, Context),
            [Transaction] = (Context.transaction_objects),
            [RWO] = (Transaction.instance_objects),
            read_write_obj_builder(RWO, Builder),

            with_transaction(Context,
                             nb_add_triple(Builder, "a", "b", value(Literal)),
                             _),

            once(ask(Descriptor,
                     t("a", "b", Data)))

        ),
        teardown_temp_store(State)).

test_lit(Data, Literal) :-
    store_get_lit(Data, Literal),
    load_get_lit(Literal, Data).

test(string) :-
    test_lit("a string"^^xsd:string, "\"a string\"^^'http://www.w3.org/2001/XMLSchema#string'").

test(boolean_false) :-
    test_lit(false^^xsd:boolean, "\"false\"^^'http://www.w3.org/2001/XMLSchema#boolean'").

test(boolean_true) :-
    test_lit(true^^xsd:boolean, "\"true\"^^'http://www.w3.org/2001/XMLSchema#boolean'").

test(decimal_pos) :-
    % note that the number saved is not further quoted
    test_lit(123.456^^xsd:decimal, "123.456^^'http://www.w3.org/2001/XMLSchema#decimal'").

test(decimal_neg) :-
    % note that the number saved is not further quoted
    test_lit(-123.456^^xsd:decimal, "-123.456^^'http://www.w3.org/2001/XMLSchema#decimal'").

test(integer_pos) :-
    % note that the number saved is not further quoted
    test_lit(42^^xsd:integer, "42^^'http://www.w3.org/2001/XMLSchema#integer'").

test(integer_neg) :-
    % note that the number saved is not further quoted
    test_lit(-42^^xsd:integer, "-42^^'http://www.w3.org/2001/XMLSchema#integer'").

%% NOTE: doubles and floats actually have an alternative notation (2.7E10 etc), as well as special constants(Inf, NaN..), which are not currently supported.

test(double_pos) :-
    % note that the number saved is not further quoted
    test_lit(123.456^^xsd:double, "123.456^^'http://www.w3.org/2001/XMLSchema#double'").

test(double_neg) :-
    % note that the number saved is not further quoted
    test_lit(-123.456^^xsd:double, "-123.456^^'http://www.w3.org/2001/XMLSchema#double'").

test(float_pos) :-
    % note that the number saved is not further quoted
    test_lit(123.456^^xsd:float, "123.456^^'http://www.w3.org/2001/XMLSchema#float'").

test(float_neg) :-
    % note that the number saved is not further quoted
    test_lit(-123.456^^xsd:float, "-123.456^^'http://www.w3.org/2001/XMLSchema#float'").

test(dateTime) :-
    test_lit(date_time(2020,01,02,03,04,05,0)^^xsd:dateTime, "\"2020-01-02T03:04:05Z\"^^'http://www.w3.org/2001/XMLSchema#dateTime'").

test(byte_pos) :-
    % note that the number saved is not further quoted
    test_lit(127^^xsd:byte, "127^^'http://www.w3.org/2001/XMLSchema#byte'").

test(byte_neg) :-
    % note that the number saved is not further quoted
    test_lit(-127^^xsd:byte, "-127^^'http://www.w3.org/2001/XMLSchema#byte'").

test(short_pos) :-
    % note that the number saved is not further quoted
    test_lit(65535^^xsd:short, "65535^^'http://www.w3.org/2001/XMLSchema#short'").

test(short_neg) :-
    % note that the number saved is not further quoted
    test_lit(-65535^^xsd:short, "-65535^^'http://www.w3.org/2001/XMLSchema#short'").

test(int_pos) :-
    % note that the number saved is not further quoted
    test_lit(123456^^xsd:int, "123456^^'http://www.w3.org/2001/XMLSchema#int'").

test(int_neg) :-
    % note that the number saved is not further quoted
    test_lit(-123456^^xsd:int, "-123456^^'http://www.w3.org/2001/XMLSchema#int'").

test(long_pos) :-
    % note that the number saved is not further quoted
    test_lit(123456^^xsd:long, "123456^^'http://www.w3.org/2001/XMLSchema#long'").

test(long_neg) :-
    % note that the number saved is not further quoted
    test_lit(-123456^^xsd:long, "-123456^^'http://www.w3.org/2001/XMLSchema#long'").

test(unsignedByte) :-
    % note that the number saved is not further quoted
    test_lit(255^^xsd:unsignedByte, "255^^'http://www.w3.org/2001/XMLSchema#unsignedByte'").

test(unsignedShort) :-
    % note that the number saved is not further quoted
    test_lit(65535^^xsd:unsignedShort, "65535^^'http://www.w3.org/2001/XMLSchema#unsignedShort'").

test(unsignedInt) :-
    % note that the number saved is not further quoted
    test_lit(123456^^xsd:unsignedInt, "123456^^'http://www.w3.org/2001/XMLSchema#unsignedInt'").

test(unsignedLong) :-
    % note that the number saved is not further quoted
    test_lit(123456^^xsd:unsignedLong, "123456^^'http://www.w3.org/2001/XMLSchema#unsignedLong'").

test(positiveInteger) :-
    % note that the number saved is not further quoted
    test_lit(123456^^xsd:positiveInteger, "123456^^'http://www.w3.org/2001/XMLSchema#positiveInteger'").

test(nonNegativeInteger) :-
    % note that the number saved is not further quoted
    test_lit(123456^^xsd:nonNegativeInteger, "123456^^'http://www.w3.org/2001/XMLSchema#nonNegativeInteger'").

test(negativeInteger) :-
    % note that the number saved is not further quoted
    test_lit(-123456^^xsd:negativeInteger, "-123456^^'http://www.w3.org/2001/XMLSchema#negativeInteger'").


test(nonPositiveInteger) :-
    % note that the number saved is not further quoted
    test_lit(-123456^^xsd:nonPositiveInteger, "-123456^^'http://www.w3.org/2001/XMLSchema#nonPositiveInteger'").

test(hexBinary) :-
    test_lit("abcd0123"^^xsd:hexBinary, "\"abcd0123\"^^'http://www.w3.org/2001/XMLSchema#hexBinary'").

test(base64Binary) :-
    test_lit("YXNkZg=="^^xsd:base64Binary, "\"YXNkZg==\"^^'http://www.w3.org/2001/XMLSchema#base64Binary'").

test(anyURI) :-
    test_lit("http://example.org/schema#thing"^^xsd:anyURI, "\"http://example.org/schema#thing\"^^'http://www.w3.org/2001/XMLSchema#anyURI'").

test(language) :-
    test_lit("en"^^xsd:language, "\"en\"^^'http://www.w3.org/2001/XMLSchema#language'").

test(language_tagged) :-
    test_lit("this is an english sentence"@en, "\"this is an english sentence\"@en").

test(gyear) :-
    test_lit(gyear(2100,0)^^xsd:gYear, "\"2100\"^^'http://www.w3.org/2001/XMLSchema#gYear'").

test(gYearMonth) :-
    test_lit(gyear_month(2100,3,0)^^xsd:gYearMonth, "\"2100-03\"^^'http://www.w3.org/2001/XMLSchema#gYearMonth'").

test(gMonthDay) :-
    test_lit(gmonth_day(05,24,0)^^xsd:gMonthDay, "\"-05-24\"^^'http://www.w3.org/2001/XMLSchema#gMonthDay'").

test(gMonth) :-
    test_lit(gmonth(05,0)^^xsd:gMonth, "\"--05\"^^'http://www.w3.org/2001/XMLSchema#gMonth'").

test(gDay) :-
    test_lit(gday(24,0)^^xsd:gDay, "\"---24\"^^'http://www.w3.org/2001/XMLSchema#gDay'").

test(time) :-
    test_lit(time(12,14,0)^^xsd:time, "\"12:14:00Z\"^^'http://www.w3.org/2001/XMLSchema#time'").

test(date) :-
    test_lit(date(1978,6,25,0)^^xsd:date, "\"1978-06-25\"^^'http://www.w3.org/2001/XMLSchema#date'").

test(coordinate) :-
    test_lit(point(1.3,34.3)^^xdd:coordinate, "\"[1.3,34.3]\"^^'http://terminusdb.com/schema/xdd#coordinate'").

test(coordinatePolygon) :-
    test_lit(coordinate_polygon([[1.3,34.3],[1.3,34.3]])^^xdd:coordinatePolygon, "\"[[1.3,34.3],[1.3,34.3]]\"^^'http://terminusdb.com/schema/xdd#coordinatePolygon'").

test(coordinatePolyline) :-
    test_lit(coordinate_polygon([[1.3,34.3],[1.3,34.3]])^^xdd:coordinatePolyline, "\"[[1.3,34.3],[1.3,34.3]]\"^^'http://terminusdb.com/schema/xdd#coordinatePolyline'").

test(integer_range) :-
    test_lit(integer_range(1,3)^^xdd:integerRange, "\"[1,3]\"^^'http://terminusdb.com/schema/xdd#integerRange'").

test(date_range) :-
    test_lit(date_range(date(2012,02,03,0),date(2012,02,03,0))^^xdd:dateRange, "\"[2012-02-03,2012-02-03]\"^^'http://terminusdb.com/schema/xdd#dateRange'").

test(gyear_range, []) :-
    test_lit(gyear_range(gyear(2012,0),gyear(2013,0))^^xdd:gYearRange, "\"[2012,2013]\"^^'http://terminusdb.com/schema/xdd#gYearRange'").

test(duration_year) :-
    test_lit(duration(1,10,0,0,0,0,0)^^xsd:duration, "\"P10Y\"^^'http://www.w3.org/2001/XMLSchema#duration'").

test(duration_hour) :-
    test_lit(duration(-1,0,0,0,1,0,0)^^xsd:duration, "\"-PT1H\"^^'http://www.w3.org/2001/XMLSchema#duration'").

:- end_tests(store_load_data).
