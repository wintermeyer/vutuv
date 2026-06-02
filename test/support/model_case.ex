defmodule Vutuv.ModelCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Vutuv.Repo

      import Ecto.Changeset
      import Ecto.Query
    end
  end

  setup tags do
    :ok = Sandbox.checkout(Vutuv.Repo)

    unless tags[:async] do
      Sandbox.mode(Vutuv.Repo, {:shared, self()})
    end

    :ok
  end
end
