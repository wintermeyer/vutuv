defmodule Vutuv.Translations.LanguageDetectionTest do
  @moduledoc """
  The language-detection sweep (issue #1535): filling the `language` column of
  the posts nobody declared one for, with an injected detector (the real Ollama
  client has its own test file). The load-bearing assertions:

    * a text the model cannot place is **stamped** and keeps `language` NULL —
      it leaves the work list instead of holding the front of every batch
      forever (the `refresh_counts` starvation lesson), and stays visible to
      every reader because NULL never hides
    * a service failure stamps **nothing** and stops the batch, so the row is
      due again once Ollama answers
    * the stamp does not touch `updated_at`, or every backfilled post would
      render as "edited" (`updated_at - inserted_at > 60`)
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Translations

  defp undeclared_post!(body \\ "Ein ganz gewöhnlicher deutscher Satz."),
    do: insert(:post, body: body, language: nil)

  defp remote_post!(attrs \\ %{}) do
    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: "https://social.example/users/u#{System.unique_integer([:positive])}",
        host: "social.example",
        handle: "them",
        inbox_uri: "https://social.example/inbox"
      })

    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct!(
        %RemotePost{
          remote_account_id: account.id,
          object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
          audience: "public",
          kind: "note",
          content_text: "Un texte tout à fait ordinaire.",
          published_at: now,
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        attrs
      )
    )
  end

  # A remote reply hangs off the local post it answers (`post_id` is NOT NULL).
  defp note!(attrs \\ %{}) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct!(
        %Note{
          # Declared, so the post this reply hangs off is not itself due.
          post_id:
            insert(:post, body: "Der Beitrag, auf den geantwortet wurde.", language: "de").id,
          object_uri: "https://social.example/n/#{System.unique_integer([:positive])}",
          actor_uri: "https://social.example/users/them",
          audience: "public",
          content_text: "Una risposta del tutto normale.",
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        attrs
      )
    )
  end

  defp detector(answer), do: fn _subject -> answer end

  defp undetermined, do: detector({:error, {:content, :undetermined}})

  defp language_of(%schema{id: id}) do
    Repo.one!(from(r in schema, where: r.id == ^id, select: {r.language, r.language_checked_at}))
  end

  describe "due_for_detection/1" do
    test "lists exactly the rows with no language and no stamp" do
      undeclared = undeclared_post!()
      declared = insert(:post, body: "Declared.", language: "de")

      keys = Enum.map(Translations.due_for_detection(50), &Translations.subject_key/1)

      assert Translations.subject_key(undeclared) in keys
      refute Translations.subject_key(declared) in keys
    end

    test "covers all three subject kinds" do
      post = undeclared_post!()
      remote = remote_post!()
      note = note!()

      keys = Enum.map(Translations.due_for_detection(50), &Translations.subject_key/1)

      for subject <- [post, remote, note], do: assert(Translations.subject_key(subject) in keys)
    end

    test "hands out the newest first — a fresh post's language is wanted while it is in the feed" do
      older = undeclared_post!()
      newer = undeclared_post!()

      assert [first, second | _] =
               Translations.due_for_detection(2) |> Enum.map(&Translations.subject_key/1)

      assert first == Translations.subject_key(newer)
      assert second == Translations.subject_key(older)
    end
  end

  describe "detect_due/1" do
    test "stores the detected language and stamps the row" do
      post = undeclared_post!()

      assert {:ok, 1} =
               Translations.detect_due(force: true, limit: 1, detect: detector({:ok, "de"}))

      assert {"de", %DateTime{}} = language_of(post)
      assert Translations.due_for_detection(50) == []
    end

    test "a remote post and a remote reply are filled the same way" do
      remote = remote_post!()
      note = note!()

      assert {:ok, 2} =
               Translations.detect_due(force: true, limit: 2, detect: detector({:ok, "fr"}))

      assert {"fr", %DateTime{}} = language_of(remote)
      assert {"fr", %DateTime{}} = language_of(note)
    end

    test "an unplaceable text keeps NULL, is stamped, and leaves the work list" do
      post = undeclared_post!("https://example.com")

      assert {:ok, 1} = Translations.detect_due(force: true, limit: 1, detect: undetermined())

      # NULL, so it stays visible to everyone and is never auto-translated.
      assert {nil, %DateTime{}} = language_of(post)
      # And gone from the work list — calibrate by clearing the stamp again:
      # without it the row would be back at the front of every batch forever.
      assert Translations.due_for_detection(50) == []

      {1, _} =
        Repo.update_all(from(p in Post, where: p.id == ^post.id),
          set: [language_checked_at: nil]
        )

      assert [%Post{}] = Translations.due_for_detection(50)
    end

    test "a service failure stamps nothing and stops the batch" do
      first = undeclared_post!()
      second = undeclared_post!()

      assert {:paused, 0} =
               Translations.detect_due(
                 force: true,
                 limit: 2,
                 detect: detector({:error, {:service, :timeout}})
               )

      assert {nil, nil} = language_of(first)
      assert {nil, nil} = language_of(second)
      assert length(Translations.due_for_detection(50)) == 2
    end

    test "the stamp does not make a backfilled post look edited" do
      post = undeclared_post!()

      assert {:ok, 1} =
               Translations.detect_due(force: true, limit: 1, detect: detector({:ok, "de"}))

      reloaded = Repo.reload!(post)
      assert NaiveDateTime.diff(reloaded.updated_at, reloaded.inserted_at) <= 60
    end

    test "an unplaceable text is re-examined once its body is edited" do
      post = undeclared_post!("https://example.com")
      {:ok, 1} = Translations.detect_due(force: true, limit: 1, detect: undetermined())

      assert Translations.due_for_detection(50) == []

      # The author writes real words under the link: the stamp says we looked
      # at a text that no longer exists, so the row is due again. Reload first —
      # the stamp was written straight to the column, so the struct in hand
      # still shows the pre-detection state (every real edit path re-reads the
      # row: `Posts.get_post/1`, `Repo.get_by(RemotePost, object_uri: …)`).
      {:ok, _post} =
        post
        |> Repo.reload!()
        |> Posts.update_post(%{body: "https://example.com — dazu ein ganzer deutscher Satz."})

      assert [%Post{}] = Translations.due_for_detection(50)
    end

    # The remote half of the same trap, and the one that would really have hurt:
    # most origins send no `contentMap`, so an ordinary edit (a content warning
    # added, a poll tick) re-writes `language` as nil — with the stamp left
    # behind, the post we had just placed would have been undeclared forever.
    test "a remote edit that declares no language puts the post back in the work list" do
      remote = remote_post!()
      {:ok, 1} = Translations.detect_due(force: true, limit: 1, detect: detector({:ok, "fr"}))
      assert {"fr", %DateTime{}} = language_of(remote)

      {:ok, _remote} =
        remote
        |> Repo.reload!()
        |> RemotePost.changeset(%{content_text: "Un texte modifié.", language: nil})
        |> Repo.update()

      assert {nil, nil} = language_of(remote)
      assert [%RemotePost{}] = Translations.due_for_detection(50)
    end

    test "a detected language reaches the reader's language filter" do
      post = undeclared_post!()
      german_reader = %User{feed_languages: ["de"], feed_foreign_posts: "hide"}

      # Undeclared, so it shows: NULL never hides.
      assert Posts.language_visible?(post.language, Posts.feed_language_filter(german_reader))

      {:ok, 1} = Translations.detect_due(force: true, limit: 1, detect: detector({:ok, "fr"}))

      refute Posts.language_visible?(
               Repo.reload!(post).language,
               Posts.feed_language_filter(german_reader)
             )
    end
  end
end
