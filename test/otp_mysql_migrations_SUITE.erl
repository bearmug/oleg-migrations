-module(otp_mysql_migrations_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all() -> [ migrate_one_script_test
         , migrate_few_scripts_test
         , incremental_migration_test
         , wrong_initial_version_test
         , migration_gap_test
           %%         , transactional_migration_test
         ].

migrate_one_script_test(Opts) ->
    Conn = ?config(conn, Opts),
    PreparedCall = pure_migrations:migrate(
                     filename:join([?config(data_dir, Opts), "00-single-script-test"]),
                     otp_mysql_tx_fun(Conn),
                     otp_mysql_query_fun(Conn)
                    ),
    ?assertEqual(ok, PreparedCall()),
    ?assertMatch(
       {ok,[<<"max(version)">>],[[0]]},
       mysql:query(Conn, "select max(version) from database_migrations_history")).

migrate_few_scripts_test(Opts) ->
    Conn = ?config(conn, Opts),
    PreparedCall = pure_migrations:migrate(
                     filename:join([?config(data_dir, Opts), "01-two-scripts-test"]),
                     otp_mysql_tx_fun(Conn),
                     otp_mysql_query_fun(Conn)
                    ),
    ?assertEqual(ok, PreparedCall()),
    ?assertMatch(
       {ok,[<<"max(version)">>],[[1]]},
       mysql:query(Conn, "select max(version) from database_migrations_history")),
    ?assertMatch(
       {ok,[<<"count(*)">>],[[1]]},
       mysql:query(Conn, "select count(*) from fruit where color = 'yellow'")).

incremental_migration_test(Opts) ->
    Conn = ?config(conn, Opts),
    MigrationStep1 = pure_migrations:migrate(
                       filename:join([?config(data_dir, Opts), "00-single-script-test"]),
                       otp_mysql_tx_fun(Conn), otp_mysql_query_fun(Conn)
                      ),
    MigrationStep2 = pure_migrations:migrate(
                       filename:join([?config(data_dir, Opts), "01-two-scripts-test"]),
                       otp_mysql_tx_fun(Conn), otp_mysql_query_fun(Conn)
                      ),

    %% assert migrations table created and nothing done
    ?assertMatch(
       {ok,[<<"max(version)">>],[[null]]},
       mysql:query(Conn, "select max(version) from database_migrations_history")),
    ?assertMatch(
       {error, _, _},
       mysql:query(Conn, "select count(*) from fruit")),

    %% assert step 1 migration
    ok = MigrationStep1(),
    ?assertMatch(
       {ok,[<<"max(version)">>],[[0]]},
       mysql:query(Conn, "select max(version) from database_migrations_history")),

    %% assert step 2 migration
    ok =MigrationStep2(),
    ?assertMatch(
       {ok,[<<"max(version)">>],[[1]]},
       mysql:query(Conn, "select max(version) from database_migrations_history")),
    ?assertMatch(
       {ok,[<<"count(*)">>],[[1]]},
       mysql:query(Conn, "select count(*) from fruit where color = 'yellow'")).

wrong_initial_version_test(Opts) ->
    Conn = ?config(conn, Opts),
    PreparedCall = pure_migrations:migrate(
                     filename:join([?config(data_dir, Opts), "02-wrong-initial-version"]),
                     otp_mysql_tx_fun(Conn),
                     otp_mysql_query_fun(Conn)
                    ),
    ?assertEqual(
       {rollback, {badmatch, {error, unexpected_version, {expected, 0, supplied, 20}}}},
       PreparedCall()).

migration_gap_test(Opts) ->
    Conn = ?config(conn, Opts),
    MigrationStep1 = pure_migrations:migrate(
                       filename:join([?config(data_dir, Opts), "00-single-script-test"]),
                       otp_mysql_tx_fun(Conn), otp_mysql_query_fun(Conn)
                      ),
    MigrationStep2 = pure_migrations:migrate(
                       filename:join([?config(data_dir, Opts), "03-migration-gap"]),
                       otp_mysql_tx_fun(Conn), otp_mysql_query_fun(Conn)
                      ),

    %% assert step 1 migration
    ok = MigrationStep1(),
    ?assertMatch(
       {ok,[<<"max(version)">>],[[0]]},
       mysql:query(Conn, "select max(version) from database_migrations_history")),

    %% assert step 2 failed migration
    ?assertEqual(
       {rollback, {badmatch, {error, unexpected_version, {expected, 1, supplied, 2}}}},
       MigrationStep2()),
    ?assertMatch(
       {ok,[<<"max(version)">>],[[0]]},
       mysql:query(Conn, "select max(version) from database_migrations_history")),
    ?assertMatch(
       {ok, [{error, [{severity, 'ERROR'}|_]}]},
       mysql:query(Conn, "select count(*) from fruit where color = 'yellow'")).

transactional_migration_test(Opts) ->
    Conn = ?config(conn, Opts),
    PreparedCall = pure_migrations:migrate(
                     filename:join([?config(data_dir, Opts), "04-last-migration-fail"]),
                     otp_mysql_tx_fun(Conn),
                     otp_mysql_query_fun(Conn)
                    ),
    ?assertMatch(
       {rollback, {badmatch, {error, [{severity,'ERROR'}|_]}}},
       PreparedCall()),
    ?assertMatch(
       {ok,[<<"max(version)">>],[[null]]},
       mysql:query(Conn, "select max(version) from database_migrations_history")),
    ?assertMatch(
       {ok, [{error, [{severity,'ERROR'}|_]}]},
       mysql:query(Conn, "select count(*) from fruit")).

otp_mysql_query_fun(Conn) ->
    fun(Q) ->
            case mysql:query(Conn, Q) of
                {ok, [{error, Details}]} -> {error, Details};
                {ok,[<<"version">>,<<"filename">>],[]} -> [];
                {ok, [{_, [
                           {"version", text, _, _, _, _, _},
                           {"filename", text, _, _, _, _, _}], Data}]} ->
                    [{list_to_integer(V), F} || [V, F] <- Data];
                {ok,[<<"max(version)">>],[[null]]} -> -1;
                {ok,[<<"max(version)">>],[[V]]} -> V;
                {ok, _} -> ok;
                Default -> io:format("otp_mysql_query_fun res=~p~n", [Default]), Default
            end
    end.

otp_mysql_tx_fun(Conn) ->
    fun(F) ->
            mysql:query(Conn, "BEGIN"),
            try F() of
                Res ->
                    mysql:query(Conn, "COMMIT"),
                    Res
            catch
                _:Problem ->
                    mysql:query(Conn, "ROLLBACK"),
                    {rollback, Problem}
            end
    end.

init_per_testcase(_TestCase, Opts) ->
    {ok, [{host, Host},
          {port, Port},
          {database, Database},
          {username, Username},
          {secret, Secret},
          {timeout, _Timeout}]} = application:get_env(mysql, config),
    {ok, Conn} = mysql:start_link([ {host, Host}
                                  , {port, Port}
                                  , {user, Username}
                                  , {password, Secret}
                                  , {database, Database}]),

    ok = mysql:query(Conn, "DROP TABLE IF EXISTS database_migrations_history, fruit"),
    [{conn, Conn}|Opts].

end_per_testcase(_TestCase, Opts) ->
    exit(?config(conn, Opts), normal).
