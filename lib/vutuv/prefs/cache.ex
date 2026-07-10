defmodule Vutuv.Prefs.Cache do
  @moduledoc """
  Holds the resolved installation defaults in `:persistent_term`, so pref
  resolution (which runs per rendered post card) never touches the database.

  Loads once at boot and reloads whenever an admin saves the defaults —
  `Vutuv.Prefs.put_defaults/1` broadcasts on `topic/0`, so every node of a
  cluster refreshes. While the cache holds
  nothing (test env, where this process is off — its reload queries would use
  the SQL-sandbox connection from a process that does not own it — or the
  moment before boot finishes) `Vutuv.Prefs.installation_defaults/0` falls
  back to the shipped defaults.
  """

  use GenServer

  @topic "prefs:defaults"
  @pt_key {Vutuv.Prefs, :installation_defaults}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "The PubSub topic an admin save of the defaults broadcasts on."
  def topic, do: @topic

  @doc "The cached defaults map, or `:not_loaded` while the cache holds nothing."
  def read, do: :persistent_term.get(@pt_key, :not_loaded)

  @doc "Install `defaults` as the cached map (also used by tests to inject)."
  def store(defaults) when is_map(defaults), do: :persistent_term.put(@pt_key, defaults)

  @doc "Drop the cached map (test cleanup)."
  def clear, do: :persistent_term.erase(@pt_key)

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Vutuv.PubSub, @topic)
    store(Vutuv.Prefs.load_installation_defaults())
    {:ok, :ok}
  end

  @impl true
  def handle_info(:defaults_changed, state) do
    store(Vutuv.Prefs.load_installation_defaults())
    {:noreply, state}
  end
end
