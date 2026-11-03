defmodule Vutuv.Profiles.PublicationTest do
  @moduledoc "The publications profile section (issue #2350)."
  use Vutuv.DataCase, async: true

  alias Vutuv.Profiles.Publication

  defp changeset(params, model \\ %Publication{}), do: Publication.changeset(model, params)

  describe "changeset/2" do
    test "needs a title and nothing else" do
      assert changeset(%{"title" => "On Bridges"}).valid?
      refute changeset(%{"publisher" => "Nature"}).valid?
    end

    test "builds the slug from the title" do
      cs = changeset(%{"title" => "A Methodology for the Emulation of Architecture"})
      assert get_field(cs, :slug) =~ ~r/^a-methodology-for-the-emulation-of-architecture/
    end

    test "a month without a year is a half date" do
      cs = changeset(%{"title" => "x", "published_month" => 3})
      refute cs.valid?
      assert cs.errors[:published_year]

      assert changeset(%{"title" => "x", "published_month" => 3, "published_year" => 2020}).valid?

      refute changeset(%{"title" => "x", "published_month" => 13, "published_year" => 2020}).valid?
    end

    test "the year may run one ahead for a paper in press, not further" do
      next = Vutuv.BerlinTime.today().year + 1
      assert changeset(%{"title" => "x", "published_year" => next}).valid?
      refute changeset(%{"title" => "x", "published_year" => next + 1}).valid?
      refute changeset(%{"title" => "x", "published_year" => 1850}).valid?
    end

    test "a bare DOI becomes its resolver address" do
      for input <- ["10.5555/12345680", "doi:10.5555/12345680", "DOI: 10.5555/12345680"] do
        cs = changeset(%{"title" => "x", "url" => input})
        assert get_field(cs, :url) == "https://doi.org/10.5555/12345680", input
        assert cs.valid?
      end
    end

    test "a full address is kept, a non-web scheme refused" do
      cs = changeset(%{"title" => "x", "url" => "https://arxiv.org/abs/2301.00001"})
      assert get_field(cs, :url) == "https://arxiv.org/abs/2301.00001"
      refute changeset(%{"title" => "x", "url" => "javascript:alert(1)"}).valid?
    end

    test "caps every column so an oversized value is an error, not a 22001" do
      refute changeset(%{"title" => String.duplicate("x", 256)}).valid?
      refute changeset(%{"title" => "x", "publisher" => String.duplicate("x", 256)}).valid?
      refute changeset(%{"title" => "x", "authors" => String.duplicate("x", 2_001)}).valid?
    end

    test "the announcement choice is taken on create only" do
      new = changeset(%{"title" => "x", "announce_to_followers?" => "true"})
      assert get_field(new, :announce_to_followers?)

      existing = %Publication{id: Vutuv.UUIDv7.generate(), title: "x"}
      edit = changeset(%{"title" => "y", "announce_to_followers?" => "true"}, existing)
      refute get_field(edit, :announce_to_followers?)
    end
  end

  describe "ordered/1" do
    test "newest first, undated last, then by title" do
      user = insert(:user)
      insert(:publication, user: user, title: "Undated")
      insert(:publication, user: user, title: "Old", published_year: 2010)
      insert(:publication, user: user, title: "New", published_year: 2024, published_month: 5)
      insert(:publication, user: user, title: "Newer", published_year: 2024, published_month: 9)
      insert(:publication, user: user, title: "Also undated")

      titles =
        Publication.ordered()
        |> where([p], p.user_id == ^user.id)
        |> Repo.all()
        |> Enum.map(& &1.title)

      assert titles == ["Newer", "New", "Old", "Also undated", "Undated"]
    end
  end
end
