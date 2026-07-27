defmodule VutuvWeb.PageHTML do
  @moduledoc false
  use VutuvWeb, :html

  # The sign-up form's email-type radios: the values and their order come from
  # the schema, the labels from the same helper the email pages use, so all
  # three renderings of Personal/Work/Other stay in step.
  import VutuvWeb.EmailHTML, only: [email_type_label: 1]

  alias Vutuv.Accounts.Email

  embed_templates("../templates/page/*")

  @doc """
  The founder quote at the top of the logged-out landing page, in the variant
  this visitor was assigned (`Vutuv.Experiments`).

  Both are one short question plus an answer, so the hero's typography holds
  either. An unknown key falls back to the default variant, which is what an
  installation with the split test switched off always renders.
  """
  def founder_quote("knapp") do
    gettext("“LinkedIn is annoying. vutuv is not.”")
  end

  def founder_quote(_stube) do
    gettext("“Tired of LinkedIn? Then come on in and make yourself at home.”")
  end
end
