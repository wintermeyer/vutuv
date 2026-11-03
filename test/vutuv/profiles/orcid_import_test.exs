defmodule Vutuv.Profiles.OrcidImportTest do
  @moduledoc """
  "Import from ORCID" on the publications editor (issue #2383).

  Not async: the feature flag (`:import_orcid_works`) and the Req seam
  (`:orcid_req_options`) both live in the application env, which the SQL
  sandbox does not roll back. The flag is read only by `Vutuv.Orcid` and
  `Vutuv.Profiles.OrcidImport`.
  """
  use Vutuv.DataCase

  import Ecto.Query

  alias Vutuv.Profiles.OrcidImport
  alias Vutuv.Profiles.Publication

  @id "0000-0002-1825-0097"

  defp enable do
    Application.put_env(:vutuv, :import_orcid_works, true)
    on_exit(fn -> Application.put_env(:vutuv, :import_orcid_works, false) end)
  end

  # The two API answers (summary groups, then the bulk detail) for the given
  # works, each `{put_code, title, attrs}`.
  defp serve_works(works) do
    groups =
      for {put_code, _title, _attrs} <- works,
          do: %{"work-summary" => [%{"put-code" => put_code}]}

    bulk =
      for {put_code, title, attrs} <- works do
        %{
          "work" =>
            Map.merge(
              %{
                "put-code" => put_code,
                "title" => %{"title" => %{"value" => title}},
                "type" => "journal-article",
                "publication-date" => %{"year" => %{"value" => "2020"}, "month" => nil}
              },
              attrs
            )
        }
      end

    Application.put_env(:vutuv, :orcid_req_options,
      plug: fn conn ->
        body =
          if String.ends_with?(conn.request_path, "/works"),
            do: %{"group" => groups},
            else: %{"bulk" => bulk}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :orcid_req_options) end)
  end

  defp member_with_orcid do
    user = insert_activated_user()
    insert(:social_media_account, provider: "ORCID", value: @id, user: user)
    user
  end

  describe "offer/1" do
    test "needs the switch on and an ORCID iD on the profile" do
      user = insert_activated_user()
      assert OrcidImport.offer(user) == :disabled

      enable()
      assert OrcidImport.offer(user) == :no_account

      insert(:social_media_account, provider: "ORCID", value: @id, user: user)
      assert OrcidImport.offer(user) == :available
    end
  end

  describe "candidates/1" do
    setup do
      enable()
      :ok
    end

    test "lists the record's works, marks what the profile already has, folds a repeated title" do
      user = member_with_orcid()
      insert(:publication, user: user, title: "On Bridges", slug: "on-bridges")

      serve_works([
        {1, "On Bridges", %{"journal-title" => %{"value" => "Span Review"}}},
        {2, "Load Paths", %{"type" => "preprint"}},
        {3, "load paths", %{}}
      ])

      assert {:ok, [bridges, paths]} = OrcidImport.candidates(user)

      assert bridges.duplicate?
      refute bridges.select?
      assert bridges.facts == "Span Review · 2020"
      assert bridges.params["title"] == "On Bridges"

      refute paths.duplicate?
      assert paths.select?
      assert paths.type == "preprint"
    end

    test "a member without an ORCID iD, and an installation with the import off" do
      user = insert_activated_user()
      assert {:error, :no_account} = OrcidImport.candidates(user)

      Application.put_env(:vutuv, :import_orcid_works, false)
      assert {:error, :disabled} = OrcidImport.candidates(member_with_orcid())
    end

    test "an outage is transient, not an empty record" do
      user = member_with_orcid()

      Application.put_env(:vutuv, :orcid_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 500, "") end
      )

      on_exit(fn -> Application.delete_env(:vutuv, :orcid_req_options) end)

      assert {:error, :transient} = OrcidImport.candidates(user)
    end
  end

  describe "apply_selection/2" do
    setup do
      enable()
      :ok
    end

    test "inserts the picks once, keyed by title, and reports what it skipped" do
      user = member_with_orcid()
      insert(:publication, user: user, title: "On Bridges", slug: "on-bridges")

      serve_works([
        {1, "On Bridges", %{}},
        {2, "Load Paths",
         %{
           "journal-title" => %{"value" => "Nature"},
           "external-ids" => %{
             "external-id" => [
               %{"external-id-type" => "doi", "external-id-value" => "10.5555/paths"}
             ]
           },
           "contributors" => %{
             "contributor" => [%{"credit-name" => %{"value" => "Gradient, G."}}]
           }
         }},
        {3, "Unticked", %{}}
      ])

      {:ok, candidates} = OrcidImport.candidates(user)
      payload = candidates |> OrcidImport.payload_map() |> Jason.encode!() |> Jason.decode!()

      # The member ticks the duplicate too (the box is only unticked by default).
      selected = candidates |> Enum.take(2) |> Enum.map(& &1.id)
      selection = OrcidImport.selection_from_payload(payload, selected)

      assert {:ok, %{created: 1, skipped: 1, blocked: 0}} =
               OrcidImport.apply_selection(user, selection)

      rows =
        from(p in Publication, where: p.user_id == ^user.id, order_by: p.title)
        |> Repo.all()
        |> Enum.map(&{&1.title, &1.authors, &1.publisher, &1.published_year, &1.url})

      assert rows == [
               {"Load Paths", "Gradient, G.", "Nature", 2020, "https://doi.org/10.5555/paths"},
               {"On Bridges", nil, nil, nil, nil}
             ]

      # A second run of the same selection adds nothing.
      assert {:ok, %{created: 0, skipped: 2}} = OrcidImport.apply_selection(user, selection)
    end

    test "a tampered payload can only add to the member's own profile, and a bad value is blocked" do
      user = member_with_orcid()
      stranger = insert_activated_user()

      selection =
        OrcidImport.selection_from_payload(
          [
            %{"id" => "x", "params" => %{"title" => "Mine", "user_id" => stranger.id}},
            %{"id" => "y", "params" => %{"title" => String.duplicate("x", 300)}}
          ],
          ["x", "y"]
        )

      assert {:ok, %{created: 1, skipped: 0, blocked: 1}} =
               OrcidImport.apply_selection(user, selection)

      assert [%{user_id: user_id}] = Repo.all(from(p in Publication, where: p.title == "Mine"))
      assert user_id == user.id
    end
  end
end
