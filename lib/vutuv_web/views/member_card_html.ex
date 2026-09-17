defmodule VutuvWeb.MemberCardHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.PersonalNoteComponents

  alias Vutuv.Accounts.User
  alias Vutuv.Organizations.Organization
  alias Vutuv.PersonalNotes
  alias VutuvWeb.Markdown
  alias VutuvWeb.UserHelpers

  embed_templates("../templates/member_card/*")

  @doc """
  What the account says about itself, as one run of plain text: a member's
  tagline or the start of a page's description. Both are Markdown, and a card
  quoting three lines of them wants the words, not the markup.
  """
  def about(%User{headline: text}), do: text |> UserHelpers.headline_text() |> blank_to_nil()

  # A description runs to 10,000 characters; three lines of it need the first
  # few hundred, so the Markdown pipeline only sees those.
  def about(%Organization{description: text}),
    do: (text || "") |> String.slice(0, 600) |> Markdown.to_preview_line() |> blank_to_nil()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  @doc "The card's way to the account's own page."
  def page_label(%User{}, true), do: gettext("Your profile")
  def page_label(%User{}, false), do: gettext("Their profile")
  def page_label(%Organization{}, _self?), do: gettext("Their page")
end
