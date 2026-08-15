defmodule Vutuv.DnsTest do
  @moduledoc """
  `Vutuv.Dns` reads a TXT record from the zone's own authoritative name servers
  instead of a caching resolver (issue #1466). Every test injects its own
  backend module, so nothing here touches real DNS and the file stays async.
  """

  use ExUnit.Case, async: true

  alias Vutuv.Dns

  @token "vutuv-organization-verify=abc123"

  # A backend whose answers are read from the test's own data. `ns` maps a zone
  # name to its NS names, `a` an NS name to its addresses, and `txt` a
  # {name, server_ip} pair to the authoritative answer.
  defmodule Stub do
    @behaviour Vutuv.Dns.Backend

    @impl true
    def lookup(name, :ns), do: get(:ns, name, [])
    def lookup(name, :a), do: get(:a, name, [])
    def lookup(name, :aaaa), do: get(:aaaa, name, [])
    def lookup(name, :txt), do: get(:txt_resolver, name, [])

    @impl true
    def txt_at(name, [{ip, 53} | _]) do
      record(:asked, {name, ip})
      get(:txt, {name, ip}, {:error, :timeout})
    end

    def put(key, map), do: Process.put({__MODULE__, key}, map)

    def asked, do: Process.get({__MODULE__, :asked}, []) |> Enum.reverse()

    defp get(key, subject, default) do
      Process.get({__MODULE__, key}, %{}) |> Map.get(subject, default)
    end

    defp record(key, value) do
      Process.put({__MODULE__, key}, [value | Process.get({__MODULE__, key}, [])])
    end
  end

  describe "zone_candidates/1" do
    test "walks up the labels, deepest first, and never offers a bare TLD" do
      assert Dns.zone_candidates("_vutuv.vutuv.de") == ["_vutuv.vutuv.de", "vutuv.de"]
      assert Dns.zone_candidates("vutuv.de") == ["vutuv.de"]

      assert Dns.zone_candidates("shop.eu.example.co.uk") == [
               "shop.eu.example.co.uk",
               "eu.example.co.uk",
               "example.co.uk",
               "co.uk"
             ]
    end

    test "a single label has no zone to ask" do
      assert Dns.zone_candidates("de") == []
      assert Dns.zone_candidates("") == []
    end
  end

  describe "txt_records/2 against the authoritative servers" do
    test "asks the zone's own name servers and returns what they answer" do
      Stub.put(:ns, %{"vutuv.de" => ["a.ns14.net"]})
      Stub.put(:a, %{"a.ns14.net" => [{185, 132, 35, 160}]})
      Stub.put(:txt, %{{"vutuv.de", {185, 132, 35, 160}} => {:ok, [[~c"#{@token}"]]}})

      assert Dns.txt_records("vutuv.de", Stub) == [[~c"#{@token}"]]
      assert Stub.asked() == [{"vutuv.de", {185, 132, 35, 160}}]
    end

    test "walks up to the parent zone for a name that is not delegated itself" do
      Stub.put(:ns, %{"vutuv.de" => ["a.ns14.net"]})
      Stub.put(:a, %{"a.ns14.net" => [{185, 132, 35, 160}]})
      Stub.put(:txt, %{{"_vutuv.vutuv.de", {185, 132, 35, 160}} => {:ok, [[~c"#{@token}"]]}})

      assert Dns.txt_records("_vutuv.vutuv.de", Stub) == [[~c"#{@token}"]]
    end

    test "keeps asking while one server is behind the others" do
      Stub.put(:ns, %{"vutuv.de" => ["a.ns14.net", "b.ns14.net"]})
      Stub.put(:a, %{"a.ns14.net" => [{1, 1, 1, 1}], "b.ns14.net" => [{2, 2, 2, 2}]})

      Stub.put(:txt, %{
        {"vutuv.de", {1, 1, 1, 1}} => {:ok, []},
        {"vutuv.de", {2, 2, 2, 2}} => {:ok, [[~c"#{@token}"]]}
      })

      assert Dns.txt_records("vutuv.de", Stub) == [[~c"#{@token}"]]
    end

    test "an unreachable server does not end the round" do
      Stub.put(:ns, %{"vutuv.de" => ["a.ns14.net", "b.ns14.net"]})
      Stub.put(:a, %{"a.ns14.net" => [{1, 1, 1, 1}], "b.ns14.net" => [{2, 2, 2, 2}]})

      Stub.put(:txt, %{
        {"vutuv.de", {1, 1, 1, 1}} => {:error, :timeout},
        {"vutuv.de", {2, 2, 2, 2}} => {:ok, [[~c"#{@token}"]]}
      })

      assert Dns.txt_records("vutuv.de", Stub) == [[~c"#{@token}"]]
    end

    test "an authoritative empty answer is trusted, so no cached answer creeps back in" do
      Stub.put(:ns, %{"vutuv.de" => ["a.ns14.net"]})
      Stub.put(:a, %{"a.ns14.net" => [{1, 1, 1, 1}]})
      Stub.put(:txt, %{{"vutuv.de", {1, 1, 1, 1}} => {:ok, []}})
      # A stale positive still sitting in the resolver cache must not be used.
      Stub.put(:txt_resolver, %{"vutuv.de" => [[~c"#{@token}"]]})

      assert Dns.txt_records("vutuv.de", Stub) == []
    end

    test "falls back to the resolver when no name server can be found" do
      Stub.put(:txt_resolver, %{"vutuv.de" => [[~c"#{@token}"]]})

      assert Dns.txt_records("vutuv.de", Stub) == [[~c"#{@token}"]]
      assert Stub.asked() == []
    end

    test "falls back to the resolver when every name server is unreachable" do
      Stub.put(:ns, %{"vutuv.de" => ["a.ns14.net"]})
      Stub.put(:a, %{"a.ns14.net" => [{1, 1, 1, 1}]})
      Stub.put(:txt, %{{"vutuv.de", {1, 1, 1, 1}} => {:error, :timeout}})
      Stub.put(:txt_resolver, %{"vutuv.de" => [[~c"#{@token}"]]})

      assert Dns.txt_records("vutuv.de", Stub) == [[~c"#{@token}"]]
    end
  end

  describe "nameservers/2" do
    test "refuses an internal address, so a hostile zone cannot point us inside" do
      Stub.put(:ns, %{"evil.example" => ["ns.evil.example"]})

      Stub.put(:a, %{
        "ns.evil.example" => [{127, 0, 0, 1}, {10, 0, 0, 5}, {169, 254, 169, 254}, {9, 9, 9, 9}]
      })

      assert Dns.nameservers("evil.example", Stub) == [{{9, 9, 9, 9}, 53}]
    end

    test "takes IPv6 only when the name server has no IPv4 address" do
      Stub.put(:ns, %{"example.org" => ["ns.example.org"]})
      Stub.put(:aaaa, %{"ns.example.org" => [{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}]})

      assert Dns.nameservers("example.org", Stub) == [{{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, 53}]
    end

    test "asks at most a handful of servers, however many the zone lists" do
      names = Enum.map(1..9, &"ns#{&1}.example.org")
      Stub.put(:ns, %{"example.org" => names})
      Stub.put(:a, Map.new(Enum.with_index(names, 1), fn {n, i} -> {n, [{9, 9, 9, i}]} end))

      assert length(Dns.nameservers("example.org", Stub)) == 4
    end
  end
end
