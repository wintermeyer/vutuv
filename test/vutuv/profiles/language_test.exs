defmodule Vutuv.Profiles.LanguageTest do
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.Languages
  alias Vutuv.Profiles.Language

  defp changeset(params) do
    Language.changeset(%Language{}, params)
  end

  describe "required fields" do
    test "a language code and a proficiency together are valid" do
      assert changeset(%{"language_code" => "en", "proficiency" => "b2"}).valid?
    end

    test "rejects a missing language code" do
      cs = changeset(%{"proficiency" => "b2"})
      refute cs.valid?
      assert %{language_code: [_]} = errors_on(cs)
    end

    test "rejects a missing proficiency" do
      cs = changeset(%{"language_code" => "en"})
      refute cs.valid?
      assert %{proficiency: [_]} = errors_on(cs)
    end
  end

  describe "language code" do
    test "accepts a known ISO 639-1 code" do
      assert changeset(%{"language_code" => "de", "proficiency" => "native"}).valid?
    end

    test "rejects a code outside the curated set" do
      cs = changeset(%{"language_code" => "xx", "proficiency" => "b2"})
      refute cs.valid?
      assert %{language_code: [_]} = errors_on(cs)
    end
  end

  describe "proficiency" do
    test "accepts every known level" do
      for level <- Language.proficiencies() do
        cs = changeset(%{"language_code" => "en", "proficiency" => level})
        assert cs.valid?, "expected #{level} to be valid"
      end
    end

    test "rejects an unknown level" do
      cs = changeset(%{"language_code" => "en", "proficiency" => "fluent"})
      refute cs.valid?
      assert %{proficiency: [_]} = errors_on(cs)
    end
  end

  describe "one entry per language per member" do
    test "rejects a duplicate language for the same user" do
      user = insert(:user)
      insert(:language, user: user, language_code: "en", proficiency: "native")

      {:error, cs} =
        user
        |> Ecto.build_assoc(:languages)
        |> Language.changeset(%{"language_code" => "en", "proficiency" => "b2"})
        |> Repo.insert()

      assert %{language_code: [_]} = errors_on(cs)
    end

    test "the same language for two different members is fine" do
      one = insert(:user)
      two = insert(:user)
      insert(:language, user: one, language_code: "en", proficiency: "native")

      assert {:ok, _} =
               two
               |> Ecto.build_assoc(:languages)
               |> Language.changeset(%{"language_code" => "en", "proficiency" => "c1"})
               |> Repo.insert()
    end
  end

  describe "ordered/1" do
    test "sorts highest proficiency first, then by language code" do
      user = insert(:user)
      insert(:language, user: user, language_code: "en", proficiency: "b2")
      insert(:language, user: user, language_code: "de", proficiency: "native")
      insert(:language, user: user, language_code: "fr", proficiency: "native")

      ordered =
        Language.ordered()
        |> where(user_id: ^user.id)
        |> Repo.all()
        |> Enum.map(&{&1.language_code, &1.proficiency})

      # native leads (de before fr within the level), then the B2.
      assert ordered == [{"de", "native"}, {"fr", "native"}, {"en", "b2"}]
    end
  end

  describe "Vutuv.Languages" do
    test "known?/1 gates the curated set" do
      assert Languages.known?("en")
      refute Languages.known?("xx")
    end

    test "name/1 returns the display name, falling back to the uppercased code" do
      assert Languages.name("en") == "English"
      assert Languages.name("zz") == "ZZ"
    end

    test "options/1 lists every code, sorted by name" do
      options = Languages.options()
      assert length(options) == length(Languages.codes())
      labels = Enum.map(options, &elem(&1, 0))
      assert labels == Enum.sort_by(labels, &String.downcase/1)
    end
  end
end
