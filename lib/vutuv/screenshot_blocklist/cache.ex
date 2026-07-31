defmodule Vutuv.ScreenshotBlocklist.Cache do
  @moduledoc """
  Holds the parsed screenshot blocklist in `:persistent_term`, so the check
  (which runs per rendered profile link and on every post save) never touches
  the database.

  Loads once at boot and reloads whenever an admin edits the list —
  `Vutuv.ScreenshotBlocklist` broadcasts on `topic/0`, so every node of a
  cluster refreshes. While the cache holds nothing (test env, where this
  process is off — its reload queries would use the SQL-sandbox connection from
  a process that does not own it — or the moment before boot finishes)
  `Vutuv.ScreenshotBlocklist.patterns/0` reads the table itself, from the
  calling process. Slower, never stale, and never wrong.
  """

  use GenServer

  @topic "screenshot_blocklist"
  @pt_key {Vutuv.ScreenshotBlocklist, :patterns}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "The PubSub topic an edit of the blocklist broadcasts on."
  def topic, do: @topic

  @doc "The cached patterns, or `:not_loaded` while the cache holds nothing."
  def read, do: :persistent_term.get(@pt_key, :not_loaded)

  @doc "Install `patterns` as the cached list (also used by tests to inject)."
  def store(patterns) when is_list(patterns), do: :persistent_term.put(@pt_key, patterns)

  @doc "Drop the cached list (test cleanup)."
  def clear, do: :persistent_term.erase(@pt_key)

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Vutuv.PubSub, @topic)
    store(Vutuv.ScreenshotBlocklist.load_patterns())
    {:ok, :ok}
  end

  @impl true
  def handle_info(:blocklist_changed, state) do
    store(Vutuv.ScreenshotBlocklist.load_patterns())
    {:noreply, state}
  end
end
