defmodule Vutuv.Prefs.Default do
  @moduledoc """
  One installation-default override: the admin-chosen default value for a
  preference key, replacing the shipped default for every member (and
  logged-out visitor) who has not set their own value.

  Only *overrides* are stored: a key without a row falls back to the shipped
  default from the `Vutuv.Prefs` registry, and setting a key back to its
  shipped value deletes the row. `value` is the canonical string encoding
  (`Vutuv.Prefs.dump/2`); the registry entry's type decodes it on load, so a
  row for a retired key or with a stale encoding is simply ignored.
  """

  use VutuvWeb, :model

  schema "pref_defaults" do
    field(:key, :string)
    field(:value, :string)

    timestamps()
  end
end
