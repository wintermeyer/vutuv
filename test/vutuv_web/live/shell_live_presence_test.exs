defmodule VutuvWeb.ShellLivePresenceTest do
  @moduledoc """
  Site-wide online presence, driven by the shell. ShellLive is the one component
  on every page, so it tracks the current member online (gated by their "Show
  when I'm online" setting) and pushes each viewer their own block-filtered
  online-id set to the Presence JS hook, which toggles the green dot on every
  avatar in the page.

  async: false — these tests track members on the shared, global presence topic
  and assert membership, so they must not interleave with each other.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias VutuvWeb.Presence

  defp session_for(user, extra \\ %{}) do
    Map.merge(
      %{
        "user_id" => user.id,
        "user_name" => "Greta Tester",
        "user_param" => user.username,
        "show_online" => true
      },
      extra
    )
  end

  test "tracks the member online and pushes them in the online set", %{conn: conn} do
    user = insert(:user)

    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))

    assert Presence.online?(Presence.online_ids(), user.id)

    # The hook is handed the viewer's online set; the member sees their own dot.
    assert_push_event(view, "presence:set", %{online: online})
    assert to_string(user.id) in online

    # Their own top-bar avatar carries the green dot.
    assert render(view) =~ "bg-emerald-500"
    assert has_element?(view, "#presence-hook")
  end

  test "a member who turned online status off is never tracked or dotted", %{conn: conn} do
    user = insert(:user)

    {:ok, view, _html} =
      live_isolated(conn, VutuvWeb.ShellLive,
        session: session_for(user, %{"show_online" => false})
      )

    refute Presence.online?(Presence.online_ids(), user.id)
    # No dot on their own avatar either.
    refute render(view) =~ "bg-emerald-500"
  end

  test "a blocked member is filtered out of the pushed online set", %{conn: conn} do
    viewer = insert(:activated_user)
    blocked = insert(:activated_user)
    {:ok, _block} = Vutuv.Social.block_user(viewer, blocked)

    # The blocked member is genuinely online (tracked by a live process), so
    # only the block — not absence — can keep them out of the viewer's set.
    agent = start_supervised!({Agent, fn -> :ok end})
    {:ok, _ref} = Presence.track_user(agent, blocked.id)

    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(viewer))

    assert Presence.online?(Presence.online_ids(), blocked.id)

    assert_push_event(view, "presence:set", %{online: online})
    assert to_string(viewer.id) in online
    refute to_string(blocked.id) in online
  end

  test "a presence join re-pushes the viewer's online set live", %{conn: conn} do
    viewer = insert(:user)
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(viewer))
    assert_push_event(view, "presence:set", %{online: _first})

    # Another member comes online; the shell re-pushes the (now larger) set.
    other = insert(:user)
    agent = start_supervised!({Agent, fn -> :ok end})
    {:ok, _ref} = Presence.track_user(agent, other.id)
    # Force the shell to process the presence_diff (and re-push) it has queued.
    _ = :sys.get_state(view.pid)

    # Mount + self-join emit earlier [viewer]-only pushes; consume past them
    # until the push that carries the new member's join.
    online = drain_until_online(view, to_string(other.id))
    assert to_string(other.id) in online
  end

  # Consume "presence:set" pushes in order until one includes `id`.
  defp drain_until_online(view, id, tries \\ 20) do
    assert_push_event(view, "presence:set", %{online: online})

    cond do
      id in online -> online
      tries > 0 -> drain_until_online(view, id, tries - 1)
      true -> flunk("#{id} never appeared in a pushed online set")
    end
  end

  test "no presence hook for a logged-out viewer", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: %{})

    refute has_element?(view, "#presence-hook")
  end

  test "a live opt-out untracks the member and drops their own dot", %{conn: conn} do
    user = insert(:user)
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(user))
    assert Presence.online?(Presence.online_ids(), user.id)

    # The member flips "Show when I'm online" off (broadcast from another tab).
    send(view.pid, {:presence_pref, false})
    _ = :sys.get_state(view.pid)

    refute Presence.online?(Presence.online_ids(), user.id)
    refute render(view) =~ "bg-emerald-500"
  end

  test "a live opt-in tracks the member and shows their dot", %{conn: conn} do
    user = insert(:user)

    {:ok, view, _html} =
      live_isolated(conn, VutuvWeb.ShellLive,
        session: session_for(user, %{"show_online" => false})
      )

    refute Presence.online?(Presence.online_ids(), user.id)

    send(view.pid, {:presence_pref, true})
    _ = :sys.get_state(view.pid)

    assert Presence.online?(Presence.online_ids(), user.id)
    assert render(view) =~ "bg-emerald-500"
  end

  test "a live block refresh drops the newly blocked member from the pushed set", %{conn: conn} do
    viewer = insert(:activated_user)
    other = insert(:activated_user)

    agent = start_supervised!({Agent, fn -> :ok end})
    {:ok, _ref} = Presence.track_user(agent, other.id)

    {:ok, view, _html} = live_isolated(conn, VutuvWeb.ShellLive, session: session_for(viewer))
    assert_push_event(view, "presence:set", %{online: before_ids})
    assert to_string(other.id) in before_ids

    # Blocking broadcasts :presence_blocks_changed to the viewer's topic.
    {:ok, _block} = Vutuv.Social.block_user(viewer, other)
    _ = :sys.get_state(view.pid)

    # The next push that reflects the refreshed filter no longer carries `other`.
    online = drain_until_absent(view, to_string(other.id))
    refute to_string(other.id) in online
  end

  # Consume "presence:set" pushes in order until one excludes `id`.
  defp drain_until_absent(view, id, tries \\ 20) do
    assert_push_event(view, "presence:set", %{online: online})

    cond do
      id not in online -> online
      tries > 0 -> drain_until_absent(view, id, tries - 1)
      true -> flunk("#{id} never left the pushed set")
    end
  end
end
