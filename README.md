# Erlang ❤ pure database migrations
> Database migrations engine. Effects-free.

[![Build Status](https://travis-ci.org/bearmug/erlang-pure-migrations.svg?branch=master)](https://travis-ci.org/bearmug/erlang-pure-migrations) [![Coverage Status](https://coveralls.io/repos/github/bearmug/erlang-pure-migrations/badge.svg?branch=master)](https://coveralls.io/github/bearmug/erlang-pure-migrations?branch=master)

Migrate your Erlang application database with no effort.
This amazing toolkit has [one and only](https://en.wikipedia.org/wiki/Unix_philosophy)
purpose - consistently upgrade database schema, using Erlang stack.
As an extra - do this in "no side-effects" mode.

## Current limitations
 * **up** transactional migration available only. No **downgrade**
 or **rollback** possible. Either whole **up** migration completes OK
 or failed and rolled back to the state before migration.
 * migrations engine **deliberately isolated from any specific
 database library**. This way engine user is free to choose from variety
 of frameworks (see tested combinations here) and so on.

## Quick start
Just call `engine:migrate/3`, providing:
 * `Path` to migration scripts folder (strictly and incrementally enumerated).
 * `FTx` transaction handler
 * `FQuery` database queries execution handler
### Live samples
#### [Postgres](https://github.com/postgres/postgres) and [epgsql/epgsql](https://github.com/epgsql/epgsql)
<details>
  <summary>Click to expand</summary>

  ```erlang
  Conn = ?config(conn, Opts),
  MigrationCall =
    engine:migrate(
      "scripts/folder/path",
      fun(F) -> epgsql:with_transaction(Conn, fun(_) -> F() end) end,
      fun(Q) ->
        case epgsql:squery(Conn, Q) of
          {ok, [
            {column, <<"version">>, _, _, _, _, _},
            {column, <<"filename">>, _, _, _, _, _}], Data} ->
              [{list_to_integer(binary_to_list(BinV)), binary_to_list(BinF)} || {BinV, BinF} <- Data];
          {ok, [{column, <<"max">>, _, _, _, _, _}], [{null}]} -> -1;
          {ok, [{column, <<"max">>, _, _, _, _, _}], [{N}]} ->
            list_to_integer(binary_to_list(N));
          [{ok, _, _}, {ok, _}] -> ok;
          {ok, _, _} -> ok;
          {ok, _} -> ok;
          Default -> Default
        end
      end),
  ...
  %% more preparation steps here
  ...
  %% migration call
  ok = MigrationCall(),

  ```
Also see examples from live epgsql integration tests
[here](test/epgsql_migrations_SUITE.erl)
</details>


## Versioning model
### Versioning strictness
As mentioned, versioning model is very opinionated and declares itself
as strictly incremental from 0 and upwards. With given approach, there is
no way for conflicting database updates, applied from different pull-requests
or branches (depends on deployment model).
### No-downgrades policy
As you may see, there is **no downgrade feature available**. Please
consider this while evaluating library for your project. This hasn't been
tooling in order to:
 * keep tooling as simple as possible, obviously :)
 * delegate upcoming upgrades validation to CI with
   unit/integration/acceptance tests chain. Decent test pack and reasonable
   CI/CD process (metric-based rollouts, monitored environments, controlled
   test coverage regression) making database rollback feature virtually
   unused. And without healthy and automated CI/CD cycle there are much
   more opportunities to break the system. Database rollback opportunity
   could be little to no help.

### Usage with epgsql TBD
### Alternative wrappers TBD

## Purely functional approach
Oh, **there is more!** Library implemented in the [way](https://en.wikipedia.org/wiki/Pure_function),
that all side-effects either externalized or deferred explicitly. Goals
are quite common and well-known:
 * bring side-effects as close to program edges as possible. And
 eventually have referential transparency, enhanced code reasoning, better
 bugs reproduceability, etc...
 * make unit testing as simple as breeze
 * library users empowered to re-run idempotent code safely. Well, if
 tx/query handlers are real ones - execution is still idempotent (at
 application level) and formally pure. But purity maintained inside
 library code only. Some query calls are to be done anyway (like migrations
 table creation, if this one does not exist).

### Purity tool #1: effects externalization
There are 2 externalized kind of effects:
 * transaction management handler
 * database queries handler
Although, those two can`t be pure in real application, it is failrly
simple to replace them with their pure versions if we would like to
(for debug purposes, or testing, or something else).

### Purity tool #2: make effects explicit
Other effects (file operations, like directory listing or file content
read) are deferred in bulk. This way 2 goals achieved:
 * pure actions sequence built and validated without any impact from
 external world
 * library users decides if regarding moment, when they ready to apply
 changes. Maybe for some reason they would like to prepare execution ->
 change migrations folder content -> run migrations.

### Used functional programming abstractions
Sure, Erlang is deeply funcitonal language. But at the same time, for
obvious reasons ( 1)not much people need tools like these 2)it is deadly
 simple to implement required abstractions on your own), there are no
(at least I did not manage to find) widely used functional primitives
Erlang library.

#### Functions composition
Abstraction quite useful if someone would like to compose two functions
without their actual nested execution (or without their application,
alternatively speaking). This pretty standard routine may look like below
(Scala or Kotlin+Arrow):
```scala
val divideByTwo = (number : Int) => number / 2;
val addThree = (number: Int) => number + 3;
val composed = addThree compose divideByTwo
```
To keep things close to the ground and avoiding infix notation, in
Erlang it is could be represented like:
```erlang
compose(F1, F2) ->
  fun() -> F2(F1()) end.
```
You may find library funcitonal composition example in a few locations
[here](https://github.com/bearmug/oleg-migrations/blob/make-engine-free-of-side-effects/src/oleg_engine.erl#L36).

#### Functor applications
There area few places in library with clear need to compose function **A**
and another function **B** inside deferred execution context. Specifics is
that **A** supplies list of objects, and **B** should be applied to each of
them. Sounds like some functor **B** to be applied to **A** output, when
this output is being wrapped into future execution context. Two cases
of this appeared in library:
 * have functor running and produce nested list of contexts:
```erlang
%% Map/1 call here produces new context (defferred function call in Erlang)
map(Generate, Map) ->
  fun() -> [Map(R) || R <- Generate()] end.
```
 * flatten (or fold) contexts to a single one:
```erlang
%% Flatten/1 call compactifies contexts and folds 2 levels to single one
flatten(Generate, Flatten) ->
  fun() -> [Flatten(R) || R <- Generate()] end.
```
#### Partial function applications
This technique is very useful, in case if not all function arguments
known yet. Or maybe there is deliberate decision to pass some of arguments
later on. Again, in Scala it may look like:
```scala
val add = (a: Int, b: Int) => a + b
val partiallyApplied = add(3, _)
```
Library code has very simplistic partial application, done for exact
arguments number (although it is easy to generalize it for arguments,
represented as list):
```erlang
partial(F, A, B) ->
  fun(C) -> F(A, B, C) end.
```
Exactly this feature helps [here](https://github.com/bearmug/oleg-migrations/blob/make-engine-free-of-side-effects/src/oleg_engine.erl#L19)
to pass particular migration to partially applied function. Therefore,
no need to care about already known parameters.