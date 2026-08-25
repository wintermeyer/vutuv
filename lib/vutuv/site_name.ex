defmodule Vutuv.SiteName do
  @moduledoc """
  What this installation calls itself (`:node_name`, `NODE_NAME`).

  The key already existed for the fediverse directory documents, and its config
  comment says an operator "should not have to answer it twice" — but sixteen
  places wrote `"vutuv"` out instead, so a third-party or intranet installation
  shipped link previews, schema.org markup, breadcrumbs and RSS channel titles
  naming somebody else's site, with no way to correct them but a source edit.

  This is the installation's *name*, not the software's: `Vutuv.NodeInfo`'s
  `software.name` stays the literal `"vutuv"`, because every installation runs
  the same software however it names itself. Copy that speaks **about vutuv the
  product** — the landing page's pitch, the media kit — is a third thing again
  and stays written out, since it is a claim about the project rather than a
  label for this site.
  """

  @doc "This installation's own name, e.g. \"vutuv\"."
  def get, do: Application.fetch_env!(:vutuv, :node_name)
end
