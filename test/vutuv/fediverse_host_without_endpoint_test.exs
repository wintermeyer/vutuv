defmodule Vutuv.FediverseHostWithoutEndpointTest do
  @moduledoc """
  The "who are we" host rule has to answer before `VutuvWeb.Endpoint` is
  started, because two callers ask it there (issue #1777).

  `VutuvWeb.Endpoint` is the **last** child in `Vutuv.Application`, and
  `Endpoint.host/0` raises until it has written its `:persistent_term`. Anything
  running earlier and asking for the host therefore gets an exception rather
  than an answer — which is what `Vutuv.PeopleCounter` got on every cold boot,
  its zero-delay `:reconcile_fediverse` reaching `own_hosts/0` through
  `distinct_follower_count/0` long before the endpoint was up. The
  `people_snapshots` migration hit the same wall.

  So the boot window is what this module reproduces: it erases the endpoint's
  persistent term, which is exactly the state those callers run in, and asks the
  host questions there. `async: false` and restoring in `on_exit`, because that
  term is VM-global and the SQL sandbox does not roll it back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse

  # Phoenix's own key — the one `Endpoint.host/0` reads (see the generated
  # `persistent!/0` in `Phoenix.Endpoint`).
  @endpoint_term {Phoenix.Endpoint, VutuvWeb.Endpoint}

  setup do
    started = :persistent_term.get(@endpoint_term)
    :persistent_term.erase(@endpoint_term)

    on_exit(fn -> :persistent_term.put(@endpoint_term, started) end)

    :ok
  end

  test "the endpoint really is unavailable in this state" do
    # Calibration. Without this the three tests below would pass just as well
    # against a started endpoint and prove nothing about the boot window.
    # The host they assert is the one `config/test.exs` gives the endpoint.
    assert_raise RuntimeError, ~r/could not find persistent term/, fn ->
      VutuvWeb.Endpoint.host()
    end
  end

  test "own_hosts/0 still lists every spelling of this installation" do
    hosts = Fediverse.own_hosts()

    assert "localhost" in hosts
    assert "www.localhost" in hosts
    assert "tags.localhost" in hosts
  end

  test "tag_host/0 and local_host?/1 answer too" do
    assert Fediverse.tag_host() == "tags.localhost"
    assert Fediverse.local_host?("https://localhost/frida")
    refute Fediverse.local_host?("https://remote.example/users/frida")
  end

  test "distinct_follower_count/0 — PeopleCounter's first tick — does not raise" do
    assert is_integer(Fediverse.distinct_follower_count())
  end
end
