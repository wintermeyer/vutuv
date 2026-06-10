defmodule Vutuv.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Vutuv.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Vutuv.DataCase
      import Vutuv.Factory
      import Vutuv.MailboxHelpers
    end
  end

  setup tags do
    :ok = Sandbox.checkout(Vutuv.Repo)

    unless tags[:async] do
      Sandbox.mode(Vutuv.Repo, {:shared, self()})
    end

    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{email: "bad"})
      assert "is invalid" in errors_on(changeset).email
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
