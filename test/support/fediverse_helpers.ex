defmodule Vutuv.FediverseHelpers do
  @moduledoc """
  The HTTP stub every "follow from your own server" test needs: a fake remote
  server answering the one WebFinger lookup `Vutuv.Fediverse.RemoteFollow`
  makes before it can hand a visitor to their own follow dialog.

  It lives here because three test files drive that lookup — the profile card,
  the page card and the hand-off shape (issue #1569) — and the stub is not
  free-form: `RemoteFollow` reads the `#subscribe` rel and demands an `https`
  template carrying `{uri}`, and Req's decode step branches on the
  content-type, so a stub that answers without `application/jrd+json` hands the
  client a binary where the real server's answer arrives decoded. Pinning that
  contract in one place is the point; a copy per file is a copy that drifts.

  A test module using this **must be `async: false`** — the stub is a global
  `Application.put_env/3`, so it is visible to everything running beside it.
  """

  import ExUnit.Assertions, only: [assert_receive: 2]
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Serves `fun` as the whole Fediverse HTTP client for one test, and takes the
  stub back down afterwards.
  """
  def stub_remote(fun) do
    Application.put_env(:vutuv, :fediverse_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  @doc """
  A remote server whose followers collection says `total`, with the
  `:fediverse_counts` flag switched on so a surface that asks for the number
  really does. Both are global, so the same `async: false` rule applies. Pair
  it with `await_background_tasks/0`: the fetch runs off the request.
  """
  def serve_follower_total(total) do
    stub_remote(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/activity+json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"totalItems" => total}))
    end)

    Application.put_env(:vutuv, :fediverse_counts, true)
    on_exit(fn -> Application.put_env(:vutuv, :fediverse_counts, false) end)
  end

  @doc "Waits until every task on `Vutuv.TaskSupervisor` has finished."
  def await_background_tasks do
    for pid <- Task.Supervisor.children(Vutuv.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end
  end

  @doc """
  The happy path: a remote server that publishes a remote-follow dialog at
  `https://social.example/authorize_interaction?uri={uri}`.
  """
  def serve_subscribe_template do
    stub_remote(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/jrd+json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "links" => [
            %{
              "rel" => "http://ostatus.org/spec/1.0#subscribe",
              "template" => "https://social.example/authorize_interaction?uri={uri}"
            }
          ]
        })
      )
    end)
  end
end
