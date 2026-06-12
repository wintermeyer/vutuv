defmodule VutuvWeb.AgentDocs.JSON do
  @moduledoc """
  Renders an agent doc (see `VutuvWeb.AgentDocs`) as a flat,
  self-describing JSON document — no API envelope. The doc map is already
  JSON-shaped; only renderer-internal keys are dropped.
  """

  # :noindex/:noai steer the Content-Signal header, :vcard_photo is
  # vCard-only payload — none of them belongs in the serialized document.
  @internal_keys [:noindex, :noai, :vcard_photo]

  def render(doc) do
    doc
    |> Map.drop(@internal_keys)
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end
end
