defmodule Vutuv.ProcessHelpers do
  @moduledoc """
  Killing a job mid-run without killing the test's database connection.

  A test that proves a job survives a deploy spawns it, lets it get going and
  kills it. Under the SQL sandbox the job runs on the test's own connection
  (shared mode, or `Ecto.Adapters.SQL.Sandbox.allow/3`), and a client that
  dies while a query is under way takes that connection with it: the
  ownership proxy stops, and the test's next query exits with
  `DBConnection.Holder.checkout … no process` or an `OwnershipError`. A job
  that writes as it goes (a progress stamp every two percent, a row per page)
  is inside a query often enough for a kill at a random moment to turn CI red
  now and then, which is what `Vutuv.VideosTest` did.

  `kill_between_queries/1` suspends the process, looks where it stands, and
  kills it only while no query is under way; otherwise it lets the process
  run for a moment and looks again.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @tries 200

  @doc """
  Kills `pid` between two of its queries. Returns `:killed`, or `:finished`
  when the process had already ended, which a test racing a fast job has to
  allow for.
  """
  def kill_between_queries(pid), do: kill(pid, @tries)

  defp kill(pid, tries) do
    cond do
      not suspend(pid) ->
        :finished

      not in_query?(pid) ->
        Process.exit(pid, :kill)
        :killed

      tries == 0 ->
        :erlang.resume_process(pid)
        flunk("#{inspect(pid)} never left the database")

      true ->
        :erlang.resume_process(pid)
        Process.sleep(1)
        kill(pid, tries - 1)
    end
  end

  defp suspend(pid) do
    :erlang.suspend_process(pid)
  rescue
    ArgumentError -> false
  end

  # A connection is checked out in DBConnection and spoken to in Postgrex, so a
  # process inside a query has one of the two among the eight frames the
  # default backtrace depth keeps.
  defp in_query?(pid) do
    {:current_stacktrace, stack} = Process.info(pid, :current_stacktrace)

    Enum.any?(stack, fn {module, _fun, _arity, _location} ->
      String.starts_with?(inspect(module), ["DBConnection", "Postgrex"])
    end)
  end
end
