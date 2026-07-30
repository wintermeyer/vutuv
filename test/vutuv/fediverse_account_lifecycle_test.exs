defmodule Vutuv.FediverseAccountLifecycleTest do
  @moduledoc """
  What happens to a follow when the account behind it moves, deletes itself or
  simply stops existing (issue #1168).

  Three ways an account can leave, and the point of all three is the same: a
  member's subscription must not quietly point at a husk. A move carries it
  over, a deletion takes everything with it, and a disappearance nobody
  announces is found by asking.

  `async: false` — the HTTP stub lives in the application env, which the SQL
  sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  @old "https://alt.example/users/them"
  @new "https://neu.example/users/them"

  defp account(uri \\ @old, attrs \\ []) do
    %URI{host: host} = URI.parse(uri)

    Repo.insert!(%RemoteAccount{
      actor_uri: uri,
      host: host,
      handle: attrs[:handle] || "them",
      name: attrs[:name] || "Them",
      inbox_uri: uri <> "/inbox",
      refreshed_at: attrs[:refreshed_at]
    })
  end

  defp member_following(acc, state \\ "accepted") do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: acc.id,
      state: state,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{acc.id}"
    })

    Repo.reload!(user)
  end

  # The successor's actor document, which is what a move stands or falls on.
  defp serve_actor(doc_overrides \\ %{}) do
    doc =
      Map.merge(
        %{
          "id" => @new,
          "type" => "Person",
          "preferredUsername" => "them",
          "name" => "Them, elsewhere",
          "inbox" => @new <> "/inbox",
          "alsoKnownAs" => [@old]
        },
        doc_overrides
      )

    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, Jason.encode!(doc))
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp serve_status(status) do
    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, status, "") end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp move(target \\ @new), do: %{"type" => "Move", "actor" => @old, "target" => target}

  describe "a verified move" do
    setup do
      acc = account()
      %{account: acc, user: member_following(acc)}
    end

    test "carries the subscription over without the member lifting a finger", ctx do
      serve_actor()

      assert :ok = Fediverse.record_remote_move(move(), @old)

      # The old follow is a husk now, and says so.
      old_follow = Repo.get_by!(Follow, user_id: ctx.user.id, remote_account_id: ctx.account.id)
      assert Follow.moved?(old_follow)

      # And a fresh request went to the successor, exactly as if the member had
      # typed the new address: a new server gets to decide like any other.
      successor = Repo.get_by!(RemoteAccount, actor_uri: @new)
      new_follow = Repo.get_by!(Follow, user_id: ctx.user.id, remote_account_id: successor.id)
      assert new_follow.state == "requested"

      assert Repo.get!(RemoteAccount, ctx.account.id).moved_to == @new
    end

    test "the swap completes only when the successor accepts", ctx do
      serve_actor()
      :ok = Fediverse.record_remote_move(move(), @old)
      successor = Repo.get_by!(RemoteAccount, actor_uri: @new)
      new_follow = Repo.get_by!(Follow, remote_account_id: successor.id)

      # Until then the husk stands: a move the successor never answers must
      # leave a record of what the member had, not silently lose it.
      assert Repo.aggregate(Follow, :count) == 2

      :ok =
        Fediverse.accept_remote_follow(
          ctx.user,
          %{"object" => %{"id" => new_follow.follow_activity_id}},
          @new
        )

      assert [only] = Repo.all(Follow)
      assert only.remote_account_id == successor.id
      assert only.state == "accepted"
    end
  end

  describe "an unverified move changes nothing" do
    setup do
      acc = account()
      %{account: acc, user: member_following(acc)}
    end

    test "when the successor does not claim the old account as an alias", ctx do
      # Without this check any server could redirect the followers of any
      # account it could name.
      serve_actor(%{"alsoKnownAs" => []})

      assert :skip = Fediverse.record_remote_move(move(), @old)

      assert Repo.aggregate(Follow, :count) == 1
      assert Repo.get_by!(Follow, remote_account_id: ctx.account.id).state == "accepted"
      assert is_nil(Repo.get!(RemoteAccount, ctx.account.id).moved_to)
    end

    test "when the target is on a blocked server", _ctx do
      {:ok, _} = Fediverse.block_instance(%{"host" => "neu.example"}, insert(:user, admin?: true))

      # No stub at all: reaching the network would raise, which is the point.
      assert :skip = Fediverse.record_remote_move(move(), @old)
      assert Repo.aggregate(Follow, :count) == 1
    end

    test "when the target is an address on this very installation", _ctx do
      assert :skip =
               Fediverse.record_remote_move(
                 move("#{VutuvWeb.Endpoint.url()}/somebody/actor"),
                 @old
               )

      assert Repo.aggregate(Follow, :count) == 1
    end
  end

  describe "an account that deletes itself" do
    test "takes its follows and its cached posts, and leaves a content-free record" do
      acc = account()
      member_following(acc)
      now = DateTime.utc_now(:second)

      Repo.insert!(%RemotePost{
        remote_account_id: acc.id,
        object_uri: "https://alt.example/p/1",
        content_text: "Bis dann.",
        audience: "public",
        kind: "note",
        published_at: now,
        received_at: now,
        expires_at: DateTime.add(now, 86_400)
      })

      # The test env filters below :warning, and this line is :info like every
      # other sweep line in this subsystem.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Fediverse.remove_remote_account(@old)
        end)

      assert Repo.aggregate(RemoteAccount, :count) == 0
      assert Repo.aggregate(Follow, :count) == 0
      assert Repo.aggregate(RemotePost, :count) == 0

      # The record names the server and the counts and nothing about the
      # person: keeping their address would undo what the deletion is for. A
      # log line rather than the takedown ledger, whose stated policy is that
      # automatic deletions stay out of it.
      assert log =~ "host=alt.example"
      assert log =~ "follows=1"
      assert log =~ "cached_posts=1"
      refute log =~ @old
    end
  end

  describe "a move only ever points where the document really is" do
    setup do
      acc = account()
      %{account: acc, user: member_following(acc)}
    end

    test "a decoy target whose document claims a blocked host is refused", _ctx do
      {:ok, _} =
        Fediverse.block_instance(%{"host" => "gesperrt.example"}, insert(:user, admin?: true))

      # The typed target is innocent; the document it serves is not. Each hop
      # can land somewhere else than the last, so the canonical id is checked
      # too — otherwise the blocklist is bypassed and a member-signed Follow is
      # queued at an inbox the attacker chose.
      serve_actor(%{"id" => "https://gesperrt.example/users/opfer", "alsoKnownAs" => [@old]})

      assert :skip = Fediverse.record_remote_move(move("https://koeder.example/x"), @old)
      refute Repo.get_by(RemoteAccount, actor_uri: "https://gesperrt.example/users/opfer")
      assert Repo.aggregate(Vutuv.Fediverse.Delivery, :count) == 0
    end

    test "a document claiming an address on this installation is refused", _ctx do
      serve_actor(%{
        "id" => "#{VutuvWeb.Endpoint.url()}/somebody/actor",
        "alsoKnownAs" => [@old]
      })

      assert :skip = Fediverse.record_remote_move(move("https://koeder.example/x"), @old)
      assert Repo.aggregate(RemoteAccount, :count) == 1
    end

    test "a member who may not follow is not re-pointed in their name", ctx do
      # Frozen pending review: a signed request must not go out in their name
      # because somebody else's server announced a move.
      ctx.user
      |> Ecto.Changeset.change(frozen_at: NaiveDateTime.utc_now(:second))
      |> Repo.update!()

      serve_actor()

      assert :ok = Fediverse.record_remote_move(move(), @old)
      assert Repo.aggregate(Vutuv.Fediverse.Delivery, :count) == 0
      # And no husk is left standing, since nothing will ever settle it.
      assert Repo.aggregate(Follow, :count) == 0
    end

    test "a member already following the successor keeps one live follow", ctx do
      successor = account(@new, handle: "them")

      Repo.insert!(%Follow{
        user_id: ctx.user.id,
        remote_account_id: successor.id,
        state: "accepted",
        follow_activity_id: "https://vutuv.test/#{ctx.user.id}/actor#f/#{successor.id}"
      })

      serve_actor()
      assert :ok = Fediverse.record_remote_move(move(), @old)

      # Nothing was sent and nothing will answer, so the old row ends rather
      # than becoming a husk no Accept can ever settle.
      assert [only] = Repo.all(Follow)
      assert only.remote_account_id == successor.id
      assert only.state == "accepted"
    end
  end

  describe "an account that simply stops existing" do
    test "is found by asking, and only a 404 or 410 removes it" do
      acc = account()
      member_following(acc)

      serve_status(410)
      assert Fediverse.prune_due_remote_accounts() == 1
      assert Repo.aggregate(RemoteAccount, :count) == 0
    end

    test "a bad day at the other end costs nobody their follow" do
      acc = account()
      member_following(acc)

      # A timeout, a 5xx, a 429: a server having a bad week must not cost its
      # members their followers here, in either direction.
      serve_status(503)
      assert Fediverse.prune_due_remote_accounts() == 0
      assert Repo.get(RemoteAccount, acc.id)
      # The clock moved, so the next run looks at somebody else.
      assert Repo.get!(RemoteAccount, acc.id).refreshed_at
    end

    test "a rename surfaces without waiting for an Update nobody sends" do
      acc = account()
      member_following(acc)
      serve_actor(%{"id" => @old, "preferredUsername" => "neuername", "alsoKnownAs" => []})

      assert Fediverse.prune_due_remote_accounts() == 0

      assert Repo.get!(RemoteAccount, acc.id).handle == "neuername"
    end

    test "an account checked recently is not asked again" do
      acc = account(@old, refreshed_at: DateTime.utc_now(:second))
      member_following(acc)

      # No stub: a request would raise. The rotation is what keeps this civil.
      assert Fediverse.remote_accounts_due_for_prune() == []
    end

    test "a document about somebody else is not applied to this row" do
      acc = account()
      member_following(acc)
      # It answered, but about a different account. Not gone, so not pruned —
      # and emphatically not a licence for this row to become that account.
      serve_actor(%{"id" => @new, "alsoKnownAs" => []})

      assert Fediverse.prune_due_remote_accounts() == 0
      assert Repo.get!(RemoteAccount, acc.id).actor_uri == @old
    end

    test "a moved account keeps its destination through a repeat resolve" do
      acc = account()
      member_following(acc)
      Repo.update!(Ecto.Changeset.change(acc, moved_to: @new))

      # A stored reply or reaction from the old actor re-upserts its row. The
      # move must survive that, or the successor's Accept can never settle the
      # husk and the account re-enters the prune rotation.
      :ok =
        Fediverse.remember_remote_account(%{
          id: @old,
          inbox: @old <> "/inbox",
          shared_inbox: nil,
          preferred_username: "them",
          name: "Them",
          summary: nil,
          public_key_id: nil,
          public_key_pem: nil,
          also_known_as: []
        })

      assert Repo.get!(RemoteAccount, acc.id).moved_to == @new
    end

    test "a moved account is not pruned: it is elsewhere, not missing" do
      acc = account()
      member_following(acc, "moved")
      Repo.update!(Ecto.Changeset.change(acc, moved_to: @new))

      assert Fediverse.remote_accounts_due_for_prune() == []
    end
  end
end
