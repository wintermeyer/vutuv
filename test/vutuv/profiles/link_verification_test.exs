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

  describe "check/3 via rel_me" do
    test "marks the link verified when the page links back to the profile" do
      user = insert(:activated_user)
      url = link(user)
      stub_body(~s(<a rel="me" href="#{VutuvWeb.Endpoint.url()}/#{user.username}">me</a>))

      assert {:ok, %Url{} = url} = LinkVerification.check(url, user, "rel_me")
      assert Url.verified?(url)
      assert url.verification_method == "rel_me"
      assert url.verified_at
    end

    test "reports what the page actually carries when the back-link is absent" do
      user = insert(:activated_user)
      url = link(user)
      stub_body(~s(<a rel="me" href="https://github.com/alice">gh</a>))

      assert {:error, report} = LinkVerification.check(url, user, "rel_me")
      refute Url.verified?(Repo.get!(Url, url.id))

      # The whole point of the report (issue #1466): not "we could not find the
      # proof yet", but the back-link the page does have beside the one wanted.
      assert report.method == "rel_me"
      assert report.status == 200
      assert report.found == ["https://github.com/alice"]
      assert report.expected == LinkVerification.profile_urls(user)
      refute report.disabled?
    end
  end

  describe "check/3 via dns / well_known" do
    test "dns marks the link verified when the TXT record is present" do
      user = insert(:activated_user)
      url = link(user) |> LinkVerification.ensure_token()
      stub_dns(url.verification_token)

      assert {:ok, url} = LinkVerification.check(url, user, "dns")
      assert url.verification_method == "dns"
    end

    test "dns verifies via the CNAME-safe _vutuv.<host> name when the host is a CNAME" do
      user = insert(:activated_user)
      # A host that is itself a CNAME cannot carry a bare-host TXT record, so the
      # member publishes it at _vutuv.<host> instead (issue #947).
      url =
        link(user, %{value: "https://changelog.alice.example/"})
        |> LinkVerification.ensure_token()

      expected = ~c"vutuv-verify=#{url.verification_token}"

      Application.put_env(:vutuv, :user_links_dns_resolver, fn
        "_vutuv.changelog.alice.example" -> [[expected]]
        _ -> []
      end)

      on_exit(fn -> Application.delete_env(:vutuv, :user_links_dns_resolver) end)

      assert {:ok, url} = LinkVerification.check(url, user, "dns")
      assert url.verification_method == "dns"
    end

    test "well_known marks the link verified when the file serves the token" do
      user = insert(:activated_user)
      url = link(user) |> LinkVerification.ensure_token()
      stub_body(url.verification_token <> "\n")

      assert {:ok, url} = LinkVerification.check(url, user, "well_known")
      assert url.verification_method == "well_known"
    end

    test "the dns report names both queried names and every TXT record it saw" do
      user = insert(:activated_user)
      # Deliberately NOT pre-tokened: a report for a link whose token was never
      # minted must still carry the fields the panel prints, or the page the
      # report exists for is a KeyError instead.
      url = link(user)
      Application.put_env(:vutuv, :user_links_dns_resolver, fn _host -> [[~c"v=spf1 -all"]] end)
      on_exit(fn -> Application.delete_env(:vutuv, :user_links_dns_resolver) end)

      assert {:error, report} = LinkVerification.check(url, user, "dns")
      assert report.method == "dns"
      assert report.names == ["alice.example", "_vutuv.alice.example"]
      assert report.found == ["v=spf1 -all"]

      # The check minted the token it needed, and the report quotes that one.
      assert report.expected == LinkVerification.dns_txt_value(Repo.get!(Url, url.id))
    end

    test "a failed check leaves the link's own check clock alone" do
      user = insert(:activated_user)
      # A link that is already verified must not have its weekly re-check pushed
      # out by a member re-running a method by hand: `last_checked_at` belongs to
      # the recheck sweeper's schedule, and a hand check is not one of its passes.
      url =
        link(user)
        |> LinkVerification.ensure_token()
        |> Ecto.Changeset.change(%{
          verified_at: ~N[2026-01-01 00:00:00],
          verification_method: "dns",
          last_checked_at: ~N[2026-01-01 00:00:00]
        })
        |> Repo.update!()

      Application.put_env(:vutuv, :user_links_dns_resolver, fn _host -> [] end)
      on_exit(fn -> Application.delete_env(:vutuv, :user_links_dns_resolver) end)

      assert {:error, _report} = LinkVerification.check(url, user, "dns")
      assert Repo.get!(Url, url.id).last_checked_at == ~N[2026-01-01 00:00:00]
    end
  end

  describe "check/3 when disabled" do
    test "says so in the report and never touches the network" do
      Application.put_env(:vutuv, :verify_user_links, false)
      user = insert(:activated_user)
      url = link(user)

      assert {:error, report} = LinkVerification.check(url, user, "rel_me")
      assert report.disabled?
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

  describe "links_due_for_recheck/1 (weekly cutoff)" do
    test "a link checked within the past week is not due; older than a week is" do
      user = insert(:activated_user)
      # verified_link/2 stamps last_checked_at two days ago — inside the weekly
      # window, so it must NOT be due (it would have been under the old 24h one).
      url = verified_link(user, "dns")
      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      refute url.id in Enum.map(LinkVerification.links_due_for_recheck(now), & &1.id)

      older =
        url
        |> Url.verification_changeset(%{last_checked_at: NaiveDateTime.add(now, -8 * 86_400)})
        |> Repo.update!()

      assert older.id in Enum.map(LinkVerification.links_due_for_recheck(now), & &1.id)
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
