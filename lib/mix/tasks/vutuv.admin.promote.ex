defmodule Mix.Tasks.Vutuv.Admin.Promote do
  @shortdoc "Grants admin rights to a member (by @handle or email address)"

  @moduledoc """
  Mints an admin — the way a fresh installation bootstraps its first one.
  The `admin?` flag is deliberately never settable through any form or API.

      mix vutuv.admin.promote stefan.wintermeyer
      mix vutuv.admin.promote sw@example.com

  In production (a release, no Mix) use
  `bin/vutuv eval 'Vutuv.Release.promote_admin("stefan.wintermeyer")'` instead.
  """

  use Mix.Task

  @impl Mix.Task
  def run([identifier]) do
    Mix.Task.run("app.start")

    case Vutuv.Accounts.promote_admin(identifier) do
      {:ok, user} ->
        Mix.shell().info("@#{user.username} is an admin now.")

      {:error, :not_found} ->
        Mix.raise("No member found for #{inspect(identifier)} (looked up as @handle and email).")

      {:error, changeset} ->
        Mix.raise("Could not promote #{inspect(identifier)}: #{inspect(changeset.errors)}")
    end
  end

  def run(_args) do
    Mix.raise("Usage: mix vutuv.admin.promote <handle-or-email>")
  end
end
