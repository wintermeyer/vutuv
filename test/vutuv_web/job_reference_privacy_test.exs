defmodule VutuvWeb.JobReferencePrivacyTest do
  @moduledoc """
  A Zeugnis nobody published must not be visible to anybody but its owner —
  not to another member, not to a crawler, not through a machine format, not
  through the file proxy.

  This is the one claim in this section whose failure is a privacy incident
  rather than a bug: a Zeugnis carries a former employer's graded judgement of
  a named person, and the default is private precisely because publishing one
  by accident cannot be taken back.

  So the test is deliberately **blunt**: one private entry whose every field is
  a string that appears nowhere else, then every public surface asked for it,
  and the whole response searched for any of those strings. Blunt because a
  test that asserts on structure only proves the structure it imagined; this
  one fails whether the leak arrives through a card, a preload, an agent
  format, a future section that joins the wrong scope, or a stray debug dump.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  # Strings that exist nowhere else in the app or its fixtures, so a hit is a
  # leak and never a coincidence.
  @secret_title "Geheimzeugnis Zzyzx"
  @secret_employer "Zzyzx Sonderwerk GmbH"
  @secret_body "Ihre Leistungen waren zzyzx unbefriedigend."

  setup %{conn: conn} do
    # Registered rather than inserted: the owner has to be able to sign in, and
    # signing in here means the real PIN flow.
    {owner_conn, owner} = create_and_login_user(conn)

    private =
      insert(:job_reference,
        user: owner,
        title: @secret_title,
        employer: @secret_employer,
        body: @secret_body,
        public?: false
      )

    # A published one beside it, so a surface that shows nothing at all cannot
    # pass this test by accident.
    public =
      insert(:job_reference,
        user: owner,
        title: "Veroeffentlichtes Zeugnis",
        body: "Stets zu unserer vollsten Zufriedenheit.",
        public?: true,
        public_consented_at: DateTime.utc_now(:second)
      )

    %{owner: owner, owner_conn: owner_conn, private: private, public: public}
  end

  defp leaks?(body) do
    Enum.any?([@secret_title, @secret_employer, @secret_body], &String.contains?(body, &1))
  end

  # Every public surface a Zeugnis can reach, in the formats each is served in.
  defp public_paths(owner) do
    slug = owner.username

    [
      "/#{slug}",
      "/#{slug}.md",
      "/#{slug}.txt",
      "/#{slug}.json",
      "/#{slug}.xml",
      "/#{slug}/job_references",
      "/#{slug}/job_references.md",
      "/#{slug}/job_references.txt",
      "/#{slug}/job_references.json",
      "/#{slug}/job_references.xml",
      "/#{slug}/cv"
    ]
  end

  describe "an anonymous visitor (and every crawler)" do
    test "sees nothing of a private reference on any public surface", %{
      conn: conn,
      owner: owner
    } do
      for path <- public_paths(owner) do
        response = conn |> get(path) |> response(200)

        refute leaks?(response), "#{path} leaked a private employment reference"
      end
    end

    test "still sees the published one, so the check above is not vacuous", %{
      conn: conn,
      owner: owner
    } do
      body = conn |> get("/#{owner.username}/job_references") |> html_response(200)

      assert body =~ "Veroeffentlichtes Zeugnis"
    end

    test "cannot open a private reference by its id, in any format", %{
      conn: conn,
      owner: owner,
      private: private
    } do
      for ext <- ["", ".md", ".txt", ".json", ".xml"] do
        conn = get(conn, "/#{owner.username}/job_references/#{private.id}#{ext}")

        assert conn.status in [404, 302],
               "the private reference answered #{conn.status} for '#{ext}'"
      end
    end
  end

  describe "another signed-in member" do
    setup %{conn: conn} do
      {conn, _viewer} = create_and_login_user(conn)
      %{conn: conn}
    end

    test "sees nothing of it either", %{conn: conn, owner: owner} do
      for path <- public_paths(owner) do
        response = conn |> get(path) |> response(200)

        refute leaks?(response), "#{path} leaked a private employment reference to a member"
      end
    end

    test "cannot open it by id", %{conn: conn, owner: owner, private: private} do
      conn = get(conn, "/#{owner.username}/job_references/#{private.id}")
      assert conn.status in [404, 302]
    end
  end

  # A Zeugnis is about a job, so the profile says which one in both directions.
  # The link itself is a fact about a private document, so it may only appear
  # for a published one — a "reference for this role" marker on a job would
  # otherwise announce that a private Zeugnis exists and what it covers.
  describe "the link between a reference and the CV entry it documents" do
    setup %{owner: owner} do
      %{job: insert(:work_experience, user: owner, title: "Leiterin Zzyzx", organization: "ACME")}
    end

    test "a published reference names the job, and the job names it back", %{
      conn: conn,
      owner: owner,
      public: public,
      job: job
    } do
      Vutuv.References.put_links(public, [{:work_experience, job.id}])

      body = conn |> get("/#{owner.username}") |> html_response(200)

      assert body =~ "Leiterin Zzyzx"
      assert body =~ public.title
    end

    test "a private reference's link is invisible on the job", %{
      conn: conn,
      owner: owner,
      private: private,
      job: job
    } do
      Vutuv.References.put_links(private, [{:work_experience, job.id}])

      body = conn |> get("/#{owner.username}") |> html_response(200)

      # The role is on the profile; the private Zeugnis it documents is not,
      # and neither is the fact that it exists.
      assert body =~ "Leiterin Zzyzx"
      refute leaks?(body)
    end
  end

  # The owner's own pages are the one place it may appear, or the feature has
  # no editor. Asserted so a future "hide it everywhere" change cannot pass by
  # hiding it from its owner too.
  describe "the owner" do
    test "sees it in their own editor", %{owner_conn: conn} do
      conn = get(conn, ~p"/settings/job_references")

      assert html_response(conn, 200) =~ @secret_title
    end

    test "does not see it on their own public profile page", %{
      owner_conn: conn,
      owner: owner
    } do
      # The profile is a showcase, not an editor: it renders the published
      # scope for every viewer, the owner included.
      conn = get(conn, "/#{owner.username}/job_references")

      refute leaks?(html_response(conn, 200))
    end
  end
end
