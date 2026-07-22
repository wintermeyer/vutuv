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
end
