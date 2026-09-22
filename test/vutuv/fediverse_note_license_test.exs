defmodule Vutuv.FediverseNoteLicenseTest do
  @moduledoc """
  A photo post's license travels with its Note twice: as a closing line of the
  content for Mastodon, and as `license` on each photo attachment for
  Pixelfed (see docs/architecture/fediverse.md). The added words follow the
  post's language, not the locale of the process that builds the Note.
  """

  use Vutuv.DataCase

  alias Vutuv.Posts
  alias Vutuv.Posts.PhotoLicense
  alias Vutuv.Repo
  alias VutuvWeb.Fediverse.Docs

  setup do
    %{user: insert_activated_user(fediverse_followers?: true)}
  end

  defp note(post, user), do: post |> Repo.preload(Docs.note_preloads()) |> Docs.note(user)

  defp photo_note(user, attrs) do
    image = insert(:post_image, user: user)

    {:ok, post} =
      Posts.create_post(user, Map.merge(%{body: "Look", image_ids: [image.id]}, attrs))

    note(post, user)
  end

  test "a CC photo post names its license in the content and on the attachment", %{user: user} do
    note = photo_note(user, %{license: "cc-by-4.0", language: "en"})

    assert note["content"] =~
             ~s{<p>Photos: <a href="https://creativecommons.org/licenses/by/4.0/" rel="license">CC BY 4.0 (reuse with credit)</a></p>}

    assert [%{"license" => "CC BY"}] = note["attachment"]
  end

  test "each license maps to the title Pixelfed matches" do
    assert PhotoLicense.pixelfed("cc-by-sa-4.0") == "CC BY-SA"
    assert PhotoLicense.pixelfed("cc-by-nc-4.0") == "CC BY-NC"
    assert PhotoLicense.pixelfed("cc0-1.0") == "Public Domain (CC0)"
    assert PhotoLicense.pixelfed("arr") == nil
  end

  test "all rights reserved adds nothing, as on the permalink", %{user: user} do
    note = photo_note(user, %{license: "arr"})

    refute note["content"] =~ "rel=\"license\""
    assert [attachment] = note["attachment"]
    refute Map.has_key?(attachment, "license")
  end

  test "a post without photos carries no license line", %{user: user} do
    {:ok, post} = Posts.create_post(user, %{body: "Just words", license: "cc-by-4.0"})

    refute note(post, user)["content"] =~ "rel=\"license\""
  end

  test "the line is written in the post's language, whatever the process locale", %{user: user} do
    note =
      Gettext.with_locale(VutuvWeb.Gettext, "en", fn ->
        photo_note(user, %{license: "cc-by-4.0", language: "de"})
      end)

    assert note["content"] =~ "<p>Fotos: <a"
    assert note["content"] =~ "CC BY 4.0 (Weitergabe mit Namensnennung)</a>"
  end

  test "a review line is written in the post's language too", %{user: user} do
    {:ok, post} =
      Posts.create_post(user, %{
        body: "Starker Film.",
        language: "de",
        review: %{"kind" => "movie", "identifier" => "tt0111161", "title" => "Die Verurteilten"}
      })

    content = Gettext.with_locale(VutuvWeb.Gettext, "en", fn -> note(post, user)["content"] end)

    assert content =~ "Filmbesprechung"
    refute content =~ "Film review"
  end
end
