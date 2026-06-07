defmodule Vutuv.UUIDv7Test do
  use ExUnit.Case, async: true

  alias Vutuv.UUIDv7

  test "generate/0 returns a canonical v7 UUID stamped with the current time" do
    uuid = UUIDv7.generate()

    assert byte_size(uuid) == 36
    assert {:ok, raw} = Ecto.UUID.dump(uuid)
    assert <<millisecond::48, version::4, _::12, variant::2, _::62>> = raw
    assert version == 7
    assert variant == 0b10
    assert_in_delta millisecond, System.system_time(:millisecond), 1_000
  end

  test "autogenerate/0 mints v7" do
    assert {:ok, <<_::48, 7::4, _::12, 2::2, _::62>>} =
             Ecto.UUID.dump(UUIDv7.autogenerate())
  end

  test "generate_at/1 encodes the given timestamp" do
    dt = ~U[2020-01-02 03:04:05.678Z]

    for input <- [dt, DateTime.to_naive(dt), DateTime.to_unix(dt, :millisecond)] do
      uuid = UUIDv7.generate_at(input)
      assert {:ok, <<millisecond::48, 7::4, _::12, 2::2, _::62>>} = Ecto.UUID.dump(uuid)
      assert millisecond == DateTime.to_unix(dt, :millisecond)
    end
  end

  test "ids sort by creation time, as strings and as binaries" do
    times = [~U[2016-05-01 12:00:00Z], ~U[2021-01-01 00:00:00Z], ~U[2026-06-07 00:00:00Z]]
    uuids = Enum.map(times, &UUIDv7.generate_at/1)

    assert Enum.sort(uuids) == uuids
    raws = Enum.map(uuids, &(Ecto.UUID.dump(&1) |> elem(1)))
    assert Enum.sort(raws) == raws
  end

  test "ids minted within the same millisecond still sort by creation time" do
    # rand_a carries the sub-ms fraction (RFC 9562 method 3): 100µs < 900µs.
    earlier = UUIDv7.generate_at(~U[2026-06-07 12:00:00.000100Z])
    later = UUIDv7.generate_at(~U[2026-06-07 12:00:00.000900Z])

    assert earlier < later
  end

  test "cast/dump/load round-trip" do
    uuid = UUIDv7.generate()

    assert {:ok, ^uuid} = UUIDv7.cast(uuid)
    assert {:ok, raw} = UUIDv7.dump(uuid)
    assert {:ok, ^uuid} = UUIDv7.load(raw)
    assert UUIDv7.type() == :uuid
  end

  test "cast_or_nil/1 nils anything that is not a UUID (e.g. pre-cutover integer ids)" do
    uuid = UUIDv7.generate()

    assert UUIDv7.cast_or_nil(uuid) == uuid
    assert UUIDv7.cast_or_nil(42) == nil
    assert UUIDv7.cast_or_nil("42") == nil
    assert UUIDv7.cast_or_nil(nil) == nil
  end
end
