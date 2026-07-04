defmodule Vutuv.Repo do
  use Ecto.Repo,
    otp_app: :vutuv,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Bumps `field` on `record` to now, but at most once per `resolution_seconds`,
  so a hot row (a session's `last_seen_at`, an API token's `last_used_at`) is
  not written on every request. Returns the (possibly unchanged) record.
  """
  def touch_throttled(record, field, resolution_seconds)
      when is_atom(field) and is_integer(resolution_seconds) do
    now = DateTime.utc_now(:second)
    current = Map.fetch!(record, field)

    if is_nil(current) or DateTime.diff(now, current) >= resolution_seconds do
      record |> Ecto.Changeset.change(%{field => now}) |> update!()
    else
      record
    end
  end
end
