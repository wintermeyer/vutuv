defmodule Vutuv.MastodonApi.NotificationsTest do
  @moduledoc """
  The account a notification names when its actor lives on another network
  (issue #1598): the item carries only the actor's handle and URI, so the
  cached `RemoteAccount` — with its gate-cleared face — has to be resolved
  from that URI, and the hand-built placeholder is only for actors nobody
  here ever stored. Calibrated against the un-fixed code, where every remote
  actor wore the installation icon.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.MastodonHelpers, only: [avatar_capability: 1]

  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.MastodonApi
  alias Vutuv.MastodonApi.Notifications
  alias Vutuv.MastodonApi.Presenter
  alias VutuvWeb.RemoteMediaToken

  defp stored_account(actor_uri) do
    Repo.insert!(%RemoteAccount{
      actor_uri: actor_uri,
      host: URI.parse(actor_uri).host,
      handle: "carol",
      name: "Carol",
      inbox_uri: actor_uri <> "/inbox",
      avatar: "avatar-abc123.avif",
      avatar_moderation: "approved"
    })
  end

  # The shape `Vutuv.Activity.remote_actor_fields/1` gives both the derived
  # items and the live notify payloads, so this covers the streaming path too.
  defp item(actor_uri) do
    %{
      id: "fediverse_reaction-test",
      kind: "fediverse_reaction",
      actor_id: nil,
      actor_name: "@carol@social.example",
      actor_handle: "@carol@social.example",
      actor_url: actor_uri
    }
  end

  test "resolves the cached account by its actor URI" do
    actor_uri = "https://social.example/users/carol-#{System.unique_integer([:positive])}"
    stored = stored_account(actor_uri)

    account = Notifications.account(item(actor_uri))

    assert account.id == "remote-" <> stored.id
    # The path names the picture, and the query carries a capability the proxy
    # accepts for exactly it — an image loader brings no session of its own.
    assert String.starts_with?(
             account.avatar,
             MastodonApi.main_url(RemoteAccount.avatar_url(stored)) <> "?"
           )

    assert account.avatar
           |> avatar_capability()
           |> RemoteMediaToken.avatar?(stored.id, stored.avatar)

    refute account.avatar == Presenter.fallback_avatar()
  end

  test "falls back to the placeholder for an actor nobody here stored" do
    actor_uri = "https://social.example/users/carol-#{System.unique_integer([:positive])}"

    account = Notifications.account(item(actor_uri))

    assert account.acct == "carol@social.example"
    assert account.avatar == Presenter.fallback_avatar()
  end
end
