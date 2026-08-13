defmodule Vutuv.FediverseDistinctFollowersDisabledTest do
  @moduledoc """
  What the people total's Fediverse half says on an installation that does not
  federate (`:fediverse_enabled` off, the intranet case).

  Its own file, and `async: false`, because the flag is application-global and
  the SQL sandbox does not roll it back: while this module holds it down, every
  other test reading it — `Vutuv.Fediverse.enabled?/0` and everything gated on
  it, `Vutuv.Tags.Timeline`, the landing page's Fediverse section — would see
  the changed value.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follower

  setup do
    original = Application.fetch_env(:vutuv, :fediverse_enabled)
    Application.put_env(:vutuv, :fediverse_enabled, false)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :fediverse_enabled, was)
        :error -> Application.delete_env(:vutuv, :fediverse_enabled)
      end
    end)

    :ok
  end

  test "stored followers stop counting once the installation leaves the Fediverse" do
    Repo.insert!(%Follower{
      user_id: insert(:activated_user).id,
      actor_uri: "https://remote.example/users/frida",
      inbox_uri: "https://remote.example/users/frida/inbox"
    })

    # The row is still there (switching the feature off is not a deletion), but
    # it describes a follow no server can act on any more, so it is not reach
    # and must not inflate the figure in the top bar.
    assert Fediverse.distinct_follower_count() == 0
  end
end
