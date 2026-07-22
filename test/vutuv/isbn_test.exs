defmodule Vutuv.IsbnTest do
  use ExUnit.Case, async: true

  alias Vutuv.Isbn

  describe "normalize/1" do
    test "accepts a hyphenated ISBN-13" do
      assert {:ok, "9783161484100"} = Isbn.normalize("978-3-16-148410-0")
    end

    test "accepts a bare ISBN-13" do
      assert {:ok, "9780306406157"} = Isbn.normalize("9780306406157")
    end

    test "accepts a 979-prefixed ISBN-13" do
      assert {:ok, "9798765432105"} = Isbn.normalize("979-8-7654-3210-5")
    end

    test "converts an ISBN-10 to its ISBN-13 form" do
      assert {:ok, "9783161484100"} = Isbn.normalize("3-16-148410-X")
      assert {:ok, "9780306406157"} = Isbn.normalize("0306406152")
    end

    test "accepts a lowercase x check digit" do
      assert {:ok, "9783161484100"} = Isbn.normalize("316148410x")
    end

    test "tolerates spaces and a leading ISBN label" do
      assert {:ok, "9783161484100"} = Isbn.normalize("ISBN 978 3 16 148410 0")
      assert {:ok, "9783161484100"} = Isbn.normalize("isbn: 978-3-16-148410-0")
    end

    test "rejects a wrong check digit" do
      assert :error = Isbn.normalize("978-3-16-148410-1")
      assert :error = Isbn.normalize("3-16-148410-0")
    end

    test "rejects wrong lengths and junk" do
      assert :error = Isbn.normalize("12345")
      assert :error = Isbn.normalize("")
      assert :error = Isbn.normalize("not-an-isbn")
      # An X anywhere but the last position of an ISBN-10 is invalid.
      assert :error = Isbn.normalize("31614841X0")
    end
  end

  describe "isbn10/1" do
    test "derives the ISBN-10 form of a 978 ISBN-13" do
      assert {:ok, "316148410X"} = Isbn.isbn10("9783161484100")
      assert {:ok, "0306406152"} = Isbn.isbn10("9780306406157")
    end

    test "a 979 ISBN-13 has no ISBN-10 form" do
      assert :error = Isbn.isbn10("9798765432105")
    end

    test "rejects anything that is not a normalized ISBN-13" do
      assert :error = Isbn.isbn10("316148410X")
      assert :error = Isbn.isbn10("junk")
    end
  end

  describe "format/1" do
    test "hyphenates a German ISBN into its five elements" do
      # Goldmann (registrant 442) — the form printed on the book itself.
      assert Isbn.format("9783442541683") == "978-3-442-54168-3"
      assert Isbn.format("9783161484100") == "978-3-16-148410-0"
    end

    test "hyphenates other registration groups" do
      # English language (group 0), and a two-digit group (94, Netherlands).
      assert Isbn.format("9780306406157") == "978-0-306-40615-7"
      assert Isbn.format("9789401799232") == "978-94-017-9923-2"
    end

    test "returns the input unchanged when the ranges do not resolve it" do
      # 978-6-70… is an unassigned EAN range: no split is knowable, so the
      # caller renders the bare digits rather than a made-up hyphenation.
      assert Isbn.format("9786700000004") == "9786700000004"
    end

    test "returns anything that is not a bare ISBN-13 unchanged" do
      assert Isbn.format("978-3-442-54168-3") == "978-3-442-54168-3"
      assert Isbn.format("316148410X") == "316148410X"
      assert Isbn.format("") == ""
      assert Isbn.format(nil) == nil
    end
  end
end
