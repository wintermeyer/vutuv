defmodule Vutuv.Profiles.LinkVerificationTest do
  @moduledoc """
  "This link is my webpage" verification: verify → mark, the disabled/not-found
  paths, and the periodic re-check grace window. `async: false` because the
  tests flip the global `:verify_user_links` flag and inject a DNS resolver /
  Req adapter.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Profiles.LinkVerification
  alias Vutuv.Profiles.Url
  alias Vutuv.Repo

  setup do
    Application.put_env(:vutuv, :verify_user_links, true)
    on_exit(fn -> Application.put_env(:vutuv, :verify_user_links, false) end)
    :ok
  end

  defp stub_dns(token) do
    expected = ~c"vutuv-verify=#{token}"
    Application.put_env(:vutuv, :user_links_dns_resolver, fn _host -> [[expected]] end)
    on_exit(fn -> Application.delete_env(:vutuv, :user_links_dns_resolver) end)
  end

  defp stub_body(body) do
    Application.put_env(:vutuv, :user_links_req_options,
      adapter: fn req -> {req, %Req.Response{status: 200, body: body}} end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :user_links_req_options) end)
  end

  defp link(user, attrs \\ %{}) do
    insert(:url, Map.merge(%{user: user, value: "https://alice.example/"}, attrs))
  end

  describe "verify/3 via rel_me" do
    test "marks the link verified when the page links back to the profile" do
      user = insert(:activated_user)
      url = link(user)
      stub_body(~s(<a rel="me" href="#{VutuvWeb.Endpoint.url()}/#{user.username}">me</a>))

      assert {:ok, %Url{} = url} = LinkVerification.verify(url, user, "rel_me")
      assert Url.verified?(url)
      assert url.verification_method == "rel_me"
      assert url.verified_at
    end

    test "returns :not_found when the back-link is absent" do
      user = insert(:activated_user)
      url = link(user)
      stub_body("<p>no back-link here</p>")

      assert {:error, :not_found} = LinkVerification.verify(url, user, "rel_me")
      refute Url.verified?(Repo.get!(Url, url.id))
    end
  end

  describe "verify/3 via dns / well_known" do
    test "dns marks the link verified when the TXT record is present" do
      user = insert(:activated_user)
      url = link(user) |> LinkVerification.ensure_token()
      stub_dns(url.verification_token)

      assert {:ok, url} = LinkVerification.verify(url, user, "dns")
      assert url.verification_method == "dns"
    end

    test "well_known marks the link verified when the file serves the token" do
      user = insert(:activated_user)
      url = link(user) |> LinkVerification.ensure_token()
      stub_body(url.verification_token <> "\n")

      assert {:ok, url} = LinkVerification.verify(url, user, "well_known")
      assert url.verification_method == "well_known"
    end
  end

  describe "verify/3 when disabled" do
    test "returns :disabled and never touches the network" do
      Application.put_env(:vutuv, :verify_user_links, false)
      user = insert(:activated_user)
      url = link(user)

      assert {:error, :disabled} = LinkVerification.verify(url, user, "rel_me")
    end
  end

  describe "ensure_token/1" do
    test "mints a token once and keeps it stable" do
      user = insert(:activated_user)
      url = link(user)
      assert is_nil(url.verification_token)

      url = LinkVerification.ensure_token(url)
      assert is_binary(url.verification_token)

      # A second call is a no-op (same token).
      assert LinkVerification.ensure_token(url).verification_token == url.verification_token
    end
  end

  describe "recheck/1 grace window" do
    test "a still-present proof refreshes last_checked_at and clears any grace" do
      user = insert(:activated_user)
      url = verified_link(user, "rel_me")
      stub_body(~s(<a rel="me" href="#{VutuvWeb.Endpoint.url()}/#{user.username}">me</a>))

      assert :ok = LinkVerification.recheck(%{url | user: user})
      assert Url.verified?(Repo.get!(Url, url.id))
    end

    test "a vanished proof starts a grace window, stays in grace, then demotes" do
      user = insert(:activated_user)
      url = verified_link(user, "rel_me")
      stub_body("<p>the back-link is gone</p>")
      reloaded = fn -> Repo.get!(Url, url.id) |> Repo.preload(:user) end

      # First failure: grace window opens, still verified.
      assert :grace_started = LinkVerification.recheck(%{url | user: user})
      in_grace = reloaded.()
      assert Url.verified?(in_grace)
      assert in_grace.grace_deadline_at

      # Still inside the window: stays verified.
      assert :in_grace = LinkVerification.recheck(in_grace)
      assert Url.verified?(reloaded.())

      # Deadline passed: the mark drops.
      past = %{reloaded.() | grace_deadline_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -1)}
      assert :demoted = LinkVerification.recheck(past)
      refute Url.verified?(reloaded.())
    end
  end

  # A link already verified via `method`, with a token and a recent check.
  defp verified_link(user, method) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    link(user)
    |> LinkVerification.ensure_token()
    |> Url.verification_changeset(%{
      verification_method: method,
      verified_at: now,
      last_checked_at: NaiveDateTime.add(now, -2 * 86_400)
    })
    |> Repo.update!()
    |> Repo.preload(:user)
  end
end
