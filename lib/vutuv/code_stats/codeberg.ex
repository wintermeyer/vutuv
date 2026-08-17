defmodule Vutuv.CodeStats.Codeberg do
  @moduledoc """
  The Codeberg client of the code-forge statistics (`Vutuv.CodeStats`).

  Codeberg **runs Forgejo**, so this client is `Vutuv.CodeStats.Forgejo` with
  the host filled in: one fixed, trusted API base and its own req-options seam,
  so a test never intercepts a self-hosted instance's requests by accident. The
  requests, the parsing and the snapshot all live there.
  """

  alias Vutuv.CodeStats.Forgejo

  # The public Forgejo API — a fixed host, never member input.
  @api "https://codeberg.org/api/v1"

  # The application-env seam tests stub HTTP through (see Vutuv.SocialFeed.Http).
  @req_options :codeberg_req_options

  @doc """
  The blocking fetch (run inside the fetcher's task, and directly by tests):
  `{:ok, stats_map}` or a classified `{:error, :gone | :transient}`.
  """
  def fetch_stats(handle), do: Forgejo.fetch_stats(handle, @api, @req_options)
end
