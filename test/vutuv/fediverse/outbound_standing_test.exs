defmodule Vutuv.Fediverse.OutboundStandingTest do
  @moduledoc """
  `Vutuv.Fediverse.outbound_standing/1` is the viewer-level half of every
  outbound gate, lifted out so a control can ask it *before* it is pressed — the
  action bar on a card from another network only paints a press on the spot when
  it answers `:ok`.

  That makes it a second copy of a cond, and a copy that drifts would have the
  bar promise what the gate then refuses: the member sees the heart fill and the
  refusal arrive together. So every state is held against the real gate here
  rather than asserted on its own.
  """
  use Vutuv.DataCase

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  defp federating_user(attrs \\ []) do
    insert(:user, Keyword.merge([email_confirmed?: true, fediverse_followers?: true], attrs))
  end

  defp cached_post do
    now = DateTime.utc_now(:second)

    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: "https://social.example/users/them",
        handle: "them",
        host: "social.example",
        inbox_uri: "https://social.example/users/them/inbox"
      })

    Repo.insert!(%RemotePost{
      remote_account_id: account.id,
      object_uri: "https://social.example/posts/1",
      origin_url: "https://social.example/@them/1",
      content_text: "A thought from over there.",
      audience: "public",
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  describe "it agrees with the gate it was lifted out of" do
    test "a member who takes part gets :ok from both" do
      user = federating_user()

      assert :ok = Fediverse.outbound_standing(user)
      assert :ok = Fediverse.check_remote_like(user, cached_post())
      assert :ok = Fediverse.check_note_like(user, insert(:note))
    end

    test "a member who does not take part is refused by both, with the same reason" do
      user = federating_user(fediverse_followers?: false)

      assert {:error, :not_federating} = Fediverse.outbound_standing(user)
      assert {:error, :not_federating} = Fediverse.check_remote_like(user, cached_post())
      assert {:error, :not_federating} = Fediverse.check_note_like(user, insert(:note))
    end

    test "an unconfirmed address is the same answer, not a different one" do
      # `federated?/1` is false here although the member's own switch is on —
      # the reason the bar must ask this predicate rather than read the column.
      user = federating_user(email_confirmed?: false)

      assert {:error, :not_federating} = Fediverse.outbound_standing(user)
      assert {:error, :not_federating} = Fediverse.check_remote_like(user, cached_post())
    end

    test "a member who moved away is refused by both" do
      user = federating_user(moved_to: "https://elsewhere.example/users/them")

      assert {:error, :moved} = Fediverse.outbound_standing(user)
      assert {:error, :moved} = Fediverse.check_remote_like(user, cached_post())
    end

    test "no viewer at all is not signed in" do
      assert {:error, :not_signed_in} = Fediverse.outbound_standing(nil)
    end
  end
end
