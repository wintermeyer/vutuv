defmodule Vutuv.UUIDv7 do
  @moduledoc """
  UUID version 7 Ecto type — the only id type in this app.

  v7 ids embed a 48-bit Unix-millisecond timestamp, so they sort by creation
  time and keep primary-key index inserts local. The column type stays `:uuid`
  (`:binary_id` in migrations); only the generation differs from `Ecto.UUID`,
  which mints random v4 values and must never be used to mint ids.

  Used as `@primary_key`/`@foreign_key_type` for every schema via
  `use VutuvWeb, :model`. Mint ids in code with `generate/0`, never
  `Ecto.UUID.generate/0` (see `test/vutuv/schema_uuid_chokepoint_test.exs`).
  """
  use Ecto.Type

  @impl true
  def type, do: Ecto.UUID.type()

  @impl true
  defdelegate cast(value), to: Ecto.UUID

  @impl true
  defdelegate dump(value), to: Ecto.UUID

  @impl true
  defdelegate load(value), to: Ecto.UUID

  @impl true
  def autogenerate, do: generate()

  @doc "Generates a v7 UUID string for the current time."
  def generate, do: from_microseconds(System.system_time(:microsecond))

  @doc "Generates a v7 UUID string whose timestamp part encodes the given time."
  def generate_at(%DateTime{} = dt), do: from_microseconds(DateTime.to_unix(dt, :microsecond))

  def generate_at(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> generate_at()

  def generate_at(millisecond) when is_integer(millisecond),
    do: from_microseconds(millisecond * 1000)

  # The 12 rand_a bits carry the sub-millisecond fraction (RFC 9562 §6.2
  # method 3), so ids minted in the same millisecond still sort by creation
  # time — the feed's keyset tiebreaker (`id < ^id`) relies on id order
  # matching insert order, which bigserial used to give for free.
  defp from_microseconds(microsecond) do
    millisecond = Integer.floor_div(microsecond, 1000)
    sub_ms = div(Integer.mod(microsecond, 1000) * 4096, 1000)
    <<_::2, rand_b::62>> = :crypto.strong_rand_bytes(8)
    {:ok, uuid} = Ecto.UUID.load(<<millisecond::48, 7::4, sub_ms::12, 2::2, rand_b::62>>)
    uuid
  end

  @doc """
  The two ids as a `{smaller, larger}` tuple — the one home of the "smaller id
  first" convention. Canonical lowercase-hex UUIDs compare in the same order as
  their bytes, so a plain `<` agrees with the Postgres `uuid` ordering that the
  `sorted_pair` check constraints on the conversation/connection tables rely on.
  """
  def sorted_pair(id1, id2) when id1 < id2, do: {id1, id2}
  def sorted_pair(id1, id2), do: {id2, id1}

  @doc """
  Casts a value to a UUID string, or `nil` if it cannot be cast.

  Session cookies issued before the UUID cutover hold integer user ids; this
  lets readers treat them as logged out instead of raising `Ecto.CastError`.
  """
  def cast_or_nil(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  @doc """
  Casts `value` to a UUID and calls `fun` with it, or returns `nil` when it
  cannot be cast. Folds the `case cast_or_nil(id) do nil -> nil; uuid -> … end`
  guard the scoped get_* lookups repeat, so a malformed id is a miss (nil) and
  never an `Ecto.CastError`.
  """
  def with_cast(value, fun) when is_function(fun, 1) do
    case cast_or_nil(value) do
      nil -> nil
      uuid -> fun.(uuid)
    end
  end
end
