defmodule VutuvWeb.FeedLanguageChipsTest do
  @moduledoc """
  The Feed-languages card on /settings/preferences (issue #1537): the languages
  a member reads, as chips, instead of a grid of every curated language with all
  sixty-odd boxes ticked. The load-bearing assertions:

    * the suggestion (interface language + the profile's language skills) decides
      which chips sit in the **open**, and ticks nothing — a pre-ticked
      suggestion would ride along the next save of the neighbouring select and
      leave the member with a language filter they never chose
    * what is ticked is the stored choice, read from the changeset, so a failed
      save keeps what they just picked
    * saving with no chip means "all languages" again (the changeset maps [] to
      nil)
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Accounts
  alias Vutuv.Posts
  alias Vutuv.Profiles.Language

  defp chip(html, code) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s|input[name="user[feed_languages][]"][value="#{code}"]|)
    |> Enum.to_list()
  end

  defp chip_checked?(html, code) do
    case chip(html, code) do
      [input] -> LazyHTML.attribute(input, "checked") != []
      [] -> false
    end
  end

  defp chip_present?(html, code), do: chip(html, code) != []

  # The chips in the open, i.e. outside the <details> disclosure.
  defp chips_in_the_open(html) do
    doc = LazyHTML.from_document(html)
    all = doc |> LazyHTML.query(~s|input[name="user[feed_languages][]"]|) |> attr_values()

    folded =
      doc
      |> LazyHTML.query(~s|details input[name="user[feed_languages][]"]|)
      |> attr_values()

    all -- folded
  end

  defp attr_values(nodes) do
    nodes |> Enum.to_list() |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))
  end

  describe "suggested_feed_languages/1" do
    test "answers the interface language plus the profile's language skills" do
      user = insert(:user, locale: "de", feed_languages: nil)
      Repo.insert!(%Language{user_id: user.id, language_code: "fr", proficiency: "c2"})

      suggested = Posts.suggested_feed_languages(user)

      assert "de" in suggested
      assert "fr" in suggested
    end

    test "is a suggestion, not the stored choice — it answers the same either way" do
      user = insert(:user, locale: "de", feed_languages: ["en"])

      assert Posts.suggested_feed_languages(user) == ["de"]
    end

    test "only curated codes, no duplicates" do
      user = insert(:user, locale: "de", feed_languages: nil)
      Repo.insert!(%Language{user_id: user.id, language_code: "de", proficiency: "native"})

      assert Posts.suggested_feed_languages(user) == ["de"]
    end
  end

  describe "the card" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, conn: conn, user: user}
    end

    test "puts the member's own languages in the open and ticks none of them", %{
      conn: conn,
      user: user
    } do
      {:ok, _user} = Accounts.update_user(user, %{"locale" => "de"})
      Repo.insert!(%Language{user_id: user.id, language_code: "fr", proficiency: "c2"})

      html = conn |> get(~p"/settings/preferences") |> html_response(200)

      open = chips_in_the_open(html)
      assert "de" in open
      assert "fr" in open
      refute "ja" in open

      # Nothing is ticked: the suggestion must not become a filter by riding
      # along a save of the select beside it.
      refute chip_checked?(html, "de")
      refute chip_checked?(html, "fr")
      # The rest are still reachable, just folded away.
      assert chip_present?(html, "ja")
      assert html =~ "data-language-more"

      # The German wording, by name: `gettext.extract --merge` fuzzy-filled
      # "Add another language" with "Weiteren Tag hinzufügen" (another *tag*),
      # and nothing in the build would have failed on it.
      assert html =~ "Diese Sprachen lese ich"
      assert html =~ "Weitere Sprache hinzufügen"
      assert html =~ "Keine Auswahl bedeutet: alle Sprachen."
    end

    test "the stored choice is what shows as ticked, and it sits in the open", %{
      conn: conn,
      user: user
    } do
      {:ok, _user} = Accounts.update_user(user, %{"feed_languages" => ["en", "it"]})

      html = conn |> get(~p"/settings/preferences") |> html_response(200)

      assert chip_checked?(html, "en")
      assert chip_checked?(html, "it")
      refute chip_checked?(html, "de")

      open = chips_in_the_open(html)
      assert "en" in open
      assert "it" in open
    end

    test "clearing every chip means all languages again", %{conn: conn, user: user} do
      {:ok, _user} = Accounts.update_user(user, %{"feed_languages" => ["de"]})

      put(conn, ~p"/settings/feed_languages", %{"user" => %{"feed_foreign_posts" => "original"}})

      assert Accounts.get_user(user.id).feed_languages == nil
    end
  end
end
