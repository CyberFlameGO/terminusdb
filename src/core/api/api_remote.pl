:- module(api_remote, [
              add_remote/5,
              remove_remote/4,
              update_remote/5,
              show_remote/5,
              list_remotes/4
          ]).

:- use_module(core(util)).
:- use_module(core(transaction)).
:- use_module(core(query)).
:- use_module(core(account)).

add_remote(SystemDB, Auth, Path, Remote_Name, Remote_Location) :-
    atomic_list_concat([Path, '/_meta'], Repo_Path),

    do_or_die(
        resolve_absolute_string_descriptor(Repo_Path, Descriptor),
        error(invalid_absolute_path(Path),_)),

    check_descriptor_auth(SystemDB, Descriptor,
                          '@schema':'Action/meta_write_access', Auth),

    do_or_die(
        create_context(Descriptor, Context),
        error(unresolvable_descriptor(Descriptor),_)),

    do_or_die(
        \+ has_repository(Context, Remote_Name),
        error(remote_exists(Remote_Name),_)),

    with_transaction(
        Context,
        insert_remote_repository(Context, Remote_Name, Remote_Location, _),
        _
    ).

remove_remote(SystemDB, Auth, Path, Remote_Name) :-
    atomic_list_concat([Path, '/_meta'], Repo_Path),

    do_or_die(
        resolve_absolute_string_descriptor(Repo_Path, Descriptor),
        error(invalid_absolute_path(Path),_)),

    check_descriptor_auth(SystemDB, Descriptor,
                          '@schema':'Action/meta_write_access', Auth),

    do_or_die(
        create_context(Descriptor, Context),
        error(unresolvable_target_descriptor(Descriptor),_)),

    do_or_die(
        has_remote_repository(Context, Remote_Name),
        error(remote_does_not_exist(Remote_Name),_)),

    with_transaction(
        Context,
        remove_remote_repository(Context, Remote_Name),
        _
    ).

update_remote(SystemDB, Auth, Path, Remote_Name, Remote_Location) :-
    atomic_list_concat([Path, '/_meta'], Repo_Path),

    do_or_die(
        resolve_absolute_string_descriptor(Repo_Path, Descriptor),
        error(invalid_absolute_path(Path),_)),

    check_descriptor_auth(SystemDB, Descriptor,
                          '@schema':'Action/meta_write_access', Auth),

    do_or_die(
        create_context(Descriptor, Context),
        error(unresolvable_target_descriptor(Descriptor),_)),

    do_or_die(
        has_remote_repository(Context, Remote_Name),
        error(remote_does_not_exist(Remote_Name),_)),

    with_transaction(
        Context,
        update_repository_remote_url(Context, Remote_Name, Remote_Location),
        _
    ).

show_remote(SystemDB, Auth, Path, Remote_Name, Remote_Location) :-
    atomic_list_concat([Path, '/_meta'], Repo_Path),

    do_or_die(
        resolve_absolute_string_descriptor(Repo_Path, Descriptor),
        error(invalid_absolute_path(Path),_)),

    check_descriptor_auth(SystemDB, Descriptor,
                          '@schema':'Action/meta_write_access', Auth),

    do_or_die(
        create_context(Descriptor, Context),
        error(unresolvable_target_descriptor(Descriptor),_)),

    do_or_die(
        has_remote_repository(Context, Remote_Name),
        error(remote_does_not_exist(Remote_Name),_)),

    repository_remote_url(Context, Remote_Name, Remote_Location).

list_remotes(SystemDB, Auth, Path, Remote_Names) :-
    atomic_list_concat([Path, '/_meta'], Repo_Path),

    do_or_die(
        resolve_absolute_string_descriptor(Repo_Path, Descriptor),
        error(invalid_absolute_path(Path),_)),

    check_descriptor_auth(SystemDB, Descriptor,
                          '@schema':'Action/meta_write_access', Auth),

    do_or_die(
        create_context(Descriptor, Context),
        error(unresolvable_target_descriptor(Descriptor),_)),

    findall(Remote_Name,
            has_remote_repository(Context, Remote_Name),
            Remote_Names).


:- begin_tests(remote_tests).

:- use_module(core(util/test_utils)).

test(add_remote,
     [setup((setup_temp_store(State),
             create_db_with_test_schema('admin','test'))),
      cleanup(teardown_temp_store(State))])
:-
    open_descriptor(system_descriptor{}, System),
    add_remote(System, 'User/admin', 'admin/test', 'remote', 'http://remote_url'),
    resolve_absolute_string_descriptor("admin/test/_meta", Descriptor),
    has_remote_repository(Descriptor, "remote").


test(remove_remote,
     [setup((setup_temp_store(State),
             create_db_with_test_schema('admin','test'))),
      cleanup(teardown_temp_store(State))])
:-
    open_descriptor(system_descriptor{}, System),
    add_remote(System, 'User/admin', 'admin/test', 'remote', 'http://remote_url'),
    remove_remote(System, 'User/admin', 'admin/test', 'remote'),
    resolve_absolute_string_descriptor("admin/test/_meta", Descriptor),
    \+ has_remote_repository(Descriptor, "remote").

test(update_remote,
     [setup((setup_temp_store(State),
             create_db_with_test_schema('admin','test'))),
      cleanup(teardown_temp_store(State))])
:-
    open_descriptor(system_descriptor{}, System),
    add_remote(System, 'User/admin', 'admin/test', 'remote', 'http://remote_url'),
    update_remote(System, 'User/admin', 'admin/test', 'remote', 'http://remote_url'),
    resolve_absolute_string_descriptor("admin/test/_meta", Descriptor),
    has_remote_repository(Descriptor, "remote").

test(show_remote,
     [setup((setup_temp_store(State),
             create_db_with_test_schema('admin','test'))),
      cleanup(teardown_temp_store(State))])
:-
    open_descriptor(system_descriptor{}, System),
    add_remote(System, 'User/admin', 'admin/test', 'remote', 'http://remote_url'),
    show_remote(System, 'User/admin', 'admin/test', 'remote', 'http://remote_url'),
    resolve_absolute_string_descriptor('admin/test/_meta', Descriptor),
    has_remote_repository(Descriptor, 'remote').


:- end_tests(remote_tests).
