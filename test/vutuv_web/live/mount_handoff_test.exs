defmodule VutuvWeb.Live.MountHandoffTest do
  @moduledoc """
  The single-use dead-render → socket-mount handoff store. Entries are keyed
  by the *authenticated* viewer plus a subject, consumed on first take and
  expired after a short TTL, so this can never behave like a general cache:
  no reuse, no cross-viewer reads, no invalidation logic to get wrong.

  The table is global (a named ETS table), but every test here keys with ids
  minted per test (UUIDv7), so async modules cannot collide on entries.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.Live.MountHandoff

  defp uid, do: Vutuv.UUIDv7.generate()

  test "a stashed payload is taken exactly once" do
    viewer = uid()
    payload = %{posts: [:a, :b], totals: %{jobs: 3}}

    assert :ok = MountHandoff.stash(viewer, {:profile, "p1"}, payload)
    assert {:ok, ^payload} = MountHandoff.take(viewer, {:profile, "p1"})

    # Single-use: the first take consumed it (a reconnect must full-load).
    assert :error = MountHandoff.take(viewer, {:profile, "p1"})
  end

  test "another viewer's key never sees the entry, and does not consume it" do
    viewer = uid()
    other = uid()

    :ok = MountHandoff.stash(viewer, :feed, %{entries: []})

    assert :error = MountHandoff.take(other, :feed)
    assert {:ok, %{entries: []}} = MountHandoff.take(viewer, :feed)
  end

  test "the same viewer's different subjects are separate entries" do
    viewer = uid()

    :ok = MountHandoff.stash(viewer, :feed, %{entries: [:feed]})
    :ok = MountHandoff.stash(viewer, {:profile, "p1"}, %{posts: [:profile]})

    assert {:ok, %{posts: [:profile]}} = MountHandoff.take(viewer, {:profile, "p1"})
    assert {:ok, %{entries: [:feed]}} = MountHandoff.take(viewer, :feed)
  end

  test "an expired entry is not served" do
    viewer = uid()

    # ttl 0: expires the moment it is written (monotonic clock, so this is
    # deterministic — no wall-clock boundary to flake on).
    :ok = MountHandoff.stash(viewer, :feed, %{entries: []}, 0)

    assert :error = MountHandoff.take(viewer, :feed)
  end

  test "an anonymous viewer is never stashed for and never takes" do
    assert :ok = MountHandoff.stash(nil, :feed, %{entries: []})
    assert :error = MountHandoff.take(nil, :feed)
  end

  test "a fresh stash overwrites the previous one for the same key" do
    viewer = uid()

    :ok = MountHandoff.stash(viewer, :feed, %{entries: [:old]})
    :ok = MountHandoff.stash(viewer, :feed, %{entries: [:new]})

    assert {:ok, %{entries: [:new]}} = MountHandoff.take(viewer, :feed)
    assert :error = MountHandoff.take(viewer, :feed)
  end
end
