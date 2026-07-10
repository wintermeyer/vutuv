defmodule Vutuv.Prefs.Pref do
  @moduledoc """
  One member-preference definition in the `Vutuv.Prefs` registry.

  * `key` — the atom name of the (nullable) `users` column holding a member's
    explicit choice; `nil` there means "inherit the installation default".
  * `type` — `:integer`, `:boolean` or `:select`.
  * `default` — the shipped default, used when the installation has not set
    its own. This is the **only** place a pref's default lives: the Ecto
    schema field and the DB column deliberately carry none.
  * `group` — the settings cluster the pref renders under (`:post_display`,
    `:maps`, ...); groups drive the admin form layout and the per-group
    "Reset to defaults" action.
  * `min`/`max` — the inclusive bounds of an `:integer` pref.
  * `values` — the allowed strings of a `:select` pref.
  """

  @enforce_keys [:key, :type, :default, :group]
  defstruct [:key, :type, :default, :group, :min, :max, :values]

  @type t :: %__MODULE__{
          key: atom,
          type: :integer | :boolean | :select,
          default: integer | boolean | binary,
          group: atom,
          min: integer | nil,
          max: integer | nil,
          values: [binary] | nil
        }
end
