defmodule Vutuv.ApiAuth.SweepTest do
  @moduledoc """
  Housekeeping for the two OAuth tables nothing ever emptied (issue #1557).

  A Mastodon client registers itself **before** anybody consents, so the
  registration is the first step of setup and an abandoned setup leaves an
  ownerless `oauth_apps` row behind for good. That is not fallout from one bug:
  a member who opens a client and does not finish the consent screen leaves the
  same row in ordinary use.

  The interesting part is what must **survive** the sweep, which is why those
  cases outnumber the deletions here. "No grant" stopped meaning "nobody can use
  this" in v7.317.0: a `client_credentials` app holds a live token and has no
  grant at all, so a sweep written before that grant existed would delete
  exactly the apps the newest feature works for.
  """
  use Vutuv.DataCase, async: true

  import Ecto.Query
  import Vutuv.MastodonHelpers

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.App
  alias Vutuv.ApiAuth.AppToken
  alias Vutuv.ApiAuth.AuthCode
  alias Vutuv.ApiAuth.Grant
  alias Vutuv.Repo

  defp age!(schema, id, days) do
    stamp = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -days * 86_400)
    Repo.update_all(from(r in schema, where: r.id == ^id), set: [inserted_at: stamp])
  end

  defp exists?(schema, id), do: Repo.exists?(from(r in schema, where: r.id == ^id))

  describe "abandoned registrations" do
    test "an old app nobody ever authorized is swept" do
      app = register_mastodon_app()
      age!(App, app.id, 30)

      assert %{apps: 1} = ApiAuth.sweep()
      refute exists?(App, app.id)
    end

    test "a fresh one is left alone, however useless it looks" do
      app = register_mastodon_app()

      assert %{apps: 0} = ApiAuth.sweep()
      assert exists?(App, app.id)
    end

    # The grant is the record of a member's consent. An app holding one can act
    # for somebody, whatever its age.
    test "an app a member authorized is kept forever" do
      app = register_mastodon_app()
      user = insert(:activated_user)
      Repo.insert!(%Grant{user_id: user.id, app_id: app.id, scopes: ["read"]})
      age!(App, app.id, 400)

      assert %{apps: 0} = ApiAuth.sweep()
      assert exists?(App, app.id)
    end

    # The trap this sweep exists to avoid. Calibrate by deleting the
    # `live_app_token_ids` clause from `sweep/0`: this test goes red and the one
    # below stays green, which is the whole difference between the two.
    test "an app holding a live client_credentials token is kept, grant or no grant" do
      app = register_mastodon_app()

      Repo.insert!(%AppToken{
        app_id: app.id,
        token_hash: ApiAuth.hash_token("vutuv_at_live"),
        scopes: ["read"]
      })

      age!(App, app.id, 400)

      assert %{apps: 0} = ApiAuth.sweep()
      assert exists?(App, app.id)
    end

    test "but a revoked one no longer protects it" do
      app = register_mastodon_app()

      Repo.insert!(%AppToken{
        app_id: app.id,
        token_hash: ApiAuth.hash_token("vutuv_at_dead"),
        scopes: ["read"],
        revoked_at: DateTime.utc_now(:second)
      })

      age!(App, app.id, 400)

      assert %{apps: 1} = ApiAuth.sweep()
      refute exists?(App, app.id)
    end

    # A developer's own app is registered by hand on /developers/apps and is not
    # an unattended client registration; it is theirs until they delete it.
    test "a native vutuv app is never touched" do
      developer = insert(:activated_user)

      {:ok, app, _secret} =
        ApiAuth.create_app(developer, %{
          "name" => "Native App",
          "redirect_uris" => ["https://native.example.org/oauth"]
        })

      age!(App, app.id, 400)

      assert %{apps: 0} = ApiAuth.sweep()
      assert exists?(App, app.id)
    end
  end

  describe "spent authorization codes" do
    setup do
      app = register_mastodon_app()
      user = insert(:activated_user)
      grant = Repo.insert!(%Grant{user_id: user.id, app_id: app.id, scopes: ["read"]})
      {:ok, app: app, user: user, grant: grant}
    end

    defp auth_code(ctx, attrs) do
      Repo.insert!(
        struct(
          %AuthCode{
            user_id: ctx.user.id,
            app_id: ctx.app.id,
            grant_id: ctx.grant.id,
            code_hash: ApiAuth.hash_token("vutuv_ac_" <> Ecto.UUID.generate()),
            redirect_uri: "org.example.client://oauth",
            scopes: ["read"],
            code_challenge: "mastodon-no-pkce",
            expires_at: DateTime.add(DateTime.utc_now(:second), 600)
          },
          attrs
        )
      )
    end

    test "an old code is swept", ctx do
      code = auth_code(ctx, %{})
      age!(AuthCode, code.id, 30)

      assert %{codes: 1} = ApiAuth.sweep()
      refute exists?(AuthCode, code.id)
    end

    # A code lives ten minutes, so a day-old one is long dead — but the row is
    # what makes a **replay** detectable: `consume_code/1` reads `used_at` and
    # revokes the whole grant's tokens when a code comes back twice. Delete the
    # row too soon and that theft signal answers "unknown code" instead.
    test "a recently spent one is kept, so a replay still trips the theft signal", ctx do
      code = auth_code(ctx, %{used_at: DateTime.utc_now(:second)})

      assert %{codes: 0} = ApiAuth.sweep()
      assert exists?(AuthCode, code.id)
    end

    test "a live code is kept", ctx do
      code = auth_code(ctx, %{})

      assert %{codes: 0} = ApiAuth.sweep()
      assert exists?(AuthCode, code.id)
    end
  end

  test "an empty database answers both counts rather than raising" do
    assert %{apps: 0, codes: 0} = ApiAuth.sweep()
  end
end
