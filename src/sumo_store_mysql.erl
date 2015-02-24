%%% @hidden
%%% @doc MySql store implementation.
%%%
%%% Copyright 2012 Inaka &lt;hello@inaka.net&gt;
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% @end
%%% @copyright Inaka <hello@inaka.net>
%%%
-module(sumo_store_mysql).
-author("Marcelo Gornstein <marcelog@gmail.com>").
-github("https://github.com/inaka").
-license("Apache License 2.0").

-include_lib("emysql/include/emysql.hrl").

-behavior(sumo_store).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Exports.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Public API.
-export([init/1]).
-export([create_schema/2]).
-export([persist/2]).
-export([delete/3, delete_by/3, delete_all/2]).
-export([prepare/3, execute/2, execute/3]).
-export([just_execute/2, just_execute/3, get_docs/3, get_docs/4]).
-export([find_all/2, find_all/5, find_by/3, find_by/5, find_by/6]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Types.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {pool :: atom() | pid()}).

-type state() :: #state{}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% External API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec init(term()) -> {ok, term()}.
init(Options) ->
  % The storage backend key in the options specifies the name of the process
  % which creates and initializes the storage backend.
  Backend = proplists:get_value(storage_backend, Options),
  Pool    = sumo_backend_mysql:get_pool(Backend),
  {ok, #state{pool=Pool}}.

-spec persist(sumo_internal:doc(), state()) ->
  sumo_store:result(sumo_internal:doc(), state()).
persist(Doc, State) ->
  % Set the real id, replacing undefined by 0 so it is autogenerated
  DocName = sumo_internal:doc_name(Doc),
  IdField = sumo_internal:id_field_name(DocName),
  NewId   =
    case sumo_internal:get_field(IdField, Doc) of
      undefined -> 0;
      Id        -> Id
    end,
  NewDoc = sumo_internal:set_field(IdField, NewId, Doc),
  % Needed because the queries will carry different number of arguments.
  Statement =
    case NewId of
      0     -> insert;
      NewId -> update
    end,

  Fields   = sumo_internal:doc_fields(NewDoc),
  NPFields = maps:remove(IdField, Fields), % Non-primary fields.
  FieldNames = maps:keys(Fields),
  NPFieldNames = maps:keys(NPFields),

  Fun =
    fun() ->
      [ColumnDqls, ColumnSqls] =
        lists:foldl(
          fun(Name, [Dqls, Sqls]) ->
            Dql = [escape(Name)],
            Sql = "?",
            [[Dql | Dqls], [Sql | Sqls]]
          end,
          [[], []],
          FieldNames
        ),

      NPColumnDqls =
        lists:foldl(
          fun(Name, Dqls) ->
            Dql = [escape(Name)],
            [Dql | Dqls]
          end,
          [],
          NPFieldNames
        ),

      TableName          = escape(DocName),
      ColumnsText        = string:join(ColumnDqls, ","),
      InsertValueSlots   = string:join(ColumnSqls, ","),
      OnDuplicateColumns = [[ColumnName, "=?"] || ColumnName <- NPColumnDqls],
      OnDuplicateSlots   = string:join(OnDuplicateColumns, ","),

      [ "INSERT INTO ", TableName
      , " (", ColumnsText, ")"
      , " VALUES (", InsertValueSlots, ")"
      , " ON DUPLICATE KEY UPDATE "
      , OnDuplicateSlots
      ]
    end,

  StatementName   = prepare(DocName, Statement, Fun),
  ColumnValues    = lists:reverse([maps:get(K, Fields)
                                   || K <- maps:keys(Fields)]),
  NPColumnValues  = lists:reverse([maps:get(K, Fields)
                                   || K <- maps:keys(NPFields)]),
  StatementValues = lists:append(ColumnValues, NPColumnValues),

  case execute(StatementName, StatementValues, State) of
    #ok_packet{insert_id = InsertId} ->
      % XXX TODO darle una vuelta mas de rosca
      % para el manejo general de cuando te devuelve el primary key
      % considerar el caso cuando la primary key (campo id) no es integer
      % tenes que poner unique index en lugar de primary key
      % la mejor solucion es que el PK siempre sea un integer, como hace mongo
      LastId =
        case InsertId of
          0 -> NewId;
          I -> I
        end,
      IdField = sumo_internal:id_field_name(DocName),
      {ok, sumo_internal:set_field(IdField, LastId, Doc), State};
    Error ->
      evaluate_execute_result(Error, State)
  end.

-spec delete(sumo:schema_name(), sumo:field_value(), state()) ->
  sumo_store:result(sumo_store:affected_rows(), state()).
delete(DocName, Id, State) ->
  StatementName = prepare(DocName, delete, fun() -> [
    "DELETE FROM ", escape(DocName),
    " WHERE ", escape(sumo_internal:id_field_name(DocName)),
    "=? LIMIT 1"
  ] end),
  case execute(StatementName, [Id], State) of
    #ok_packet{affected_rows = NumRows} -> {ok, NumRows > 0, State};
    Error -> evaluate_execute_result(Error, State)
  end.

-spec delete_by(sumo:schema_name(), sumo:conditions(), state()) ->
  sumo_store:result(sumo_store:affected_rows(), state()).
delete_by(DocName, Conditions, State) ->
  {Values, CleanConditions} = sumo_sql_builder:values_conditions(Conditions),
  Clauses = sumo_sql_builder:where_clause(CleanConditions),
  HashClause = hash(Clauses),
  PreStatementName = list_to_atom("delete_by_" ++ HashClause),

  StatementFun =
    fun() ->
      [ "DELETE FROM ",
        escape(DocName),
        " WHERE ",
        Clauses
      ]
    end,
  StatementName = prepare(DocName, PreStatementName, StatementFun),
  Values = [V || {_K, V} <- Conditions],
  case execute(StatementName, Values, State) of
    #ok_packet{affected_rows = NumRows} -> {ok, NumRows, State};
    Error -> evaluate_execute_result(Error, State)
  end.

-spec delete_all(sumo:schema_name(), state()) ->
  sumo_store:result(sumo_store:affected_rows(), state()).
delete_all(DocName, State) ->
  StatementName = prepare(DocName, delete_all, fun() ->
    ["DELETE FROM ", escape(DocName)]
  end),
  case execute(StatementName, State) of
    #ok_packet{affected_rows = NumRows} -> {ok, NumRows, State};
    Error -> evaluate_execute_result(Error, State)
  end.

-spec find_all(sumo:schema_name(), state()) ->
  sumo_store:result([sumo_internal:doc()], state()).
find_all(DocName, State) ->
  find_all(DocName, [], 0, 0, State).

-spec find_all(sumo:schema_name(),
               term(),
               non_neg_integer(),
               non_neg_integer(),
               state()) ->
  sumo_store:result([sumo_internal:doc()], state()).
find_all(DocName, SortFields, Limit, Offset, State) ->
  find_by(DocName, [], SortFields, Limit, Offset, State).

-spec find_by(sumo:schema_name(), sumo:conditions(), state()) ->
  sumo_store:result([sumo_internal:doc()], state()).
find_by(DocName, Conditions, State) ->
  find_by(DocName, Conditions, [], 0, 0, State).

-spec find_by(sumo:schema_name(),
              sumo:conditions(),
              non_neg_integer(),
              non_neg_integer(),
              state()) ->
  sumo_store:result([sumo_internal:doc()], state()).
find_by(DocName, Conditions, Limit, Offset, State) ->
  find_by(DocName, Conditions, [], Limit, Offset, State).

%% XXX We should have a DSL here, to allow querying in a known language
%% to be translated by each driver into its own.
-spec find_by(sumo:schema_name(),
              sumo:conditions(),
              term(),
              non_neg_integer(),
              non_neg_integer(),
              state()) ->
  sumo_store:result([sumo_internal:doc()], state()).
find_by(DocName, Conditions, SortFields, Limit, Offset, State) ->
  {Values, CleanConditions} = sumo_sql_builder:values_conditions(Conditions),
  Clauses = sumo_sql_builder:where_clause(CleanConditions),
  PreStatementName0 = hash(Clauses),

  PreStatementName1 =
    case Limit of
      0     -> PreStatementName0;
      Limit -> PreStatementName0 ++ "_limit"
    end,

  {PreStatementName2, OrderByClause} =
    case SortFields of
      [] ->
        {PreStatementName1, []};
      _ ->
        OrderByClause0 = sumo_sql_builder:order_by_clause(SortFields),
        {
          PreStatementName1 ++ "_" ++ hash(OrderByClause0),
          OrderByClause0
        }
    end,

  WhereClause =
    case Conditions of
      [] -> "";
      _  -> [" WHERE ", Clauses]
    end,

  PreName = list_to_atom("find_by_" ++ PreStatementName2),

  Fun = fun() ->
    % Select * is not good..
    Sql1 = [ "SELECT * FROM ",
             escape(DocName),
             WhereClause,
             OrderByClause
           ],
    Sql2 = case Limit of
      0 -> Sql1;
      _ -> [Sql1|[" LIMIT ?, ?"]]
    end,
    Sql2
  end,

  StatementName = prepare(DocName, PreName, Fun),

  ExecArgs =
    case Limit of
      0     -> Values;
      Limit -> Values ++ [Offset, Limit]
    end,

  case execute(StatementName, ExecArgs, State) of
    #result_packet{} = Result ->
      {ok, build_docs(DocName, Result), State};
    Error ->
      evaluate_execute_result(Error, State)
  end.

%% XXX: Refactor:
%% Requires {length, X} to be the first field attribute in order to form the
%% correct query. :P
%% If no indexes are defined, will put an extra comma :P
%% Maybe it would be better to just use ALTER statements instead of trying to
%% create the schema on the 1st pass. Also, ALTER statements might be better
%% for when we have migrations.
-spec create_schema(sumo:schema(), state()) -> sumo_store:result(state()).
create_schema(Schema, State) ->
  Name = sumo_internal:schema_name(Schema),
  Fields = sumo_internal:schema_fields(Schema),
  FieldsDql = lists:map(fun create_column/1, Fields),
  Indexes = lists:filter(
    fun(T) -> length(T) > 0 end,
    lists:map(fun create_index/1, Fields)
  ),
  Dql = [
    "CREATE TABLE IF NOT EXISTS ", escape(Name), " (",
    string:join(FieldsDql, ", "), ", ", string:join(Indexes, ", "),
    ") ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8"
  ],
  case execute(Dql, State) of
    #ok_packet{} -> {ok, State};
    Error -> evaluate_execute_result(Error, State)
  end.

create_column(Field) ->
  create_column(
    sumo_internal:field_name(Field),
    sumo_internal:field_type(Field),
    sumo_internal:field_attrs(Field)).

create_column(Name, integer, Attrs) ->
  [escape(Name), " INT(11) ", create_column_options(Attrs)];

create_column(Name, float, Attrs) ->
  [escape(Name), " FLOAT ", create_column_options(Attrs)];

create_column(Name, text, Attrs) ->
  [escape(Name), " TEXT ", create_column_options(Attrs)];

create_column(Name, binary, Attrs) ->
  [escape(Name), " BLOB ", create_column_options(Attrs)];

create_column(Name, string, Attrs) ->
  [escape(Name), " VARCHAR ", create_column_options(Attrs)];

create_column(Name, date, Attrs) ->
  [escape(Name), " DATE ", create_column_options(Attrs)];

create_column(Name, datetime, Attrs) ->
  [escape(Name), " DATETIME ", create_column_options(Attrs)].

create_column_options(Attrs) ->
  lists:filter(fun(T) -> is_list(T) end, lists:map(
    fun(Option) ->
      create_column_option(Option)
    end,
    Attrs
  )).

create_column_option(auto_increment) ->
  ["AUTO_INCREMENT "];

create_column_option(not_null) ->
  [" NOT NULL "];

create_column_option({length, X}) ->
  ["(", integer_to_list(X), ") "];

create_column_option(_Option) ->
  none.

create_index(Field) ->
  Name = sumo_internal:field_name(Field),
  Attrs = sumo_internal:field_attrs(Field),
  lists:filter(fun(T) -> is_list(T) end, lists:map(
    fun(Attr) ->
      create_index(Name, Attr)
    end,
    Attrs
  )).

create_index(Name, id) ->
  ["PRIMARY KEY(", escape(Name), ")"];

create_index(Name, unique) ->
  List = atom_to_list(Name),
  ["UNIQUE KEY ", escape(List), " (", escape(List), ")"];

create_index(Name, index) ->
  List = atom_to_list(Name),
  ["KEY ", escape(List), " (", escape(List), ")"];

create_index(_, _) ->
  none.

-spec prepare(sumo:schema_name(), atom(), fun()) -> atom().
prepare(DocName, PreName, Fun) when is_atom(PreName), is_function(Fun) ->
  Name = statement_name(DocName, PreName),
  case emysql_statements:fetch(Name) of
    undefined ->
      Query = iolist_to_binary(Fun()),
      log("Preparing query: ~p: ~p", [Name, Query]),
      ok = emysql:prepare(Name, Query);
    Q ->
      log("Using already prepared query: ~p: ~p", [Name, Q])
  end,
  Name.

%% @doc Call prepare/3 first, to get a well formed statement name.
-spec just_execute(atom() | list(), state()) ->
  {ok, {raw, ok}, state()} | {error, binary(), state()}.
just_execute(Query, State) ->
  case execute(Query, State) of
    #ok_packet{} -> {ok, {raw, ok}, State};
    Error -> evaluate_execute_result(Error, State)
  end.

-spec just_execute(atom(), list(), state()) ->
  {ok, {raw, ok}, state()} | {error, binary(), state()}.
just_execute(Name, Args, State) ->
  case execute(Name, Args, State) of
    #ok_packet{} -> {ok, {raw, ok}, State};
    Error -> evaluate_execute_result(Error, State)
  end.

%% @doc Call prepare/3 first, to get a well formed statement name.
-spec get_docs(atom(), atom() | list(), state()) ->
  {ok, {docs, [sumo_internal:doc()]}, state()} | {error, binary(), state()}.
get_docs(DocName, Query, State) ->
  case execute(Query, State) of
    #result_packet{} = Result ->
      {ok, {docs, build_docs(DocName, Result)}, State};
    Error ->
      evaluate_execute_result(Error, State)
  end.

-spec get_docs(atom(), atom(), list(), state()) ->
  {ok, {docs, [sumo_internal:doc()]}, state()} | {error, binary(), state()}.
get_docs(DocName, Name, Args, State) ->
  case execute(Name, Args, State) of
    #result_packet{} = Result ->
      {ok, {docs, build_docs(DocName, Result)}, State};
    Error ->
      evaluate_execute_result(Error, State)
  end.

build_docs(DocName, #result_packet{rows = Rows, field_list = Fields}) ->
  FieldNames = memoize:call(fun field_names/1, [Fields]),
  [build_doc(sumo_internal:new_doc(DocName), FieldNames, Row) || Row <- Rows].

field_names(Fields) ->
  [binary_to_atom(Field#field.name, utf8) || Field <- Fields].

build_doc(Doc, [], []) -> Doc;
build_doc(Doc, [FieldName|FieldNames], [Value|Values]) ->
  build_doc(sumo_internal:set_field(FieldName, Value, Doc), FieldNames, Values).

%% @doc Call prepare/3 first, to get a well formed statement name.
-spec execute(atom(), list(), state()) -> term().
execute(Name, Args, #state{pool=Pool}) when is_atom(Name), is_list(Args) ->
  {Time, Value} = timer:tc( emysql, execute, [Pool, Name, Args] ),
  log("Executed Query: ~s -> ~p (~pms)", [Name, Args, Time/1000]),
  Value.

-spec execute(atom() | list(), state()) -> term().
execute(Name, State) when is_atom(Name) ->
  execute(Name, [], State);
execute(PreQuery, #state{pool=Pool}) when is_list(PreQuery)->
  Query = iolist_to_binary(PreQuery),
  {Time, Value} = timer:tc( emysql, execute, [Pool, Query] ),
  log("Executed Query: ~s (~pms)", [Query, Time/1000]),
  Value.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Private API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc We can extend this to wrap around emysql records, so they don't end up
%% leaking details in all the store.
evaluate_execute_result(#error_packet{status = Status, msg = Msg}, State) ->
  {error, <<Status/binary, ":", (list_to_binary(Msg))/binary>>, State}.

escape(Name) when is_atom(Name) ->
  ["`", atom_to_list(Name), "`"];
escape(String) ->
  ["`", String, "`"].

statement_name(DocName, StatementName) ->
  list_to_atom(string:join(
    [atom_to_list(DocName), atom_to_list(StatementName), "stmt"], "_"
  )).

log(Msg, Args) ->
  case application:get_env(sumo_db, log_queries) of
    {ok, true} -> lager:debug(Msg, Args);
    _          -> ok
  end.

-spec hash(iodata()) -> string().
hash(Clause) ->
  Num = erlang:phash2(Clause),
  integer_to_list(Num).
