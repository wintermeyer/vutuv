defmodule VutuvWeb.AgentDocs.JSON do
  @moduledoc """
  Renders an agent doc (see `VutuvWeb.AgentDocs`) as a flat,
  self-describing JSON document — no API envelope. The doc map is already
  JSON-shaped; only renderer-internal keys are dropped.
  """

  # :noindex/:noai steer the Content-Signal header, :vcard_photo is
  # vCard-only payload — none of them belongs in the serialized document.
  # When a caller *wants* the consent flags in-band (the API does), it
  # re-surfaces them under their public names via expose_consent/1 below.
  @internal_keys [:noindex, :noai, :vcard_photo]

  def render(doc) do
    doc
    |> Map.drop(@internal_keys)
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  @doc """
  Re-surfaces the dropped consent flags under their public `PATCH /me`
  param names (`noindex?`/`noai?`). The extension URLs carry the member's
  choice as Content-Signal/X-Robots-Tag headers and keep the body clean;
  `/api/2.0` consumers read bodies, so the API serves profile docs through
  this — a client that feeds profiles into an LLM must skip members with
  `"noai?": true`.
  """
  def expose_consent(doc) do
    Map.merge(doc, %{noindex?: doc.noindex, noai?: doc.noai})
  end
end
