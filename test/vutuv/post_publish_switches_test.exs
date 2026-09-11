defmodule Vutuv.PostPublishSwitchesTest do
  @moduledoc """
  The two answers a post carries out of the composer (issue #2107).

  The first — *may search engines and AI see this post* — is the sharp one:
  a post that says no is not handed to the Fediverse **at all**, because a
  remote server keeps its copy for ever and no `X-Robots-Tag` reaches it.
  Every outbound path is asserted here, not only the Create, because a post
  withheld from its author's followers and then announced by a topic actor
  would have left anyway.

  The second — *remove the metadata from the files* — is a `qpdf` run on the
  **served** copy only. The private original is the promise that what the
  member sent is kept exactly as they sent it, and the tests read both files.
  """

  use Vutuv.DataCase, async: false

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Attachments.Metadata
  alias Vutuv.AttachmentStore
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Posts
  alias Vutuv.Posts.Pending
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Tags.Timeline
  alias VutuvWeb.AgentDocs.PostDoc

  # An admin (the milestone's `ATTACHMENT_UPLOADERS` default) with an uploads
  # root of its own, shared by the two describes that put real bytes on disk.
  defp uploading_admin(_context) do
    %{files: files} = Fixtures.tmp_uploads_dir()
    %{user: insert_activated_user(admin?: true), files: files}
  end

  defp federated_user(attrs \\ []) do
    insert(:activated_user, Keyword.merge([fediverse_followers?: true], attrs))
  end

  defp with_follower(user) do
    {:ok, _actor} = Fediverse.ensure_actor(user)

    {:ok, _} =
      Fediverse.add_follower(user, %{
        actor_uri: "https://social.example/users/alice",
        inbox_uri: "https://social.example/inbox"
      })

    user
  end

  describe "machines_allowed?/1" do
    test "a post says yes unless its author turned the switch off" do
      assert Posts.machines_allowed?(%Post{noindex_noai?: false})
      refute Posts.machines_allowed?(%Post{noindex_noai?: true})
    end

    test "the column defaults to no-opt-out, so every post written so far still counts" do
      assert %Post{noindex_noai?: false, strip_metadata?: true} = insert(:post)
    end
  end

  describe "a post that says no search engines and no AI" do
    test "is not delivered to the author's remote followers" do
      user = with_follower(federated_user())

      blocked = insert(:post, user: user, body: "Nur hier", noindex_noai?: true)

      assert :skip == Fediverse.federate_new_post(blocked)
      assert Repo.aggregate(Delivery, :count) == 0

      # Calibration in the same test: the only thing different about the next
      # post is the answer, and it goes out.
      open = insert(:post, user: user, body: "Überall")
      assert :ok == Fediverse.federate_new_post(open)
      assert Repo.aggregate(Delivery, :count) == 1
    end

    test "is not announced by the topic actors either" do
      user = federated_user()
      tag = insert(:tag, name: "Elixir", slug: "elixir")

      {:ok, _} =
        Fediverse.add_tag_follower(tag, %{
          actor_uri: "https://social.example/users/bob",
          inbox_uri: "https://social.example/inbox-b"
        })

      # Driven through the real publish path, which announces by itself. The
      # author has no followers of their own, so every delivery here is the
      # topic actor's.
      {:ok, _blocked} =
        Posts.create_post(user, %{
          body: "Neues von hier.",
          tags: tag.name,
          noindex_noai: "true"
        })

      assert Repo.aggregate(Delivery, :count) == 0

      # Calibration in the same test: the same post without the switch is
      # announced.
      {:ok, _open} = Posts.create_post(user, %{body: "Und noch mehr.", tags: tag.name})

      assert Repo.aggregate(Delivery, :count) == 1
    end

    test "is not reshared out either, however public the resharer is" do
      author = with_follower(federated_user())
      resharer = with_follower(federated_user())

      post = insert(:post, user: author, noindex_noai?: true)

      assert :skip == Fediverse.federate_repost(post, resharer)
      assert Repo.aggregate(Delivery, :count) == 0
    end

    test "is not put into the featured collection when it is pinned" do
      user = with_follower(federated_user())
      post = insert(:post, user: user, noindex_noai?: true)

      assert :skip == Fediverse.federate_pin(post, user)
      assert Repo.aggregate(Delivery, :count) == 0
      assert Fediverse.featured_posts(%{user | pinned_post_id: post.id}) == []
    end

    test "is left out of the site-wide feed, which cannot signal per item" do
      author = insert(:activated_user, noindex?: false, noai?: false)

      open = insert(:post, user: author)
      _blocked = insert(:post, user: author, noindex_noai?: true)

      ids = :all |> Posts.recent_public_posts() |> Enum.map(& &1.id)

      assert ids == [open.id]
    end

    test "is quoted on no shared listing surface, in any format" do
      # Measured on the un-fixed branch over HTTP: the 200-character excerpt
      # went out on `/<slug>/posts.md|.txt|.json`, on every tag page's four
      # formats, on `/system/posts/<y>/<m>/<d>` and on `/api/2.0/users/:slug/
      # posts`, each under `Content-Signal: ai-train=yes, search=yes` and with
      # no `X-Robots-Tag` at all. Those documents are the machine surface and
      # cannot signal per row, so the words had to go rather than the signal.
      author = insert(:activated_user, noindex?: false, noai?: false)
      tag = insert(:tag, name: "Zurueckgehalten", slug: "zurueckgehalten")

      {:ok, open} = Posts.create_post(author, %{body: "Ganz offen", tags: tag.name})

      {:ok, blocked} =
        Posts.create_post(author, %{
          body: "Geheime Preisliste",
          tags: tag.name,
          noindex_noai: "true"
        })

      # The public archive drops it, so its `.md`/`.json`/`.xml` siblings and
      # `/api/2.0/users/:slug/posts` never see it.
      archive =
        PostDoc.build_archive(author, "/#{author.username}/posts", entries(author), 1, nil)

      assert Enum.map(archive.posts, & &1.id) == [open.id]

      # And the shared row builder withholds the words anywhere a withheld post
      # still reaches a list — the reader's own feed document, a conversation
      # folded into a row — rather than relying on every caller to filter.
      assert %{excerpt: "Post not open to search engines"} =
               PostDoc.timeline_entry(%{post: Repo.reload!(blocked)})

      # The tag page drops it outright — a public topic surface with no owner
      # to make an exception for.
      tag_ids =
        tag |> Timeline.page() |> Map.fetch!(:entries) |> Enum.map(& &1.post.id)

      assert tag_ids == [open.id]
    end

    test "is out of the author's public archive but stays in their own" do
      author = insert(:activated_user)
      {:ok, open} = Posts.create_post(author, %{body: "Offen"})
      {:ok, blocked} = Posts.create_post(author, %{body: "Nur hier", noindex_noai: "true"})

      anonymous = author |> Posts.author_posts_page(nil, %{}) |> ids()
      own = author |> Posts.author_posts_page(author, %{}) |> ids()

      assert anonymous == [open.id]
      assert Enum.sort(own) == Enum.sort([open.id, blocked.id])
    end

    defp entries(author), do: author |> Posts.author_posts_page(nil, %{}) |> elem(0)

    defp ids({entries, _total}), do: entries |> Enum.map(& &1.post.id) |> Enum.sort()

    test "carries noindex and noai on its permalink and its agent formats" do
      author = insert(:activated_user, noindex?: false, noai?: false)
      post = insert(:post, user: author, noindex_noai?: true)

      assert {true, true} = PostDoc.robots_axes(author, post, false)
    end

    test "is out of the outbox count too, not only out of the notes it counts" do
      user = federated_user()
      _open = insert(:post, user: user)
      _blocked = insert(:post, user: user, noindex_noai?: true)

      assert Fediverse.public_post_count(user) == 1
    end

    test "is called back when the switch is turned on after it went out" do
      user = with_follower(federated_user())
      post = insert(:post, user: user, body: "Erst öffentlich")

      assert :ok == Fediverse.federate_new_post(post)
      Repo.delete_all(Delivery)

      {:ok, post} = Posts.update_post(post, %{body: post.body, noindex_noai: "true"})
      assert %Post{noindex_noai?: true} = post

      # A Delete, not silence: what already left has to be called back, and
      # `:skip` would have left the remote copies standing while the row said
      # the author had refused them.
      assert [delivery] = Repo.all(Delivery)
      assert delivery.activity_json =~ ~s("type":"Delete")
    end
  end

  describe "removing the metadata from a file" do
    setup :uploading_admin

    test "the served copy loses the author, the software and the dates", %{
      user: user,
      files: files
    } do
      if Metadata.available?() do
        source = Fixtures.metadata_pdf(files)
        assert {:ok, attachment} = Attachments.create_pending(user, source, "preise.pdf")

        served = File.read!(AttachmentStore.served_path(attachment.token))
        refute served =~ "Erika Mustermann"
        refute served =~ "SecretWriter"

        # The private original is the promise that what the member sent is
        # kept exactly as they sent it.
        assert File.read!(AttachmentStore.original_path(attachment.token)) == File.read!(source)
        assert attachment.metadata_stripped_at
      end
    end

    test "a text file is left alone — there is nothing to strip", %{user: user, files: files} do
      source = Path.join(files, "notiz.txt")
      File.write!(source, "nur Worte\n")

      assert {:ok, attachment} = Attachments.create_pending(user, source, "notiz.txt")
      assert attachment.metadata_stripped_at == nil
      assert File.read!(AttachmentStore.served_path(attachment.token)) == "nur Worte\n"
    end

    test "the author saying no puts the verbatim upload back on the served copy", %{
      user: user,
      files: files
    } do
      if Metadata.available?() do
        source = Fixtures.metadata_pdf(files)
        {:ok, attachment} = Attachments.create_pending(user, source, "preise.pdf")

        {:ok, post} =
          Posts.create_post(user, %{
            body: "Mit Metadaten",
            attachment_ids: [attachment.id],
            strip_metadata: "false"
          })

        assert %Post{strip_metadata?: false} = post
        assert File.read!(AttachmentStore.served_path(attachment.token)) == File.read!(source)
        assert Repo.reload!(attachment).metadata_stripped_at == nil

        # …and turning it back on cleans the file after all. Answering only the
        # first direction left the row claiming the metadata was gone while the
        # bytes still carried the author's name.
        {:ok, _} = Posts.update_post(post, %{body: post.body, strip_metadata: "true"})

        refute File.read!(AttachmentStore.served_path(attachment.token)) =~
                 Fixtures.metadata_author()

        assert Repo.reload!(attachment).metadata_stripped_at
      end
    end

    test "an atom-keyed false is an answer, not an absent key", %{user: user, files: files} do
      # `fetch/2` joined the two key shapes with `||`, which cannot carry a
      # `false` — so the composer, which builds atom-keyed attrs, had its "keep
      # my metadata" silently read as "the caller said nothing" and the post
      # stored the default. It survived only on the parked path, where the
      # attrs round-trip through JSONB into string keys.
      {:ok, file} = Attachments.create_pending(user, Fixtures.plain_pdf(files), "a.pdf")

      {:ok, post} =
        Posts.create_post(user, %{
          body: "Atomschlüssel",
          attachment_ids: [file.id],
          strip_metadata: false,
          noindex_noai: false
        })

      assert %Post{strip_metadata?: false, noindex_noai?: false} = post
    end

    test "without qpdf on the box nothing is stripped and nothing fails", %{
      user: user,
      files: files
    } do
      Fixtures.put_config(qpdf: "vutuv-no-such-qpdf")
      Metadata.forget_capability()
      on_exit(&Metadata.forget_capability/0)

      refute Metadata.available?()

      source = Fixtures.metadata_pdf(files)
      assert {:ok, attachment} = Attachments.create_pending(user, source, "preise.pdf")
      assert attachment.metadata_stripped_at == nil
      assert File.read!(AttachmentStore.served_path(attachment.token)) == File.read!(source)
    end

    test "a qpdf too old for the flags counts as no qpdf at all", %{user: user, files: files} do
      # Debian 12 ships qpdf 11.3.0 and Ubuntu 24.04 ships 11.9.0; both have the
      # binary and neither has `--remove-info`, which arrived in 11.10.0. A
      # probe that only asked whether the file exists left the switch visible
      # and inert on every one of those boxes — the run died with
      # `unrecognized argument` and the file kept the author's name.
      old = Path.join(files, "qpdf-11.9.0")

      File.write!(old, """
      #!/bin/sh
      case "$1" in
        --help=--remove-info|--help=--remove-metadata) echo "unknown option"; exit 2 ;;
        *) exit 0 ;;
      esac
      """)

      File.chmod!(old, 0o755)
      Fixtures.put_config(qpdf: old)
      Metadata.forget_capability()
      on_exit(&Metadata.forget_capability/0)

      refute Metadata.available?()

      source = Fixtures.metadata_pdf(files)
      assert {:ok, attachment} = Attachments.create_pending(user, source, "preise.pdf")
      assert attachment.metadata_stripped_at == nil
      assert File.read!(AttachmentStore.served_path(attachment.token)) == File.read!(source)
    end

    test "a qpdf that knows the flags is used", %{files: files} do
      new = Path.join(files, "qpdf-12.2.0")
      File.write!(new, "#!/bin/sh\nexit 0\n")
      File.chmod!(new, 0o755)
      Fixtures.put_config(qpdf: new)
      Metadata.forget_capability()
      on_exit(&Metadata.forget_capability/0)

      assert Metadata.available?()
    end
  end

  describe "the four corrections this PR folds in (blind review of #2106)" do
    setup :uploading_admin

    test "a refused file cannot be attached to a post", %{user: user, files: files} do
      {:ok, refused} =
        Attachments.create_pending(user, Fixtures.plain_pdf(files), "abgelehnt.pdf")

      {1, _} =
        Repo.update_all(
          from(a in Attachment, where: a.id == ^refused.id),
          set: [refused_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

      assert {:error, :invalid_attachments} =
               Posts.create_post(user, %{body: "Trotzdem", attachment_ids: [refused.id]})
    end

    test "publishing without the refused part is refused when nothing would be left", %{
      user: user,
      files: files
    } do
      {:ok, file} = Attachments.create_pending(user, Fixtures.plain_pdf(files), "allein.pdf")

      # A post whose only content is the file, and the file was refused: there
      # is nothing to publish, and the context has to say so rather than let
      # the create path answer with an opaque failure.
      {:ok, pending} =
        Pending.create(user, "post", %{}, %{body: ""}, attachments: [file])

      {1, _} =
        Repo.update_all(
          from(a in Attachment, where: a.id == ^file.id),
          set: [refused_at: DateTime.utc_now() |> DateTime.truncate(:second), stage: "ready"]
        )

      assert {:error, :nothing_left} = Pending.publish_without_refused(pending)
    end

    test "a file that failed to render is still publishable", %{user: user, files: files} do
      {:ok, failed} = Attachments.create_pending(user, Fixtures.plain_pdf(files), "kaputt.pdf")

      {1, _} =
        Repo.update_all(
          from(a in Attachment, where: a.id == ^failed.id),
          set: [stage: "failed"]
        )

      assert {:ok, %Post{}} =
               Posts.create_post(user, %{body: "Geht doch", attachment_ids: [failed.id]})
    end
  end
end
