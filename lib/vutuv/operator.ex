defmodule Vutuv.Operator do
  @moduledoc """
  How a human reaches whoever runs *this* installation.

  `:operator_recipient` (OPERATOR_NAME / OPERATOR_EMAIL) is the person behind
  the site and their address. It is already the public answer in three places —
  `security.txt`, the NodeInfo maintainer and the Mastodon API's instance
  contact — and it is what the operator notices (daily report, ad bookings,
  deletion records) are addressed to.

  It has one home here because it had seven, each destructuring the tuple
  itself. The error pages made that worth fixing: they are the one surface
  where a *visitor* is sent to that address, so the name has to be readable
  text and the address a `mailto:`, two shapes of the same setting that do not
  belong in a template.

  **Every function here is named `contact_*` on purpose.** The operator-identity
  block in `config/config.exs` also holds `:operator_name`, and it is a
  different string: "Wintermeyer Consulting" (the footer credit, the company)
  against this pair's "Stefan Wintermeyer" (the person who answers). The media
  kit prints both side by side, so they are two facts and not one. A bare
  `name/0` here would hand the next author the wrong one of the two.
  """

  alias Vutuv.Mailto

  @doc "The `{name, address}` pair, for anything that addresses an email."
  def recipient, do: Application.fetch_env!(:vutuv, :operator_recipient)

  @doc "The name of the person to write to, as a reader should see it."
  def contact_name, do: elem(recipient(), 0)

  @doc "The address to write to."
  def contact_email, do: elem(recipient(), 1)

  @doc "A `mailto:` for that address, optionally with a prefilled subject."
  def contact_mailto(subject \\ nil), do: Mailto.to(contact_email(), subject)
end
