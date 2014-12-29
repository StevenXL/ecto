defmodule Ecto.Query.Planner do
  # Normalizes a query and its parameters.
  @moduledoc false

  alias Ecto.Query.SelectExpr
  alias Ecto.Query.JoinExpr
  alias Ecto.Query.Types

  @doc """
  Plans the struct for query execution.

  This function simply invokes `model/3` passing the persisted
  field names as arguments.
  """
  def struct(kind, %{__struct__: model} = struct) do
    model(kind, model, Map.take(struct, model.__schema__(:fields)))
  end

  @doc """
  Plans the given fields belong to a model for query execution.

  It is mostly a matter of casing the field values.
  """
  def model(kind, model, kw, dumper \\ &Types.dump/2) do
    for {field, value} <- kw do
      type = model.__schema__(:field, field)

      unless type do
        raise Ecto.InvalidModelError,
          message: "field `#{inspect model}.#{field}` in `#{kind}` does not exist in the model source"
      end

      case dumper.(type, value) do
        {:ok, value} ->
          {field, value}
        :error ->
          raise Ecto.InvalidModelError,
            message: "value `#{inspect value}` for `#{inspect model}.#{field}` " <>
                     "in `#{kind}` does not match type #{inspect type}"
      end
    end
  end

  @doc """
  Plans the query for execution.

  Planning happens in multiple steps:

    1. First the query is prepared by retrieving
       its cache key, casting and merging parameters

    2. Then a cache lookup is done, if the query is
       cached, we are done

    3. If there is no cache, we need to actually
       normalize and validate the query, before sending
       it to the adapter

    4. The query is sent to the adapter to be generated

  Currently only steps 1 and 3 are implemented.

  ## Cache

  All entries in the query, except the preload field, should
  be part of the cache key. The query key is composed by the
  cache key of children expressions which are typically
  pre-calculated at compilation time. However, some dynamic
  fields may force particular expressions to have their cache
  calculated at runtime.
  """
  def query(query, base, opts \\ []) do
    {query, params} = prepare(query, base)
    {normalize(query, base, opts), params}
  rescue
    e ->
      # Reraise errors so we ignore the planner inner stacktrace
      raise e
  end

  @doc """
  Prepares the query for cache.

  This means all the parameters from query expressions are
  merged into a single value and their entries are prunned
  from the query.

  In the future, this function should also calculate a hash
  to be used as cache key.

  This function is called by the backend before invoking
  any cache mechanism.
  """
  def prepare(query, params) do
    # TODO: Select fields normalization should be here
    query
    |> prepare_sources
    |> traverse_exprs(params, &merge_params/4)
  end

  defp merge_params(kind, query, expr, params) when kind in ~w(select limit offset)a do
    if expr do
      {put_in(expr.params, nil),
       cast_and_merge_params(kind, query, expr, params)}
   else
      {expr, params}
    end
  end

  defp merge_params(kind, query, exprs, params) when kind in ~w(distinct where group_by having order_by)a do
    Enum.map_reduce exprs, params, fn expr, acc ->
      {put_in(expr.params, nil),
       cast_and_merge_params(kind, query, expr, acc)}
    end
  end

  defp merge_params(:join, query, exprs, params) do
    Enum.map_reduce exprs, params, fn join, acc ->
      {put_in(join.on.params, nil),
       cast_and_merge_params(:join, query, join.on, acc)}
    end
  end

  defp cast_and_merge_params(kind, query, expr, params) do
    size = Map.size(params)
    Enum.reduce expr.params, params, fn {k, {v, type}}, acc ->
      Map.put acc, k + size, cast_param(kind, query, expr, v, type)
    end
  end

  defp cast_param(kind, query, expr, v, {composite, {idx, field}}) when is_integer(idx) do
    {_, model} = elem(query.sources, idx)
    type = type!(kind, query, expr, model, field)
    cast_param(kind, query, expr, model, field, v, {composite, type})
  end

  defp cast_param(kind, query, expr, v, {idx, field}) when is_integer(idx) do
    {_, model} = elem(query.sources, idx)
    type = type!(kind, query, expr, model, field)
    cast_param(kind, query, expr, model, field, v, type)
  end

  defp cast_param(kind, query, expr, v, type) do
    case Types.cast(type, v) do
      {:ok, nil} ->
        error! query, expr, "value `nil` in `#{kind}` cannot be cast to type #{inspect type} " <>
                            "(if you want to check for nils, use is_nil/1 instead)"
      {:ok, v} ->
        v
      :error ->
        error! query, expr, "value `#{inspect v}` in `#{kind}` cannot be cast to type #{inspect type}"
    end
  end

  defp cast_param(kind, query, expr, model, field, value, type) do
    cast_param(kind, query, expr, value, type)
  rescue
    e in [Ecto.QueryError] ->
      raise Ecto.CastError, model: model, field: field, value: value, type: type,
                            message: Exception.message(e) <>
                                     "\nError when casting value to `#{inspect model}.#{field}`"
  end

  # Normalize all sources and adds a source
  # field to the query for fast access.
  defp prepare_sources(query) do
    from = query.from || error!(query, "query must have a from expression")

    {joins, sources} =
      Enum.map_reduce(query.joins, [from], &prepare_join(&1, &2, query))

    %{query | sources: sources |> Enum.reverse |> List.to_tuple, joins: joins}
  end

  defp prepare_join(%JoinExpr{assoc: {ix, assoc}} = join, sources, query) do
    {_, model} = Enum.fetch!(Enum.reverse(sources), ix)

    unless model do
      error! query, join, "association join cannot be performed without a model"
    end

    refl = model.__schema__(:association, assoc)

    unless refl do
      error! query, join, "could not find association `#{assoc}` on model #{inspect model}"
    end

    associated = refl.assoc
    source     = {associated.__schema__(:source), associated}

    on = on_expr(join.on, refl, ix, length(sources))
    {%{join | source: source, on: on}, [source|sources]}
  end

  defp prepare_join(%JoinExpr{source: {source, nil}} = join, sources, _query) when is_binary(source) do
    source = {source, nil}
    {%{join | source: source}, [source|sources]}
  end

  defp prepare_join(%JoinExpr{source: {nil, model}} = join, sources, _query) when is_atom(model) do
    source = {model.__schema__(:source), model}
    {%{join | source: source}, [source|sources]}
  end

  defp on_expr(on, refl, var_ix, assoc_ix) do
    var = {:&, [], [var_ix]}
    owner_key = refl.owner_key
    assoc_key = refl.assoc_key
    assoc_var = {:&, [], [assoc_ix]}

    expr = quote do
      unquote(assoc_var).unquote(assoc_key) == unquote(var).unquote(owner_key)
    end

    %{on | expr: expr}
  end

  @doc """
  Normalizes the query.

  After the query was prepared and there is no cache
  entry, we need to update its interpolations and check
  its fields and associations exist and are valid.
  """
  def normalize(query, base, opts) do
    only_where? = Keyword.get(opts, :only_where, false)

    query
    |> traverse_exprs(map_size(base), &validate_and_increment/4)
    |> elem(0)
    |> normalize_select(only_where?)
    |> validate_assocs
    |> only_where(only_where?)
  end

  defp validate_and_increment(kind, query, expr, counter) when kind in ~w(select limit offset)a do
    if expr do
      do_validate_and_increment(kind, query, expr, counter)
    else
      {nil, counter}
    end
  end

  defp validate_and_increment(kind, query, exprs, counter) when kind in ~w(distinct where group_by having order_by)a do
    Enum.map_reduce exprs, counter, &do_validate_and_increment(kind, query, &1, &2)
  end

  defp validate_and_increment(:join, query, exprs, counter) do
    Enum.map_reduce exprs, counter, fn join, acc ->
      {on, acc} = do_validate_and_increment(:join, query, join.on, acc)
      {%{join | on: on}, acc}
    end
  end

  defp do_validate_and_increment(kind, query, expr, counter) do
    {inner, acc} = Macro.prewalk expr.expr, counter, fn
      {:^, meta, [param]}, acc ->
        {{:^, meta, [param + counter]}, acc + 1}
      {{:., _, [{:&, _, [source]}, field]}, meta, []} = quoted, acc ->
        validate_field(kind, query, expr, source, field, meta)
        {quoted, acc}
      other, acc ->
        {other, acc}
    end
    {%{expr | expr: inner}, acc}
  end

  defp validate_field(kind, query, expr, source, field, meta) do
    {_, model} = elem(query.sources, source)

    if model do
      type = type!(kind, query, expr, model, field)

      if (expected = meta[:ecto_type]) && !Types.match?(type, expected) do
        error! query, expr, "field `#{inspect model}.#{field}` in `#{kind}` does not type check. " <>
                            "It has type #{inspect type} but a type #{inspect expected} is expected"
      end
    end
  end

  # Normalize the select field.
  defp normalize_select(query, only_where?) do
    cond do
      only_where? ->
        query
      select = query.select ->
        %{query | select: prepopulate_select(query, select)}
      true ->
        %{query | select: prepopulate_select(query, %SelectExpr{expr: {:&, [], [0]}})}
    end
  end

  defp prepopulate_select(query, select) do
    # TODO: Allow assocs and fields to be mixed
    # TODO: Validate {:&, ..., [_]} have models
    if query.assocs == [] do
      fields = collect_fields(select.expr)
    else
      var    = {:&, [], [0]}
      fields = [var|collect_assocs(query.assocs)]
    end

    %{select | fields: fields, assocs: 0}
  end

  defp collect_assocs([{_assoc, {idx, children}}|tail]),
    do: [{:&, [], [idx]}] ++ collect_assocs(children) ++ collect_assocs(tail)
  defp collect_assocs([]),
    do: []

  defp collect_fields({left, right}),
    do: collect_fields([left, right])
  defp collect_fields({:{}, _, elems}),
    do: collect_fields(elems)
  defp collect_fields(list) when is_list(list),
    do: Enum.flat_map(list, &collect_fields/1)
  defp collect_fields(expr),
    do: [expr]

  defp validate_assocs(query) do
    validate_assocs(query, 0, query.assocs)
    query
  end

  defp validate_assocs(query, idx, assocs) do
    {_, parent_model} = elem(query.sources, idx)

    Enum.each assocs, fn {assoc, {child_idx, child_assocs}} ->
      refl = parent_model.__schema__(:association, assoc)

      unless refl do
        error! query, "field `#{inspect parent_model}.#{assoc}` " <>
                      "in preload is not an association"
      end

      {_, child_model} = elem(query.sources, child_idx)

      unless refl.assoc == child_model do
        error! query, "association `#{inspect parent_model}.#{assoc}` " <>
                      "in preload doesn't match join model `#{inspect child_model}`"
      end

      case find_source_expr(query, child_idx) do
        %JoinExpr{qual: qual} when qual in [:inner, :left] ->
          :ok
        %JoinExpr{qual: qual} ->
          error! query, "association `#{inspect parent_model}.#{assoc}` " <>
                        "in preload requires an inner or left join, got #{qual} join"
        _ ->
          :ok
      end

      validate_assocs(query, child_idx, child_assocs)
    end
  end

  defp find_source_expr(query, 0) do
    query.from
  end

  defp find_source_expr(query, idx) do
    Enum.fetch! query.joins, idx - 1
  end

  if map_size(%Ecto.Query{}) != 15 do
    raise "Ecto.Query match out of date in planner"
  end

  defp only_where(query, false), do: query
  defp only_where(query, true) do
    case query do
      %Ecto.Query{joins: [], select: nil, order_bys: [], limit: nil, offset: nil,
                  group_bys: [], havings: [], preloads: [], assocs: [], distincts: [],
                  lock: nil} ->
        query
      _ ->
        error! query, "only `where` expressions are allowed"
    end
  end

  ## Helpers

  # Traverse all query components with expressions.
  # Therefore from, preload and lock are not traversed.
  defp traverse_exprs(original, acc, fun) do
    query = original

    {select, acc} = fun.(:select, original, original.select, acc)
    query = %{query | select: select}

    {distincts, acc} = fun.(:distinct, original, original.distincts, acc)
    query = %{query | distincts: distincts}

    {joins, acc} = fun.(:join, original, original.joins, acc)
    query = %{query | joins: joins}

    {wheres, acc} = fun.(:where, original, original.wheres, acc)
    query = %{query | wheres: wheres}

    {group_bys, acc} = fun.(:group_by, original, original.group_bys, acc)
    query = %{query | group_bys: group_bys}

    {havings, acc} = fun.(:having, original, original.havings, acc)
    query = %{query | havings: havings}

    {order_bys, acc} = fun.(:order_by, original, original.order_bys, acc)
    query = %{query | order_bys: order_bys}

    {limit, acc} = fun.(:limit, original, original.limit, acc)
    query = %{query | limit: limit}

    {offset, acc} = fun.(:offset, original, original.offset, acc)
    {%{query | offset: offset}, acc}
  end

  defp type!(_kind, _query, _expr, nil, _field), do: :any

  defp type!(kind, query, expr, model, field) do
    if type = model.__schema__(:field, field) do
      type
    else
      error! query, expr, "field `#{inspect model}.#{field}` in `#{kind}` does not exist in the model source"
    end
  end

  def cast!(query, expr, message) do
    message =
      [message: message, query: query, file: expr.file, line: expr.line]
      |> Ecto.QueryError.exception()
      |> Exception.message

    raise Ecto.CastError, message: message
  end

  defp error!(query, message) do
    raise Ecto.QueryError, message: message, query: query
  end

  defp error!(query, expr, message) do
    raise Ecto.QueryError, message: message, query: query, file: expr.file, line: expr.line
  end
end