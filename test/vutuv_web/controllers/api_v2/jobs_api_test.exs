defmodule VutuvWeb.ApiV2.JobsApiTest do
  use VutuvWeb.ConnCase

  alias Vutuv.ApiAuth
  alias Vutuv.Jobs
  alias Vutuv.JobsHelpers

  # A confirmed account old enough to clear the publish gate, plus a jobs:write
  # token. The `other` reader carries only jobs:read.
  setup %{conn: conn} do
    Vutuv.RateLimiter.reset()
    me = JobsHelpers.poster_fixture()
    other = insert_activated_user()

    {:ok, write, _} = ApiAuth.create_pat(me, %{"name" => "w", "scopes" => ["jobs:write"]})
    {:ok, read, _} = ApiAuth.create_pat(other, %{"name" => "r", "scopes" => ["jobs:read"]})

    {:ok, conn: conn, me: me, other: other, write: write, read: read}
  end

  # Full publish payload as a JSON body (string amounts like the form sends).
  defp publish_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Backend Engineer (m/w/d)",
        employment_type: "full_time",
        workplace_type: "onsite",
        zip_code: "50667",
        city: "Köln",
        country: "DE",
        salary_min: 55_000,
        salary_max: 70_000,
        salary_currency: "EUR",
        salary_period: "year",
        apply_kind: "url",
        apply_url: "https://example.com/apply",
        required_tags: "elixir, phoenix"
      },
      overrides
    )
  end

  describe "create" do
    test "POST /jobs without publish creates a draft", %{conn: conn, write: write} do
      conn = json_req(conn, :post, write, "/api/2.0/jobs", %{title: "Just a draft"})
      body = json_response(conn, 201)

      assert body["status"] == "draft"
      assert body["title"] == "Just a draft"
      assert is_binary(body["id"])
      # A draft has no expiry yet.
      assert body["expires_on"] == nil
    end

    test "POST /jobs with publish=true goes live with a 90-day expiry", %{
      conn: conn,
      write: write
    } do
      conn =
        json_req(conn, :post, write, "/api/2.0/jobs", Map.put(publish_attrs(), :publish, true))

      body = json_response(conn, 201)

      assert body["status"] == "published"
      assert body["location"]["city"] == "Köln"
      assert body["salary"]["min"] == 55_000
      assert body["street_address"] == nil
      expires = Date.from_iso8601!(body["expires_on"])
      assert Date.diff(expires, Vutuv.BerlinTime.today()) == Jobs.runtime_days()
      assert Enum.sort(Enum.map(body["required_tags"], & &1["name"])) == ["elixir", "phoenix"]
    end

    test "publishing an onsite posting with no salary and no location is a 422", %{
      conn: conn,
      me: me,
      write: write
    } do
      conn =
        json_req(conn, :post, write, "/api/2.0/jobs", %{
          title: "Incomplete",
          workplace_type: "onsite",
          apply_kind: "url",
          apply_url: "https://example.com/apply",
          publish: true
        })

      assert conn.status == 422
      errors = json_response(conn, 422)["errors"]
      assert errors["salary_min"]
      assert errors["city"]
      # The failed atomic publish leaves no orphan draft.
      assert Jobs.own_status_counts(me) == %{}
    end

    test "attributing a posting to an organization you cannot manage is a 403", %{
      conn: conn,
      other: other,
      write: write
    } do
      org = insert(:organization, created_by_user_id: other.id)

      conn =
        json_req(
          conn,
          :post,
          write,
          "/api/2.0/jobs",
          Map.put(publish_attrs(), :organization, org.slug)
        )

      assert conn.status == 403
      assert json_response(conn, 403)["reason"] == "attribution_denied"
    end
  end

  describe "the draft → publish flow (the smoke-test path)" do
    test "POST a draft, a bad publish stays a 422, then PATCH publishes it", %{
      conn: conn,
      me: me,
      write: write
    } do
      %{"id" => id} =
        json_response(json_req(conn, :post, write, "/api/2.0/jobs", %{title: "Grows up"}), 201)

      # Trying to publish the bare draft fails and keeps the draft.
      bad = json_req(build_conn(), :patch, write, "/api/2.0/jobs/#{id}", %{publish: true})
      assert bad.status == 422
      assert Jobs.get_job_posting(id).status == :draft

      good =
        json_req(
          build_conn(),
          :patch,
          write,
          "/api/2.0/jobs/#{id}",
          Map.put(publish_attrs(%{title: "Grows up"}), :publish, true)
        )

      assert json_response(good, 200)["status"] == "published"
      assert Jobs.get_job_posting(id).status == :published
      assert Jobs.get_job_posting(id).user_id == me.id
    end
  end

  describe "read" do
    test "GET /jobs/:id returns status and dates; the owner sees a draft", %{
      conn: conn,
      me: me,
      write: write,
      read: read
    } do
      {:ok, draft} = Jobs.create_draft(me, %{"title" => "Owner draft"})

      # The owner reads their own draft.
      mine = get(authed(conn, write), "/api/2.0/jobs/#{draft.id}")
      assert json_response(mine, 200)["status"] == "draft"

      # A stranger cannot see a draft.
      theirs = get(authed(build_conn(), read), "/api/2.0/jobs/#{draft.id}")
      assert theirs.status == 404
    end

    test "a stranger sees a published posting but not an expired one", %{
      conn: _conn,
      me: me,
      read: read
    } do
      live = JobsHelpers.publish_job!(me)
      assert get(authed(build_conn(), read), "/api/2.0/jobs/#{live.id}").status == 200

      expired = JobsHelpers.publish_job!(me)
      {:ok, _} = expired |> Ecto.Changeset.change(status: :expired) |> Vutuv.Repo.update()
      assert get(authed(build_conn(), read), "/api/2.0/jobs/#{expired.id}").status == 404
    end

    test "GET /jobs lists published postings and filters by salary", %{
      conn: conn,
      me: me,
      read: read
    } do
      JobsHelpers.publish_job!(me, %{"title" => "Well paid", "salary_max" => "90000"})

      JobsHelpers.publish_job!(me, %{
        "title" => "Modest",
        "salary_min" => "30000",
        "salary_max" => "40000"
      })

      all = json_response(get(authed(conn, read), "/api/2.0/jobs"), 200)
      assert all["type"] == "jobs"
      assert length(all["jobs"]) == 2
      assert Enum.all?(all["jobs"], &is_binary(&1["id"]))

      filtered =
        json_response(get(authed(build_conn(), read), "/api/2.0/jobs?salary_min=80000"), 200)

      assert Enum.map(filtered["jobs"], & &1["title"]) == ["Well paid"]
    end

    test "GET /jobs pages by cursor", %{conn: conn, me: me, read: read} do
      for n <- 1..3, do: JobsHelpers.publish_job!(me, %{"title" => "Role #{n}"})

      page1 = json_response(get(authed(conn, read), "/api/2.0/jobs?limit=2"), 200)
      assert length(page1["jobs"]) == 2
      assert page1["more"] == true
      assert is_binary(page1["next_cursor"])

      page2 =
        json_response(
          get(
            authed(build_conn(), read),
            "/api/2.0/jobs?limit=2&cursor=#{URI.encode_www_form(page1["next_cursor"])}"
          ),
          200
        )

      assert length(page2["jobs"]) == 1
      assert page2["more"] == false
    end
  end

  describe "edit" do
    test "PATCH edits an own live posting", %{conn: conn, me: me, write: write} do
      posting = JobsHelpers.publish_job!(me)

      conn =
        json_req(conn, :patch, write, "/api/2.0/jobs/#{posting.id}", %{title: "Renamed role"})

      assert json_response(conn, 200)["title"] == "Renamed role"
    end

    test "PATCH on a closed posting is a clean 409", %{conn: conn, me: me, write: write} do
      posting = JobsHelpers.publish_job!(me)
      {:ok, _} = Jobs.close(posting, :filled)

      conn = json_req(conn, :patch, write, "/api/2.0/jobs/#{posting.id}", %{title: "Reopen?"})
      assert conn.status == 409
      assert json_response(conn, 409)["reason"] == "not_editable"
    end

    test "cannot edit someone else's posting", %{conn: conn, other: other, write: write} do
      posting = JobsHelpers.publish_job!(JobsHelpers.poster_fixture())
      _ = other

      conn = json_req(conn, :patch, write, "/api/2.0/jobs/#{posting.id}", %{title: "hijack"})
      assert conn.status == 404
    end
  end

  describe "closure and deletion" do
    test "POST /jobs/:id/closure closes a live posting", %{conn: conn, me: me, write: write} do
      posting = JobsHelpers.publish_job!(me)

      conn =
        json_req(conn, :post, write, "/api/2.0/jobs/#{posting.id}/closure", %{reason: "filled"})

      assert json_response(conn, 200)["status"] == "closed"
      assert Jobs.get_job_posting(posting.id).close_reason == :filled
    end

    test "closure rejects an unknown reason", %{conn: conn, me: me, write: write} do
      posting = JobsHelpers.publish_job!(me)

      conn =
        json_req(conn, :post, write, "/api/2.0/jobs/#{posting.id}/closure", %{reason: "bored"})

      assert conn.status == 422
    end

    test "DELETE discards a draft but refuses a published posting", %{
      conn: conn,
      me: me,
      write: write
    } do
      {:ok, draft} = Jobs.create_draft(me, %{"title" => "throwaway"})
      assert delete(authed(conn, write), "/api/2.0/jobs/#{draft.id}").status == 204
      assert Jobs.get_job_posting(draft.id) == nil

      live = JobsHelpers.publish_job!(me)
      refused = delete(authed(build_conn(), write), "/api/2.0/jobs/#{live.id}")
      assert refused.status == 409
      assert Jobs.get_job_posting(live.id)
    end
  end

  describe "scopes" do
    test "jobs:read reads but cannot write", %{conn: conn, me: me, read: read} do
      posting = JobsHelpers.publish_job!(me)

      assert get(authed(conn, read), "/api/2.0/jobs/#{posting.id}").status == 200
      assert json_req(build_conn(), :post, read, "/api/2.0/jobs", %{title: "x"}).status == 403
    end

    test "a token without a jobs scope is refused", %{conn: conn, me: me} do
      {:ok, profile_only, _} =
        ApiAuth.create_pat(me, %{"name" => "p", "scopes" => ["profile:read"]})

      posting = JobsHelpers.publish_job!(me)
      assert get(authed(conn, profile_only), "/api/2.0/jobs/#{posting.id}").status == 403
    end
  end

  describe "organizations" do
    test "GET /organizations lists verified organizations and filters by ?q=", %{
      conn: conn,
      read: read
    } do
      insert(:organization, name: "Acme Rockets", slug: "acme-rockets")
      insert(:organization, name: "Globex", slug: "globex")

      all = json_response(get(authed(conn, read), "/api/2.0/organizations"), 200)
      assert all["total"] == 2

      filtered =
        json_response(get(authed(build_conn(), read), "/api/2.0/organizations?q=Acme"), 200)

      assert Enum.map(filtered["organizations"], & &1["name"]) == ["Acme Rockets"]
    end

    test "GET /organizations/:slug returns the page with aliases and domains", %{
      conn: conn,
      read: read
    } do
      org = insert(:organization, name: "Acme Corp", slug: "acme-corp")

      body = json_response(get(authed(conn, read), "/api/2.0/organizations/#{org.slug}"), 200)
      assert body["name"] == "Acme Corp"
      assert body["slug"] == "acme-corp"
      assert is_list(body["verified_domains"])
      assert is_list(body["aliases"])
    end

    test "GET /organizations/:slug also resolves a claimed root handle", %{conn: conn, read: read} do
      # A handle-holding organization is canonical at /:handle, and the listing's
      # url points there — so the show endpoint must resolve by handle too.
      org = insert(:organization, name: "Handle Co", slug: "handle-co", username: "handleco")

      body = json_response(get(authed(conn, read), "/api/2.0/organizations/#{org.username}"), 200)
      assert body["name"] == "Handle Co"
    end

    test "an unknown organization is a 404", %{conn: conn, read: read} do
      assert get(authed(conn, read), "/api/2.0/organizations/nope").status == 404
    end
  end
end
