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
  Splits a translated string on a `{marker}` placeholder into `{before, after}`,
  so the landing-page consent line can drop a link where the placeholder sits.

  Deliberately **total**: `parts: 2` collapses a doubled placeholder (a botched
  translation) to one split, and a missing placeholder returns `{text, ""}`.
  This is the landing page - the first thing every logged-out visitor sees - so
  a malformed translation must render slightly wrong text, never a 500. A hard
  `[a, b] = String.split(...)` here 500ed vutuv.de for every German visitor when
  a `.po` merge duplicated the German consent sentence (two placeholders where
  the code expected one); `page_locale_render_test.exs` guards against it.
  """
  def split_marker(text, marker) do
    case String.split(text, marker, parts: 2) do
      [before, rest] -> {before, rest}
      [whole] -> {whole, ""}
    end
  end
end
