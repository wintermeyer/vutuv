defmodule Vutuv.SchemaUuidChokepointTest do
  @moduledoc """
  Regression guard: every id in this system is a UUID v7. All schemas must use
  `Vutuv.UUIDv7` for their primary key and every `belongs_to` foreign key
  (wired once in `use VutuvWeb, :model`), and nothing may mint v4 ids with
  `Ecto.UUID.generate/0`.
  """
  use ExUnit.Case, async: true

  test "every schema uses Vutuv.UUIDv7 for its primary key" do
    for mod <- schema_modules() do
      assert mod.__schema__(:primary_key) == [:id],
             "#{inspect(mod)} must keep the conventional :id primary key"

      assert mod.__schema__(:type, :id) == Vutuv.UUIDv7,
             "#{inspect(mod)}.id must be Vutuv.UUIDv7, got " <>
               "#{inspect(mod.__schema__(:type, :id))} — schemas inherit the type " <>
               "from `use VutuvWeb, :model`, do not override it"
    end
  end

  test "every belongs_to foreign key is Vutuv.UUIDv7" do
    for mod <- schema_modules(),
        assoc_name <- mod.__schema__(:associations),
        %Ecto.Association.BelongsTo{owner_key: fk} <-
          [mod.__schema__(:association, assoc_name)] do
      assert mod.__schema__(:type, fk) == Vutuv.UUIDv7,
             "#{inspect(mod)}.#{fk} must be Vutuv.UUIDv7, got " <>
               inspect(mod.__schema__(:type, fk))
    end
  end

  test "nothing mints v4 UUIDs with Ecto.UUID.generate/bingenerate" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(fn path ->
        contents = File.read!(path)
        contents =~ "Ecto.UUID.generate(" or contents =~ "Ecto.UUID.bingenerate("
      end)

    assert offenders == [],
           "Mint ids with Vutuv.UUIDv7.generate/0 (v7), never Ecto.UUID (v4). " <>
             "Offending files: #{Enum.join(offenders, ", ")}"
  end

  defp schema_modules do
    {:ok, modules} = :application.get_key(:vutuv, :modules)

    schemas =
      Enum.filter(modules, fn mod ->
        Code.ensure_loaded?(mod) and function_exported?(mod, :__schema__, 1) and
          mod.__schema__(:source) != nil
      end)

    # Guard the filter itself: if this drops, the assertions above test nothing.
    assert length(schemas) >= 30, "expected to find all schemas, got #{length(schemas)}"

    schemas
  end
end
