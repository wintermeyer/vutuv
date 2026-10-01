defmodule Vutuv.Beta.Feature do
  @moduledoc """
  One beta feature in the `Vutuv.Beta` registry.

  * `key` — the atom a call site asks `Vutuv.Beta.enabled?/2` about; stored as
    its string in `users.beta_features` once somebody switches it on.
  * `audience` — `:members` (offered to every signed-in member) or `:admins`
    (offered to admins only). Being offered is all it decides: an admin still
    switches an admin feature on themselves.
  * `since` — the day it went into beta, so a feature that has sat there for
    months is visible on the settings page instead of forgotten.
  * `title` / `description` — msgids in the registry, translated by
    `Vutuv.Beta.available/1` for the settings page.
  """

  @enforce_keys [:key, :audience, :since, :title, :description]
  defstruct [:key, :audience, :since, :title, :description]

  @type t :: %__MODULE__{
          key: atom,
          audience: :members | :admins,
          since: Date.t(),
          title: binary,
          description: binary
        }
end
