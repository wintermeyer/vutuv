defmodule Vutuv.Profiles.QualificationTest do
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.Profiles.Qualification

  defp changeset(params) do
    Qualification.changeset(%Qualification{}, params)
  end

  describe "required fields" do
    test "a name and a kind together are valid" do
      assert changeset(%{"name" => "AWS Solutions Architect", "kind" => "certification"}).valid?
    end

    test "rejects a missing name" do
      cs = changeset(%{"kind" => "certification"})
      refute cs.valid?
      assert %{name: [_]} = errors_on(cs)
    end

    test "a blank kind falls back to the certification default" do
      cs = changeset(%{"name" => "Approbation", "kind" => ""})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :kind) == "certification"
    end
  end

  describe "kind" do
    test "accepts certification and license" do
      for kind <- Qualification.kinds() do
        assert changeset(%{"name" => "X", "kind" => kind}).valid?, "expected #{kind} to be valid"
      end
    end

    test "rejects an unknown kind" do
      cs = changeset(%{"name" => "X", "kind" => "diploma"})
      refute cs.valid?
      assert %{kind: [_]} = errors_on(cs)
    end
  end

  describe "length caps (the varchar(255) guard against Postgres 22001)" do
    test "rejects an oversized name" do
      cs = changeset(%{"name" => String.duplicate("a", 256), "kind" => "certification"})
      refute cs.valid?
      assert %{name: [_]} = errors_on(cs)
    end

    test "rejects an oversized issuer" do
      cs =
        changeset(%{
          "name" => "X",
          "kind" => "certification",
          "issuer" => String.duplicate("a", 256)
        })

      refute cs.valid?
      assert %{issuer: [_]} = errors_on(cs)
    end
  end

  describe "url" do
    test "accepts an http(s) verification link" do
      assert changeset(%{
               "name" => "X",
               "kind" => "certification",
               "url" => "https://verify.example.org/abc"
             }).valid?
    end

    test "rejects a javascript: scheme (stored XSS on the public profile)" do
      cs =
        changeset(%{"name" => "X", "kind" => "certification", "url" => "javascript:alert(1)"})

      refute cs.valid?
      assert %{url: [_]} = errors_on(cs)
    end
  end

  describe "dates" do
    test "an awarded and expiry year are valid" do
      assert changeset(%{
               "name" => "X",
               "kind" => "certification",
               "awarded_year" => 2023,
               "expires_year" => 2026
             }).valid?
    end

    test "allows a future expiry (a licence valid for years)" do
      future = Vutuv.BerlinTime.today().year + 5

      assert changeset(%{
               "name" => "X",
               "kind" => "license",
               "awarded_year" => 2023,
               "expires_year" => future
             }).valid?
    end

    test "rejects an award date in the future" do
      future = Vutuv.BerlinTime.today().year + 1

      cs = changeset(%{"name" => "X", "kind" => "certification", "awarded_year" => future})
      refute cs.valid?
      assert %{awarded_year: [_]} = errors_on(cs)
    end

    test "rejects a month without its year" do
      cs = changeset(%{"name" => "X", "kind" => "certification", "awarded_month" => 3})
      refute cs.valid?
      assert %{awarded_year: [_]} = errors_on(cs)
    end

    test "rejects an expiry before the award" do
      cs =
        changeset(%{
          "name" => "X",
          "kind" => "certification",
          "awarded_year" => 2023,
          "expires_year" => 2020
        })

      refute cs.valid?
      assert %{expires_year: [_]} = errors_on(cs)
    end
  end

  describe "expired?/2" do
    test "an entry with no expiry never expires" do
      refute Qualification.expired?(%Qualification{expires_year: nil}, ~D[2026-07-05])
    end

    test "an expiry year in the past is expired" do
      assert Qualification.expired?(%Qualification{expires_year: 2024}, ~D[2026-07-05])
    end

    test "the whole expiry year is still valid" do
      refute Qualification.expired?(%Qualification{expires_year: 2026}, ~D[2026-07-05])
    end

    test "an expiry month is valid through that month, then expired" do
      qual = %Qualification{expires_year: 2026, expires_month: 6}
      assert Qualification.expired?(qual, ~D[2026-07-05])
      refute Qualification.expired?(qual, ~D[2026-06-30])
    end
  end

  describe "job_usage/1 (issue #1005)" do
    alias Vutuv.Profiles.WorkExperience

    test "nil when the citing jobs were not preloaded" do
      assert Qualification.job_usage(%Qualification{}) == nil
    end

    test "nil when no job cites the credential" do
      assert Qualification.job_usage(%Qualification{work_experiences: []}) == nil
    end

    test "counts the citing jobs and marks an ongoing one as current" do
      qual = %Qualification{
        work_experiences: [
          %WorkExperience{end_year: nil},
          %WorkExperience{end_year: 2019, end_month: 9}
        ]
      }

      assert %{count: 2, current?: true} = Qualification.job_usage(qual)
    end

    test "a credential only past jobs cite reports the newest end date" do
      qual = %Qualification{
        work_experiences: [
          %WorkExperience{end_year: 2016, end_month: 12},
          %WorkExperience{end_year: 2019, end_month: 9}
        ]
      }

      assert %{count: 2, current?: false, last_end: {2019, 9}} = Qualification.job_usage(qual)
    end

    test "a year-only end date counts as the whole year (beats earlier months)" do
      qual = %Qualification{
        work_experiences: [
          %WorkExperience{end_year: 2019, end_month: 3},
          %WorkExperience{end_year: 2019, end_month: nil}
        ]
      }

      assert %{last_end: {2019, nil}} = Qualification.job_usage(qual)
    end

    test "a job with no dates at all reads as ongoing (no known end)" do
      qual = %Qualification{work_experiences: [%WorkExperience{}]}

      assert %{count: 1, current?: true} = Qualification.job_usage(qual)
    end
  end

  describe "ordered/1" do
    test "sorts most recently awarded first, undated last, then by name" do
      user = insert(:user)
      insert(:qualification, user: user, name: "Older", awarded_year: 2019)
      insert(:qualification, user: user, name: "Newest", awarded_year: 2024)
      insert(:qualification, user: user, name: "Undated", awarded_year: nil)

      names =
        Qualification.ordered()
        |> where(user_id: ^user.id)
        |> Repo.all()
        |> Enum.map(& &1.name)

      assert names == ["Newest", "Older", "Undated"]
    end
  end

  describe "visible_to/2" do
    test "an owner sees expired entries; a visitor does not" do
      user = insert(:user)
      insert(:qualification, user: user, name: "Current", expires_year: nil)
      insert(:qualification, user: user, name: "Lapsed", awarded_year: 2015, expires_year: 2018)

      owner_names =
        Qualification.visible_to(true)
        |> where(user_id: ^user.id)
        |> Repo.all()
        |> Enum.map(& &1.name)

      visitor_names =
        Qualification.visible_to(false)
        |> where(user_id: ^user.id)
        |> Repo.all()
        |> Enum.map(& &1.name)

      assert "Lapsed" in owner_names
      assert "Current" in visitor_names
      refute "Lapsed" in visitor_names
    end
  end
end
