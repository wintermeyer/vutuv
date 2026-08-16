defmodule Vutuv.TranslationsTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Translations
  alias Vutuv.Translations.Translation
  alias Vutuv.Translations.TranslationJob

  defp post!(attrs \\ []) do
    insert(:post, Keyword.merge([body: "Guten Morgen allerseits."], attrs))
  end

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
          content_text: "Bonjour tout le monde.",
          audience: "public",
          kind: "note",
          published_at: now,
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        attrs
      )
    )
  end

  defp note!(post, attrs \\ %{}) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct!(
        %Note{
          post_id: post.id,
          object_uri: "https://social.example/n/#{System.unique_integer([:positive])}",
          actor_uri: "https://social.example/users/them",
          handle: "them@social.example",
          content_text: "Une réponse.",
          audience: "public",
          received_at: now,
          checked_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        attrs
      )
    )
  end

  describe "normalize_language/1" do
    test "keeps a bare primary subtag, lowercased" do
      assert Translations.normalize_language("de") == "de"
      assert Translations.normalize_language("EN") == "en"
      assert Translations.normalize_language("und") == "und"
    end

    test "reduces a full BCP47 tag to its primary subtag" do
      assert Translations.normalize_language("de-AT") == "de"
      assert Translations.normalize_language("pt_BR") == "pt"
      assert Translations.normalize_language(" en-US ") == "en"
    end

    test "answers nil for garbage, so hostile inbound tags never reach a column" do
      assert Translations.normalize_language("") == nil
      assert Translations.normalize_language("x") == nil
      assert Translations.normalize_language("deutsch") == nil
      assert Translations.normalize_language("<script>") == nil
      assert Translations.normalize_language(nil) == nil
      assert Translations.normalize_language(%{"weird" => true}) == nil
    end
  end

  describe "the subject triple" do
    test "each subject kind stores in its own column and reads back via subject/1" do
      post = post!()
      remote = remote_post!()
      note = note!(post)

      for subject <- [post, remote, note] do
        assert {:queued, %TranslationJob{} = job} = Translations.request(subject, "en")
        assert Translations.subject(job) == expected_subject(subject)
        assert Translations.load_subject(job).id == subject.id
      end
    end

    test "the CHECK refuses a row without exactly one subject" do
      post = post!()
      remote = remote_post!()

      assert_raise Ecto.ConstraintError, ~r/exactly_one_subject/, fn ->
        Repo.insert!(%TranslationJob{target_language: "en"})
      end

      assert_raise Ecto.ConstraintError, ~r/exactly_one_subject/, fn ->
        Repo.insert!(%TranslationJob{
          post_id: post.id,
          remote_post_id: remote.id,
          target_language: "en"
        })
      end
    end
  end

  describe "request/2 and the job queue" do
    test "queues one job and dedupes the second request onto the same open row" do
      post = post!()

      assert {:queued, %TranslationJob{id: id, status: "pending"}} =
               Translations.request(post, "en")

      assert {:queued, %TranslationJob{id: ^id}} = Translations.request(post, "en")
      assert Repo.aggregate(TranslationJob, :count) == 1
    end

    test "a different target language is separate work" do
      post = post!()

      assert {:queued, %TranslationJob{id: en_id}} = Translations.request(post, "en")
      assert {:queued, %TranslationJob{id: fr_id}} = Translations.request(post, "fr")
      assert en_id != fr_id
    end

    test "a resolved job does not block a fresh request" do
      post = post!()
      {:queued, job} = Translations.request(post, "en")
      Repo.update_all(TranslationJob, set: [status: "failed"])

      assert {:queued, %TranslationJob{id: new_id, status: "pending"}} =
               Translations.request(post, "en")

      assert new_id != job.id
    end

    test "jobs die with their subject" do
      post = post!()
      {:queued, _job} = Translations.request(post, "en")

      Repo.delete!(post)
      assert Repo.aggregate(TranslationJob, :count) == 0
    end
  end

  describe "the translation cache" do
    test "store_translation then request answers from the cache" do
      post = post!()

      assert {:ok, %Translation{} = stored} =
               Translations.store_translation(post, "en", %{
                 source_language: "de",
                 body: "Good morning everyone.",
                 model: "gemma4:31b"
               })

      assert {:cached, %Translation{id: id}} = Translations.request(post, "en")
      assert id == stored.id
      assert Repo.aggregate(TranslationJob, :count) == 0
    end

    test "an edited source makes the cached row stale and re-queues" do
      post = post!()

      {:ok, _} =
        Translations.store_translation(post, "en", %{body: "Good morning.", model: "m"})

      edited = %{post | body: "Guten Abend allerseits."}

      assert Translations.fresh_translation(edited, "en") == nil
      assert {:queued, %TranslationJob{}} = Translations.request(edited, "en")
    end

    test "re-storing after an edit replaces the row in place" do
      post = post!()
      {:ok, first} = Translations.store_translation(post, "en", %{body: "One.", model: "m"})

      edited = %{post | body: "Zwei."}
      {:ok, _second} = Translations.store_translation(edited, "en", %{body: "Two.", model: "m"})

      assert Repo.aggregate(Translation, :count) == 1
      assert Repo.get!(Translation, first.id).body == "Two."
      assert Translations.fresh_translation(edited, "en").body == "Two."
    end

    test "a remote subject's summary is part of the cache key and the result" do
      remote = remote_post!(%{summary: "CW: Politik"})

      {:ok, stored} =
        Translations.store_translation(remote, "en", %{
          source_language: "fr",
          body: "Hello everyone.",
          summary: "CW: politics",
          model: "m"
        })

      assert stored.summary == "CW: politics"
      assert Translations.fresh_translation(remote, "en").id == stored.id

      # The same body under an edited content warning is a different source.
      assert Translations.fresh_translation(%{remote | summary: "CW: anders"}, "en") == nil
    end

    test "translations die with their subject" do
      post = post!()
      {:ok, _} = Translations.store_translation(post, "en", %{body: "X.", model: "m"})

      Repo.delete!(post)
      assert Repo.aggregate(Translation, :count) == 0
    end
  end

  defp expected_subject(%Vutuv.Posts.Post{id: id}), do: {:post, id}
  defp expected_subject(%RemotePost{id: id}), do: {:remote_post, id}
  defp expected_subject(%Note{id: id}), do: {:note, id}
end
