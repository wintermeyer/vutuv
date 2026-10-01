defmodule Vutuv.Beta.Feature do
  @moduledoc """
  One beta feature in the `Vutuv.Beta` registry.

  * `key` — the atom a call site asks `Vutuv.Beta.enabled?/2` about.
  * `since` — the day it went into beta, shown on the settings page so a
    feature that has sat there for months is noticed rather than forgotten.
  * `title` / `description` — msgids in the registry, translated by
    `Vutuv.Beta.current/0` for the settings page.
  """

  @enforce_keys [:key, :since, :title, :description]
  defstruct [:key, :since, :title, :description]

  @type t :: %__MODULE__{
          key: atom,
          since: Date.t(),
          title: binary,
          description: binary
        }
end
