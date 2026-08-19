defmodule VutuvWeb.RemoteMediaFederationDisabledTest do
  @moduledoc """
  Switching federation off closes the picture proxy, on **both** of its doors.

  The signed-in door has been closed since the proxy shipped. The capability
  the Mastodon adapter hands its clients (`VutuvWeb.RemoteMediaToken`) is the
  new one, and it is the one worth a test of its own: it is checked after the
  database read, so a rearrangement of `avatar/2`'s `with` chain could leave a
  valid capability opening cached pictures of accounts on a network this
  installation no longer talks to.

  Key flipped here, and who else reads it: `:fediverse_enabled`, through
  `Vutuv.Fediverse.enabled?/0` — the tag timeline, the feed source tabs, the
  sign-up form and `Vutuv.Fediverse.federated?/1` all consult it.

  async: false for exactly that reason, like `VutuvWeb.LandingConfigurationTest`:
  the flag is global application state the SQL sandbox does not roll back, so
  this must not run beside anything that reads it. It lives in its own file
  rather than making the whole of `VutuvWeb.RemoteMediaControllerTest` sync.
  """
  use VutuvWeb.ConnCase

  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.RemoteMedia
  alias VutuvWeb.RemoteMediaToken

  setup do
    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: "https://social.example/users/them#{System.unique_integer([:positive])}",
        host: "social.example",
        handle: "them",
        inbox_uri: "https://social.example/inbox"
      })

    {:ok, %{file: file}} = RemoteMedia.store_avatar(jpeg_bytes(), account.id)
    account = Repo.update!(change(account, avatar: file, avatar_moderation: "approved"))

    %{account: account, url: adapter_url(account), out: build_conn()}
  end

  test "the capability opens the picture while the installation federates", ctx do
    assert get(ctx.out, ctx.url).status == 200
  end

  test "and stops opening it once federation is switched off", ctx do
    put_config(:fediverse_enabled, false)

    assert get(ctx.out, ctx.url).status == 404
  end

  # The avatar URL as an API client receives it. Minted straight from the
  # capability rather than round-tripped through `Presenter.account/1`: that
  # the adapter really appends this is `VutuvWeb.MastodonApi.FediverseClientTest`'s
  # subject, and what is under test here is only the switch.
  defp adapter_url(%RemoteAccount{id: id, avatar: file}),
    do: RemoteMedia.avatar_url(id, file) <> "?" <> RemoteMediaToken.avatar_query(id, file)

  # `put_env(key, get_env(key))` cannot restore: `get_env` answers nil both for
  # "absent" and for "present as nil", and a nil `:fediverse_enabled` makes
  # every `and` on `enabled?/0` raise instead of falling through to its `true`
  # default. `fetch_env/2` tells the two cases apart.
  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  defp jpeg_bytes do
    {:ok, image} = Image.new(8, 8, color: [10, 20, 30])
    {:ok, bytes} = Image.write(image, :memory, suffix: ".jpg")
    bytes
  end
end
