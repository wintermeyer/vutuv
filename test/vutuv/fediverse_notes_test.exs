defmodule Vutuv.FediverseNotesTest do
  @moduledoc """
  Replies written on other networks under a member's post (issues #1069 and
  #1071): the first content vutuv stores that its own members did not write.

  async: false — the inbound caps (issue #1067) and the report rate limit live
  in the shared `Vutuv.RateLimiter` ETS table, which the SQL sandbox does not
  roll back.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.PostsHelpers

  alias Vutuv.Accounts
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.NoteEvent
  alias Vutuv.Posts
  alias VutuvWeb.Fediverse.Docs

  @actor "https://social.example/users/alice"
  @other_actor "https://chaos.example/users/bob"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    Vutuv.RateLimiter.reset()
    user = insert(:activated_user, fediverse_followers?: true, fediverse_replies?: true)
    post = create_post!(user, %{"body" => "Federated far and wide."})
    {:ok, user: user, post: post, note_url: Docs.note_url(user, post.id)}
  end

  # A Create(Note) the way Mastodon sends one: the note embedded, addressed to
  # the public collection, cc'ing the author's followers.
  defp create_activity(note_url, opts \\ []) do
    actor = Keyword.get(opts, :actor, @actor)
    object_id = Keyword.get(opts, :object_id, "#{actor}/statuses/1")

    object =
      %{
        "id" => object_id,
        "type" => Keyword.get(opts, :type, "Note"),
        "inReplyTo" => note_url,
        "content" => Keyword.get(opts, :content, "<p>Guter Punkt.</p>"),
        "url" => Keyword.get(opts, :url, "https://social.example/@alice/1"),
        "to" => Keyword.get(opts, :to, [@public]),
        "cc" => Keyword.get(opts, :cc, ["#{actor}/followers"])
      }
      |> maybe_put("summary", opts[:summary])
      |> maybe_put("tag", opts[:tag])

    %{
      "type" => "Create",
      "actor" => actor,
      "to" => Keyword.get(opts, :to, [@public]),
      "object" => object
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # The actor document the inbox verified the delivery against, reduced to what
  # a stored note keeps. `inbox:` is what an answer would be delivered to
  # (issue #1070); pass it explicitly to test the same-host rule.
  defp remote(uri \\ @actor, opts \\ []) do
    %{
      uri: uri,
      handle: "alice",
      name: "Alice Anders",
      inbox: Keyword.get(opts, :inbox, default_inbox(uri))
    }
  end

  defp default_inbox(uri), do: uri <> "/inbox"

  describe "the inbox an answer would go to (issue #1070)" do
    test "is captured from the verified actor document", %{user: user, note_url: note_url} do
      assert :ok = Fediverse.record_reply(user, create_activity(note_url), remote())

      assert [%Note{inbox_uri: inbox}] = Repo.all(Note)
      assert inbox == "#{@actor}/inbox"
    end

    test "is refused when the actor names an inbox on another host", %{
      user: user,
      note_url: note_url
    } do
      author = remote(@actor, inbox: "https://victim.example/inbox")

      assert :ok = Fediverse.record_reply(user, create_activity(note_url), author)

      # The classic ActivityPub inbox redirect: whoever runs social.example
      # writes that document, so a foreign inbox would turn a member's answer
      # into a signed POST at a third party. Not stored, so not delivered to.
      assert [%Note{inbox_uri: nil}] = Repo.all(Note)
    end

    test "is refused when the actor names a plain-http inbox", %{user: user, note_url: note_url} do
      author = remote(@actor, inbox: "http://social.example/users/alice/inbox")

      assert :ok = Fediverse.record_reply(user, create_activity(note_url), author)
      assert [%Note{inbox_uri: nil}] = Repo.all(Note)
    end

    test "is absent when the document carried none", %{user: user, note_url: note_url} do
      author = remote(@actor, inbox: nil)

      assert :ok = Fediverse.record_reply(user, create_activity(note_url), author)
      assert [%Note{inbox_uri: nil}] = Repo.all(Note)
    end
  end

  describe "record_reply/3 — the gates" do
    test "stores a public reply to the member's own post", %{
      user: user,
      post: post,
      note_url: note_url
    } do
      assert :ok = Fediverse.record_reply(user, create_activity(note_url), remote())

      assert [%Note{} = note] = Repo.all(Note)
      assert note.post_id == post.id
      assert note.actor_uri == @actor
      assert note.handle == "alice"
      assert note.display_name == "Alice Anders"
      assert note.content_text == "Guter Punkt."
      assert note.audience == "public"
      assert note.origin_url == "https://social.example/@alice/1"
      assert note.received_at
      # It was demonstrably live the moment it was delivered, so that counts as
      # the first freshness confirmation.
      assert note.checked_at == note.received_at
      assert DateTime.compare(note.expires_at, note.received_at) == :gt
    end

    test "the same note delivered twice stores one row", %{user: user, note_url: note_url} do
      assert :ok = Fediverse.record_reply(user, create_activity(note_url), remote())
      assert :skip = Fediverse.record_reply(user, create_activity(note_url), remote())

      assert Repo.aggregate(Note, :count) == 1
    end

    test "stores nothing for a member who did not switch replies on", %{
      user: user,
      note_url: note_url
    } do
      {:ok, user} = Accounts.update_user(user, %{"fediverse_replies?" => false})

      assert :skip = Fediverse.record_reply(user, create_activity(note_url), remote())
      assert Repo.aggregate(Note, :count) == 0
    end

    test "the reply switch is independent of the reaction switch", %{
      user: user,
      note_url: note_url
    } do
      # Counts off, replies on: the reply still lands. The two are separate
      # decisions, which is why they are separate columns.
      {:ok, user} = Accounts.update_user(user, %{"fediverse_reactions?" => false})

      assert :ok = Fediverse.record_reply(user, create_activity(note_url), remote())
      assert Repo.aggregate(Note, :count) == 1
    end

    test "stores nothing for a member who does not federate", %{note_url: note_url} do
      plain = insert(:activated_user, fediverse_replies?: true)

      assert :skip = Fediverse.record_reply(plain, create_activity(note_url), remote())
      assert Repo.aggregate(Note, :count) == 0
    end

    test "stores nothing while federation is off installation-wide", %{
      user: user,
      note_url: note_url
    } do
      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      assert :skip = Fediverse.record_reply(user, create_activity(note_url), remote())
      assert Repo.aggregate(Note, :count) == 0
    end

    test "ignores a reply to somebody else's post", %{note_url: note_url} do
      stranger = insert(:activated_user, fediverse_followers?: true, fediverse_replies?: true)

      assert :skip = Fediverse.record_reply(stranger, create_activity(note_url), remote())
      assert Repo.aggregate(Note, :count) == 0
    end

    test "ignores a reply to a restricted post", %{user: user} do
      restricted =
        create_post!(user, %{
          body: "Just for some.",
          denials: [%{"wildcard" => "logged_out"}]
        })

      activity = create_activity(Docs.note_url(user, restricted.id))

      assert :skip = Fediverse.record_reply(user, activity, remote())
      assert Repo.aggregate(Note, :count) == 0
    end

    test "ignores an inReplyTo that is not one of our Note URLs", %{user: user} do
      for target <- [
            "https://social.example/users/alice/statuses/9",
            "#{VutuvWeb.Endpoint.url()}/#{user.username}/posts/not-a-uuid",
            "#{VutuvWeb.Endpoint.url()}/#{user.username}",
            nil
          ] do
        assert :skip = Fediverse.record_reply(user, create_activity(target), remote())
      end

      assert Repo.aggregate(Note, :count) == 0
    end

    test "ignores an object that is not a Note", %{user: user, note_url: note_url} do
      assert :skip =
               Fediverse.record_reply(user, create_activity(note_url, type: "Video"), remote())

      assert Repo.aggregate(Note, :count) == 0
    end

    test "ignores a Create whose object is only an id", %{user: user, note_url: note_url} do
      # We never go and fetch it: an activity that does not carry what it claims
      # to deliver is not worth an outbound request to a stranger's server.
      activity = Map.put(create_activity(note_url), "object", "https://social.example/statuses/1")

      assert :skip = Fediverse.record_reply(user, activity, remote())
      assert Repo.aggregate(Note, :count) == 0
    end

    test "ignores a note whose text is empty once the markup is gone", %{
      user: user,
      note_url: note_url
    } do
      assert :skip =
               Fediverse.record_reply(
                 user,
                 create_activity(note_url, content: "<p>  </p><img src=x>"),
                 remote()
               )

      assert Repo.aggregate(Note, :count) == 0
    end

    test "is subject to the inbound caps (#1067)", %{user: user, note_url: note_url} do
      original_caps = Application.fetch_env(:vutuv, :fediverse_inbound_caps)
      Application.put_env(:vutuv, :fediverse_inbound_caps, {1, 1})

      on_exit(fn ->
        case original_caps do
          {:ok, was} -> Application.put_env(:vutuv, :fediverse_inbound_caps, was)
          :error -> Application.delete_env(:vutuv, :fediverse_inbound_caps)
        end
      end)

      assert :ok = Fediverse.record_reply(user, create_activity(note_url), remote())

      assert :skip =
               Fediverse.record_reply(
                 user,
                 create_activity(note_url, object_id: "#{@actor}/statuses/2"),
                 remote()
               )
    end
  end

  describe "record_reply/3 — the text is reduced to plain text" do
    test "script and markup are stripped away", %{user: user, note_url: note_url} do
      content = "<script>alert(1)</script><p>Hallo <b>Welt</b></p><p>Zweiter Absatz</p>"

      assert :ok =
               Fediverse.record_reply(user, create_activity(note_url, content: content), remote())

      assert [%Note{content_text: text}] = Repo.all(Note)
      assert text == "Hallo Welt\n\nZweiter Absatz"
      refute text =~ "<"
      refute text =~ "alert"
    end

    test "a runaway note is clamped", %{user: user, note_url: note_url} do
      long = "<p>" <> String.duplicate("a", Note.max_content() * 2) <> "</p>"

      assert :ok =
               Fediverse.record_reply(user, create_activity(note_url, content: long), remote())

      assert [%Note{content_text: text}] = Repo.all(Note)
      assert String.length(text) <= Note.max_content()
    end

    test "a mentioned account is stored as its full fediverse address", %{
      user: user,
      note_url: note_url
    } do
      content =
        ~s(<p><a href="https://social.example/@carla" class="u-url mention">@<span>carla</span></a> hat recht.</p>)

      tag = [
        %{
          "type" => "Mention",
          "href" => "https://social.example/users/carla",
          "name" => "@carla"
        }
      ]

      assert :ok =
               Fediverse.record_reply(
                 user,
                 create_activity(note_url, content: content, tag: tag),
                 remote()
               )

      assert [%Note{content_text: text}] = Repo.all(Note)
      assert text == "@carla@social.example hat recht."
    end

    test "a content warning is kept as the lid, not folded into the text", %{
      user: user,
      note_url: note_url
    } do
      activity =
        create_activity(note_url, summary: "Spoiler: Staffelfinale", content: "<p>Er stirbt.</p>")

      assert :ok = Fediverse.record_reply(user, activity, remote())

      assert [%Note{} = note] = Repo.all(Note)
      assert note.summary == "Spoiler: Staffelfinale"
      assert note.content_text == "Er stirbt."
      assert Note.warned?(note)
    end
  end

  describe "audience (#1071)" do
    test "every spelling of the public collection counts as public", %{
      user: user,
      note_url: note_url
    } do
      for {spelling, index} <-
            Enum.with_index([@public, "as:Public", "Public"]) do
        activity =
          create_activity(note_url, to: [spelling], object_id: "#{@actor}/statuses/pub#{index}")

        assert :ok = Fediverse.record_reply(user, activity, remote())
      end

      assert Repo.all(from(n in Note, select: n.audience)) == ~w(public public public)
    end

    test "a note addressed only to the member is direct", %{user: user, note_url: note_url} do
      activity = create_activity(note_url, to: [Docs.actor_url(user)], cc: [])

      assert :ok = Fediverse.record_reply(user, activity, remote())

      assert [%Note{audience: "direct"} = note] = Repo.all(Note)
      refute Note.public?(note)
    end

    test "a followers-only note is not public", %{user: user, note_url: note_url} do
      activity =
        create_activity(note_url, to: ["#{@actor}/followers"], cc: [Docs.actor_url(user)])

      assert :ok = Fediverse.record_reply(user, activity, remote())

      assert [%Note{audience: "followers"} = note] = Repo.all(Note)
      refute Note.public?(note)
    end

    test "an audience we cannot read is treated as private, never widened", %{
      user: user,
      note_url: note_url
    } do
      activity = create_activity(note_url, to: ["https://social.example/some/collection"], cc: [])

      assert :ok = Fediverse.record_reply(user, activity, remote())

      assert [%Note{audience: "unknown"} = note] = Repo.all(Note)
      refute Note.public?(note)
    end
  end

  describe "list_notes/2 — who may see what" do
    setup %{user: user, note_url: note_url} do
      :ok = Fediverse.record_reply(user, create_activity(note_url), remote())

      :ok =
        Fediverse.record_reply(
          user,
          create_activity(note_url,
            actor: @other_actor,
            object_id: "#{@other_actor}/statuses/7",
            to: [Docs.actor_url(user)],
            cc: []
          ),
          remote(@other_actor)
        )

      :ok
    end

    test "a logged-out visitor sees only the public one", %{post: post} do
      assert [%Note{audience: "public"}] = notes_for(post, nil)
    end

    test "another member sees only the public one", %{post: post} do
      assert [%Note{audience: "public"}] = notes_for(post, insert(:activated_user))
    end

    test "the member whose post it is sees both", %{post: post, user: user} do
      assert [%Note{audience: "public"}, %Note{audience: "direct"}] = notes_for(post, user)
    end

    test "the public count never moves for a private note", %{post: post} do
      assert Fediverse.note_count(post.id) == 1
    end
  end

  defp notes_for(post, viewer) do
    Fediverse.list_notes([post.id], viewer) |> Map.get(post.id, [])
  end

  describe "takedown" do
    setup %{user: user, note_url: note_url} do
      :ok = Fediverse.record_reply(user, create_activity(note_url), remote())
      {:ok, note: Repo.one!(Note)}
    end

    test "the member removes a reply from their own post", %{user: user, note: note} do
      assert :ok = Fediverse.remove_note(note.id, user)

      assert Repo.aggregate(Note, :count) == 0
      assert [%NoteEvent{action: "removed_by_member"} = event] = Repo.all(NoteEvent)
      assert event.host == "social.example"
      assert event.user_id == user.id
      assert event.actor_id == user.id
    end

    test "somebody else cannot remove it", %{note: note} do
      assert {:error, :not_allowed} = Fediverse.remove_note(note.id, insert(:activated_user))
      assert Repo.aggregate(Note, :count) == 1
    end

    test "a report deletes it at once, with no case workflow", %{note: note} do
      reporter = insert(:activated_user)

      assert :ok = Fediverse.report_note(note.id, reporter)

      assert Repo.aggregate(Note, :count) == 0
      assert [%NoteEvent{action: "reported"} = event] = Repo.all(NoteEvent)
      assert event.actor_id == reporter.id
      assert Repo.aggregate(Vutuv.Moderation.Case, :count) == 0
    end

    test "the ledger keeps no content and no URIs", %{note: note} do
      :ok = Fediverse.report_note(note.id, insert(:activated_user))

      assert [%NoteEvent{} = event] = Repo.all(NoteEvent)
      # A keyed digest groups a repeat offender without holding the identifier.
      assert event.actor_digest != @actor
      assert String.length(event.actor_digest) == 64

      encoded = inspect(Map.from_struct(event))
      refute encoded =~ "Guter Punkt"
      refute encoded =~ @actor
    end

    test "the same actor digests the same way twice", %{user: user, note_url: note_url} do
      :ok = Fediverse.report_note(Repo.one!(Note).id, insert(:activated_user))

      :ok =
        Fediverse.record_reply(
          user,
          create_activity(note_url, object_id: "#{@actor}/statuses/2"),
          remote()
        )

      :ok = Fediverse.report_note(Repo.one!(Note).id, insert(:activated_user))

      assert [a, b] = Repo.all(from(e in NoteEvent, select: e.actor_digest))
      assert a == b
    end

    test "a private reply cannot be reported by anyone but its addressee", %{
      user: user,
      note_url: note_url
    } do
      Repo.delete_all(Note)

      :ok =
        Fediverse.record_reply(
          user,
          create_activity(note_url, to: [Docs.actor_url(user)], cc: []),
          remote()
        )

      private = Repo.one!(Note)

      assert {:error, :not_allowed} = Fediverse.report_note(private.id, insert(:activated_user))
      assert Repo.aggregate(Note, :count) == 1

      assert :ok = Fediverse.report_note(private.id, user)
      assert Repo.aggregate(Note, :count) == 0
    end

    test "reporting is rate limited per reporter", %{user: user, note_url: note_url} do
      reporter = insert(:activated_user)

      for index <- 1..(Fediverse.report_limit() + 1) do
        Repo.delete_all(Note)

        :ok =
          Fediverse.record_reply(
            user,
            create_activity(note_url, object_id: "#{@actor}/statuses/r#{index}"),
            remote()
          )

        note = Repo.one!(Note)

        if index > Fediverse.report_limit() do
          assert {:error, :rate_limited} = Fediverse.report_note(note.id, reporter)
        else
          assert :ok = Fediverse.report_note(note.id, reporter)
        end
      end
    end
  end

  describe "upstream signals" do
    setup %{user: user, note_url: note_url} do
      :ok = Fediverse.record_reply(user, create_activity(note_url), remote())
      {:ok, note: Repo.one!(Note)}
    end

    test "a Delete of the note removes it immediately", %{note: note} do
      assert :ok = Fediverse.delete_reply(@actor, note.object_uri)
      assert Repo.aggregate(Note, :count) == 0
    end

    test "a Delete from a different server cannot touch it", %{note: note} do
      assert :ok = Fediverse.delete_reply(@other_actor, note.object_uri)
      assert Repo.aggregate(Note, :count) == 1
    end

    test "an upstream Delete is honoured after the member switched replies off", %{
      user: user,
      note: note
    } do
      # The withdrawal path must never depend on a switch still being on.
      {:ok, _} = Accounts.update_user(user, %{"fediverse_replies?" => false})

      assert :ok = Fediverse.delete_reply(@actor, note.object_uri)
      assert Repo.aggregate(Note, :count) == 0
    end

    test "an Update rewrites the stored text", %{user: user, note_url: note_url, note: note} do
      activity =
        create_activity(note_url, content: "<p>Korrigiert: doch nicht.</p>")
        |> Map.put("type", "Update")

      assert :ok = Fediverse.update_reply(user, activity, @actor)

      assert %Note{content_text: "Korrigiert: doch nicht."} = Repo.reload!(note)
    end

    test "an Update from a different server is ignored", %{
      user: user,
      note_url: note_url,
      note: note
    } do
      activity =
        create_activity(note_url,
          actor: @other_actor,
          object_id: note.object_uri,
          content: "<p>Hijack</p>"
        )
        |> Map.put("type", "Update")

      assert :ok = Fediverse.update_reply(user, activity, @other_actor)

      assert %Note{content_text: "Guter Punkt."} = Repo.reload!(note)
    end
  end

  describe "retention" do
    test "a note past its ceiling is swept", %{user: user, note_url: note_url} do
      :ok = Fediverse.record_reply(user, create_activity(note_url), remote())

      Repo.update_all(Note, set: [expires_at: DateTime.add(DateTime.utc_now(:second), -60)])

      assert Fediverse.expire_due_notes() == 1
      assert Repo.aggregate(Note, :count) == 0
    end

    test "a note inside its ceiling is left alone", %{user: user, note_url: note_url} do
      :ok = Fediverse.record_reply(user, create_activity(note_url), remote())

      assert Fediverse.expire_due_notes() == 0
      assert Repo.aggregate(Note, :count) == 1
    end

    test "the ceiling is the configured number of days out", %{user: user, note_url: note_url} do
      :ok = Fediverse.record_reply(user, create_activity(note_url), remote())

      note = Repo.one!(Note)
      days = DateTime.diff(note.expires_at, note.received_at, :day)

      assert days == Fediverse.note_retention_days()
    end

    test "only a public note is ever re-fetched", %{user: user, note_url: note_url} do
      # A direct message answers 403/404 to any fetch we can make, which the
      # checker would read as "deleted upstream" and act on — quietly destroying
      # every private reply about a week after it arrived. It also tells the
      # origin we are holding it. So it is never checked.
      :ok =
        Fediverse.record_reply(
          user,
          create_activity(note_url, to: [Docs.actor_url(user)], cc: []),
          remote()
        )

      note = Repo.one!(Note)

      Repo.update_all(Note,
        set: [checked_at: DateTime.add(DateTime.utc_now(:second), -400 * 86_400)]
      )

      assert Fediverse.due_for_refresh([Repo.reload!(note)]) == []
    end

    test "a stale public note is due for a re-fetch", %{user: user, note_url: note_url} do
      :ok = Fediverse.record_reply(user, create_activity(note_url), remote())

      fresh = Repo.one!(Note)
      assert Fediverse.due_for_refresh([fresh]) == []

      stale_at =
        DateTime.add(DateTime.utc_now(:second), -(Fediverse.note_refresh_days() + 1) * 86_400)

      Repo.update_all(Note, set: [checked_at: stale_at])

      assert [%Note{}] = Fediverse.due_for_refresh([Repo.reload!(fresh)])
    end
  end

  # The half of retention that deletes *earlier* than the ceiling, and the half
  # that keeps "cache" an honest word. Stubbed at the HTTP layer, the way the
  # other Fediverse outbound tests stub it.
  describe "refresh_note/1" do
    defp stub_origin(response) do
      Application.put_env(:vutuv, :fediverse_req_options, plug: response)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
    end

    defp answer(status, body \\ "") do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(status, body)
      end
    end

    defp note_doc(fields) do
      Jason.encode!(
        Map.merge(
          %{
            "id" => "#{@actor}/statuses/1",
            "type" => "Note",
            "content" => "<p>Guter Punkt.</p>",
            "to" => [@public]
          },
          fields
        )
      )
    end

    defp stored_note(user, note_url) do
      :ok = Fediverse.record_reply(user, create_activity(note_url), remote())
      Repo.one!(Note)
    end

    test "still published: the text is refreshed and the ceiling pushed out", %{
      user: user,
      note_url: note_url
    } do
      note = stored_note(user, note_url)
      stub_origin(answer(200, note_doc(%{"content" => "<p>Nachtrag: doch.</p>"})))

      # Age it, so the new ceiling is visibly later than the old one.
      old_expiry = DateTime.add(note.expires_at, -10 * 86_400)
      Repo.update_all(Note, set: [expires_at: old_expiry])

      assert :refreshed = Fediverse.refresh_note(Repo.reload!(note))

      refreshed = Repo.reload!(note)
      assert refreshed.content_text == "Nachtrag: doch."
      assert DateTime.compare(refreshed.expires_at, old_expiry) == :gt
    end

    test "gone from its origin: deleted at once", %{user: user, note_url: note_url} do
      for {status, index} <- Enum.with_index([404, 410, 403]) do
        :ok =
          Fediverse.record_reply(
            user,
            create_activity(note_url, object_id: "#{@actor}/statuses/gone#{index}"),
            remote()
          )

        note = Repo.one!(Note)
        stub_origin(answer(status))

        assert :deleted = Fediverse.refresh_note(note)
        assert Repo.aggregate(Note, :count) == 0
      end
    end

    test "checking a note twice does not raise on the second delete", %{
      user: user,
      note_url: note_url
    } do
      # Two open pages can both queue a check for the same note, and both can
      # conclude it is gone. The loser must find nothing to do, not raise.
      note = stored_note(user, note_url)
      stub_origin(answer(410))

      assert :deleted = Fediverse.refresh_note(note)
      assert :deleted = Fediverse.refresh_note(note)
      assert Repo.aggregate(Note, :count) == 0
    end

    test "no longer public: also deleted, it is the same signal", %{
      user: user,
      note_url: note_url
    } do
      # The author narrowed the audience. We would never see a Delete for
      # that, and it means "stop showing this" just as plainly.
      note = stored_note(user, note_url)
      stub_origin(answer(200, note_doc(%{"to" => ["#{@actor}/followers"]})))

      assert :deleted = Fediverse.refresh_note(note)
      assert Repo.aggregate(Note, :count) == 0
    end

    test "unreachable: nothing changes, so an outage buys no retention", %{
      user: user,
      note_url: note_url
    } do
      note = stored_note(user, note_url)

      for response <- [answer(500), answer(429), answer(200, "not json at all")] do
        stub_origin(response)
        assert :unchanged = Fediverse.refresh_note(Repo.reload!(note))
      end

      kept = Repo.reload!(note)
      assert kept.content_text == "Guter Punkt."
      # The ceiling did NOT move: a server that stays offline cannot keep a
      # copy alive by being offline.
      assert kept.expires_at == note.expires_at
    end

    test "a private note is never asked about at all", %{user: user, note_url: note_url} do
      :ok =
        Fediverse.record_reply(
          user,
          create_activity(note_url, to: [Docs.actor_url(user)], cc: []),
          remote()
        )

      # Any request would be a failure here: the stub raises if it is called.
      stub_origin(fn _conn -> raise "the origin of a private note must never be asked" end)

      assert :skip = Fediverse.refresh_note(Repo.one!(Note))
      assert Repo.aggregate(Note, :count) == 1
    end
  end

  describe "cascades" do
    setup %{user: user, note_url: note_url} do
      :ok = Fediverse.record_reply(user, create_activity(note_url), remote())
      :ok
    end

    test "deleting the post takes its remote replies", %{post: post} do
      {:ok, _} = Posts.delete_post(post)

      assert Repo.aggregate(Note, :count) == 0
    end

    test "deleting the account takes them too", %{user: user} do
      {:ok, _} = Accounts.delete_user(user)

      assert Repo.aggregate(Note, :count) == 0
    end

    test "switching replies off deletes what was stored", %{user: user} do
      assert Fediverse.drop_notes(user) == 1
      assert Repo.aggregate(Note, :count) == 0
    end

    test "blocking the server takes its notes with it" do
      admin = insert(:activated_user)

      {:ok, {_blocked, purged}} =
        Fediverse.block_instance(%{"host" => "social.example"}, admin)

      assert purged.notes == 1
      assert Repo.aggregate(Note, :count) == 0
    end
  end

  describe "the reply joins the unread badge" do
    test "reading the notifications page clears it for good", %{user: user, note_url: note_url} do
      # An older local event pins the read marker: mark_notifications_read/1
      # anchors the marker to the newest event it knows about, and a source
      # missing from that anchor query stays "unread" on every recount — the
      # /notifications -> /feed badge loop.
      old_follow = insert(:follow, follower: insert(:user), followee: user)

      Repo.update_all(from(f in Vutuv.Social.Follow, where: f.id == ^old_follow.id),
        set: [inserted_at: ~N[2020-01-01 12:00:00]]
      )

      Vutuv.Activity.mark_notifications_read(user.id)

      :ok = Fediverse.record_reply(user, create_activity(note_url), remote())

      # Second precision would let a same-second mark tie the note away.
      Repo.update_all(Note,
        set: [received_at: DateTime.add(DateTime.utc_now(:second), -300, :second)]
      )

      assert Vutuv.Activity.unread_notification_count(user.id) == 1

      Vutuv.Activity.mark_notifications_read(user.id)

      assert Vutuv.Activity.unread_notification_count(user.id) == 0
    end
  end

  describe "the count reaches the action bar" do
    test "engagement_counts/1 carries public replies on their own figure", %{
      user: user,
      post: post,
      note_url: note_url
    } do
      assert Posts.engagement_counts(post.id).fediverse_replies == 0

      :ok = Fediverse.record_reply(user, create_activity(note_url), remote())

      counts = Posts.engagement_counts(post.id)
      assert counts.fediverse_replies == 1
      # Kept apart in the data — a remote reply never moves the vutuv figure —
      # while the card adds the two up into the one reply count it shows
      # (`shown_counts/1`) and names the split in its panel.
      assert counts.replies == 0
      assert Posts.fediverse_reaction_count(counts) == 0
      assert %{replies: 1} = Posts.shown_counts(counts)
    end

    test "a private reply is invisible to the public figure", %{
      user: user,
      post: post,
      note_url: note_url
    } do
      :ok =
        Fediverse.record_reply(
          user,
          create_activity(note_url, to: [Docs.actor_url(user)], cc: []),
          remote()
        )

      assert Posts.engagement_counts(post.id).fediverse_replies == 0
    end
  end
end
