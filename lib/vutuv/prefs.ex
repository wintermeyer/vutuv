defmodule Vutuv.Prefs do
  @moduledoc """
  Member preferences with installation defaults: the one place that knows
  which knobs a member can turn to shape how vutuv works *for them*, and how
  a value is resolved for rendering.

  Every preference is declared once in the `registry/0` (a `Vutuv.Prefs.Pref`
  per knob) and resolved in three layers:

  1. **The member's explicit choice** — a non-nil value in the pref's own
     nullable `users` column (set on their /settings pages, or by an admin on
     /admin/users/:id/preferences for support). An explicit `0`/`false` is a
     choice, not an absence.
  2. **The installation default** — set by an admin at /admin/preferences,
     stored as a `pref_defaults` row (`Vutuv.Prefs.Default`) and cached in
     `Vutuv.Prefs.Cache`. This is what every untouched member and every
     logged-out visitor gets, and the admin can change it at any time.
  3. **The shipped default** — the registry entry's `default`, used while the
     installation has not overridden it. It lives *only* here: the schema
     fields and DB columns deliberately carry no default, so "never touched"
     stays distinguishable from "chose the default value".

  Adding a preference = one additive migration (a nullable `users` column,
  no default), one registry entry (+ `label/1`, and a home on a /settings
  page). Both admin GUIs, the resolution and the reset actions pick it up
  from the registry; `test/vutuv/prefs_test.exs` guards the invariants.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Prefs.Cache
  alias Vutuv.Prefs.Default
  alias Vutuv.Prefs.Pref
  alias Vutuv.Repo

  # ── The registry ──
  #
  # Grouped in display order. The post-display values mirror the CSS fallbacks
  # in assets/css/components.css (.post-clamp / .markdown--post / .notif-clamp)
  # — see Vutuv.Accounts.User.post_prefs_defaults/0 and
  # notification_post_lines_default/0; the map defaults reproduce
  # "all services on, Google first" (Vutuv.Maps).
  @registry [
    %Pref{
      key: :post_lines_desktop,
      type: :integer,
      default: 6,
      min: 0,
      max: 50,
      group: :post_display
    },
    %Pref{
      key: :post_lines_mobile,
      type: :integer,
      default: 8,
      min: 0,
      max: 50,
      group: :post_display
    },
    %Pref{key: :post_hyphenate_desktop, type: :boolean, default: false, group: :post_display},
    %Pref{key: :post_hyphenate_mobile, type: :boolean, default: true, group: :post_display},
    # The quoted post body on /notifications. A quote there is context beside a
    # link to the post, not the post itself, so the minimum is 1 line rather
    # than the "0 = never shorten" the two counts above allow.
    %Pref{
      key: :notification_post_lines,
      type: :integer,
      default: 5,
      min: 1,
      max: 50,
      group: :post_display
    },
    %Pref{key: :map_google?, type: :boolean, default: true, group: :maps},
    %Pref{key: :map_openstreetmap?, type: :boolean, default: true, group: :maps},
    %Pref{key: :map_apple?, type: :boolean, default: true, group: :maps},
    %Pref{
      key: :default_map_service,
      type: :select,
      default: "google",
      values: ~w(google openstreetmap apple),
      group: :maps
    }
  ]

  @groups Enum.uniq(Enum.map(@registry, & &1.group))
  @keys Enum.map(@registry, & &1.key)
  @by_key Map.new(@registry, &{&1.key, &1})
  @shipped_defaults Map.new(@registry, &{&1.key, &1.default})

  @doc "Every preference definition, in display order."
  def registry, do: @registry

  @doc "The group keys, in display order."
  def groups, do: @groups

  @doc "The definitions of one group, in display order."
  def group_registry(group), do: Enum.filter(@registry, &(&1.group == group))

  @doc "The definition behind `key`. Raises on an unknown key."
  def pref!(key), do: Map.fetch!(@by_key, key)

  @doc "The registry keys."
  def keys, do: @keys

  # ── Labels (resolved at render time, so they follow the request locale) ──

  @doc "The human label of a pref, shared by the admin forms."
  def label(:post_lines_desktop), do: Gettext.gettext(VutuvWeb.Gettext, "Lines on desktop")
  def label(:post_lines_mobile), do: Gettext.gettext(VutuvWeb.Gettext, "Lines on mobile")

  def label(:post_hyphenate_desktop),
    do: Gettext.gettext(VutuvWeb.Gettext, "Hyphenate on desktop")

  def label(:post_hyphenate_mobile), do: Gettext.gettext(VutuvWeb.Gettext, "Hyphenate on mobile")

  def label(:notification_post_lines),
    do: Gettext.gettext(VutuvWeb.Gettext, "Lines in notifications")

  def label(:map_google?), do: Gettext.gettext(VutuvWeb.Gettext, "Show Google Maps")
  def label(:map_openstreetmap?), do: Gettext.gettext(VutuvWeb.Gettext, "Show OpenStreetMap")
  def label(:map_apple?), do: Gettext.gettext(VutuvWeb.Gettext, "Show Apple Maps")
  def label(:default_map_service), do: Gettext.gettext(VutuvWeb.Gettext, "Default map")

  @doc "A short muted helper line under the control, or nil."
  def hint(key) when key in [:post_lines_desktop, :post_lines_mobile],
    do: Gettext.gettext(VutuvWeb.Gettext, "0 means posts are never shortened.")

  def hint(:notification_post_lines),
    do:
      Gettext.gettext(
        VutuvWeb.Gettext,
        "How much of a post a notification quotes before it is cut off."
      )

  def hint(:default_map_service),
    do:
      Gettext.gettext(
        VutuvWeb.Gettext,
        "Opens first, as the main button. The others appear as alternatives."
      )

  def hint(_key), do: nil

  @doc "The human label of a pref group."
  def group_label(:post_display), do: Gettext.gettext(VutuvWeb.Gettext, "Posts")
  def group_label(:maps), do: Gettext.gettext(VutuvWeb.Gettext, "Maps")

  @doc "The human label of one value of a pref (select options, current-value lines)."
  def value_label(%Pref{type: :boolean}, true), do: Gettext.gettext(VutuvWeb.Gettext, "On")
  def value_label(%Pref{type: :boolean}, false), do: Gettext.gettext(VutuvWeb.Gettext, "Off")
  def value_label(%Pref{type: :integer}, value), do: Integer.to_string(value)
  def value_label(%Pref{key: :default_map_service}, "google"), do: Vutuv.Maps.label(:google)

  def value_label(%Pref{key: :default_map_service}, "openstreetmap"),
    do: Vutuv.Maps.label(:openstreetmap)

  def value_label(%Pref{key: :default_map_service}, "apple"), do: Vutuv.Maps.label(:apple)
  def value_label(%Pref{}, value), do: to_string(value)

  # ── Encoding ──

  @doc "The canonical string form of a value (form inputs, pref_defaults rows)."
  def dump(%Pref{type: :integer}, value), do: Integer.to_string(value)
  def dump(%Pref{type: :boolean}, value), do: to_string(value)
  def dump(%Pref{type: :select}, value), do: value

  @doc """
  Parse + validate one raw form/DB string against the definition. Returns
  `{:ok, value}` or `:error`; a raw that decodes but breaks the constraints
  (out of range, unknown option) is an `:error` too.
  """
  def parse(%Pref{type: :integer} = pref, raw) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} when n >= pref.min and n <= pref.max -> {:ok, n}
      _ -> :error
    end
  end

  def parse(%Pref{type: :boolean}, "true"), do: {:ok, true}
  def parse(%Pref{type: :boolean}, "false"), do: {:ok, false}

  def parse(%Pref{type: :select} = pref, raw) when is_binary(raw) do
    if raw in pref.values, do: {:ok, raw}, else: :error
  end

  def parse(%Pref{}, _raw), do: :error

  # ── Installation defaults ──

  @doc "The shipped defaults as a `%{key => value}` map."
  def shipped_defaults, do: @shipped_defaults

  @doc """
  The installation's defaults as a `%{key => value}` map: the shipped
  defaults with the admin's `pref_defaults` overrides applied. Served from
  `Vutuv.Prefs.Cache`; while the cache holds nothing the shipped defaults
  apply as-is.
  """
  def installation_defaults do
    case Cache.read() do
      :not_loaded -> @shipped_defaults
      defaults -> defaults
    end
  end

  @doc "The installation default of one pref."
  def default(key) when key in @keys, do: Map.fetch!(installation_defaults(), key)

  @doc """
  Resolve the `pref_defaults` rows into the full defaults map (what the cache
  stores). A row for a retired key, or whose value no longer parses under the
  current registry, is ignored — the shipped default applies.
  """
  def load_installation_defaults do
    Default
    |> Repo.all()
    |> Enum.reduce(@shipped_defaults, fn row, acc ->
      with %Pref{} = pref <- @by_key[maybe_key(row.key)],
           {:ok, value} <- parse(pref, row.value) do
        Map.put(acc, pref.key, value)
      else
        _ -> acc
      end
    end)
  end

  # Registry keys are a closed set, so the string→atom mapping is a lookup,
  # never String.to_atom on a DB value.
  @key_by_string Map.new(@keys, &{Atom.to_string(&1), &1})
  defp maybe_key(string), do: @key_by_string[string]

  @doc "The stored overrides as `%{key => raw_string}` (only known keys)."
  def list_default_rows do
    Default
    |> Repo.all()
    |> Enum.reduce(%{}, fn row, acc ->
      case maybe_key(row.key) do
        nil -> acc
        key -> Map.put(acc, key, row.value)
      end
    end)
  end

  @doc """
  Save the admin's installation defaults from raw form params
  (`%{"post_lines_desktop" => "6", ...}`; unknown keys are ignored). A value
  equal to the shipped default deletes the override row instead of storing a
  redundant one. All-or-nothing: any invalid value returns
  `{:error, [key, ...]}` and writes nothing. On success every node reloads
  its cache via PubSub.
  """
  def put_defaults(params) when is_map(params) do
    {changes, invalid} = parse_params(params)

    if invalid == [] do
      persist_defaults(changes)
      {:ok, installation_defaults()}
    else
      {:error, invalid}
    end
  end

  defp persist_defaults(changes) do
    Repo.transaction(fn ->
      Enum.each(changes, fn {pref, value} -> put_default(pref, value) end)
    end)

    broadcast_change()
  end

  defp put_default(%Pref{} = pref, value) do
    key = Atom.to_string(pref.key)

    if value == pref.default do
      Repo.delete_all(from(d in Default, where: d.key == ^key))
    else
      Repo.insert!(%Default{key: key, value: dump(pref, value)},
        on_conflict: {:replace, [:value, :updated_at]},
        conflict_target: :key
      )
    end
  end

  # Parse the known-key subset of raw params. Returns {[{pref, value}], [bad_key]};
  # for `allow_blank_as_nil` (the per-member override form) a blank raw means
  # "clear back to inherit" and parses to nil.
  defp parse_params(params, allow_blank_as_nil \\ false) do
    Enum.reduce(@registry, {[], []}, fn pref, acc ->
      case Map.fetch(params, Atom.to_string(pref.key)) do
        :error -> acc
        {:ok, raw} -> collect_parsed(acc, pref, raw, allow_blank_as_nil)
      end
    end)
  end

  defp collect_parsed({changes, invalid}, pref, raw, allow_blank_as_nil) do
    case parse_or_nil(pref, raw, allow_blank_as_nil) do
      {:ok, value} -> {[{pref, value} | changes], invalid}
      :error -> {changes, [pref.key | invalid]}
    end
  end

  defp parse_or_nil(_pref, raw, true) when raw in [nil, ""], do: {:ok, nil}
  defp parse_or_nil(pref, raw, _), do: parse(pref, raw)

  defp broadcast_change do
    Phoenix.PubSub.broadcast(Vutuv.PubSub, Cache.topic(), :defaults_changed)
  end

  # ── Resolution ──

  @doc """
  The effective value of one pref for a member (or `nil` = logged out): their
  explicit column value, or the installation default. The single read seam —
  `Vutuv.Accounts.User.post_prefs/1` and `Vutuv.Maps` resolve through it.
  """
  def get(nil, key), do: default(key)

  def get(user, key) when key in @keys do
    case Map.fetch!(user, key) do
      nil -> default(key)
      value -> value
    end
  end

  @doc """
  The member struct with every inherited (nil) pref field filled with its
  installation default — what the /settings forms render, so a member always
  sees the values that actually apply to them.
  """
  def with_effective(user) do
    Enum.reduce(@keys, user, fn key, acc ->
      case Map.fetch!(acc, key) do
        nil -> Map.put(acc, key, default(key))
        _ -> acc
      end
    end)
  end

  @doc "Whether the member holds an explicit value for any pref of `group`."
  def customized_in_group?(user, group) do
    Enum.any?(group_registry(group), &(Map.fetch!(user, &1.key) != nil))
  end

  # ── Per-member writes (support overrides, the per-group reset) ──

  @doc """
  Set a member's preferences from raw admin-form params. A blank value clears
  the field back to nil = "inherit the installation default"; anything else
  must parse under the registry. All-or-nothing like `put_defaults/1`.
  """
  def admin_update_user(user, params) when is_map(params) do
    {changes, invalid} = parse_params(params, true)

    if invalid == [] do
      user
      |> Ecto.Changeset.change(Map.new(changes, fn {pref, value} -> {pref.key, value} end))
      |> Repo.update()
    else
      {:error, invalid}
    end
  end

  @doc "Clear every pref of `group` back to inherit (the /settings reset buttons)."
  def reset_group(user, group) do
    user
    |> Ecto.Changeset.change(Map.new(group_registry(group), &{&1.key, nil}))
    |> Repo.update()
  end

  @doc """
  How many members hold an explicit value per pref (`%{key => count}`), shown
  on the admin defaults page so an admin knows how far a change reaches.
  """
  def customized_counts do
    select =
      Map.new(@registry, fn pref ->
        {pref.key,
         dynamic([u], fragment("count(*) FILTER (WHERE ? IS NOT NULL)", field(u, ^pref.key)))}
      end)

    Repo.one(from(u in User, select: ^select))
  end
end
