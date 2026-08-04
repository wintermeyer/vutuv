defmodule VutuvWeb.EmailGreetingTest do
  @moduledoc """
  The line every email to a member opens with (`UserHelpers.email_greeting/1`).

  It reads `users.gender`. That field is asked for as a membership statistic, so
  this is the one place where the answer does something a member can notice, and
  the cases below are what that costs and what it buys.

  The point the assertions defend is that all three German outcomes are real
  greetings: a member who answers "divers" or answers nothing at all is greeted
  by name just as warmly as the two who get the classic form. That is not
  politeness, it is what keeps the statistic usable — the moment the neutral
  branch reads as a downgrade, answering becomes a way to get a better greeting
  rather than a statement, and the figures stop measuring anything.

  No clock is stubbed anywhere here, and that is itself the regression guard:
  the German branch used to open with a time-of-day greeting, so its output
  depended on the Europe/Berlin hour the suite happened to run in.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Accounts.User
  alias VutuvWeb.UserHelpers

  defp user(attrs), do: struct!(%User{locale: "de", first_name: "Max", last_name: "Meier"}, attrs)

  describe "German greeting" do
    test "\"female\" is addressed with the classic feminine form" do
      assert UserHelpers.email_greeting(user(gender: "female")) == "Liebe Frau Meier"
    end

    test "\"male\" is addressed with the classic masculine form" do
      assert UserHelpers.email_greeting(user(gender: "male")) == "Lieber Herr Meier"
    end

    test "\"diverse\" is greeted by name, never with an invented form of address" do
      # German has no established third form of address, and inventing one for
      # the members who answered "divers" would single them out in every mail
      # they get. The neutral greeting names them, which is the point.
      assert UserHelpers.email_greeting(user(gender: "diverse")) == "Hallo Max Meier"
    end

    test "no answer is greeted by full name, not left nameless" do
      assert UserHelpers.email_greeting(user(gender: nil)) == "Hallo Max Meier"
    end

    test "a gendered greeting without a surname falls back rather than trailing off" do
      # "Liebe Frau " is not a greeting, so the neutral branch has to catch it.
      assert UserHelpers.email_greeting(user(gender: "female", last_name: nil)) == "Hallo Max"
      assert UserHelpers.email_greeting(user(gender: "male", last_name: "  ")) == "Hallo Max"
    end

    test "an unknown stored value is treated as no answer" do
      # Including the vocabulary of the column this one replaced, which is what
      # a half-applied migration or an old row would leave behind.
      assert UserHelpers.email_greeting(user(gender: "mr")) == "Hallo Max Meier"
      assert UserHelpers.email_greeting(user(gender: "other")) == "Hallo Max Meier"
    end

    test "a member with no name at all still gets a greeting" do
      assert UserHelpers.email_greeting(user(first_name: nil, last_name: nil)) == "Hallo"
    end

    test "the greeting does not depend on the time of day" do
      # Ten reads across the same call must agree; the predecessor's opener
      # changed at 11:00 and 18:00 Berlin time, which made this function's
      # output a function of the wall clock.
      greetings = Enum.map(1..10, fn _ -> UserHelpers.email_greeting(user(gender: "female")) end)

      assert Enum.uniq(greetings) == ["Liebe Frau Meier"]
    end
  end

  describe "English greeting" do
    test "keeps the informal first-name greeting" do
      # Deliberately untouched: the classic form is a German convention, and
      # English opens with the first name whatever the member answered.
      assert UserHelpers.email_greeting(user(locale: "en", gender: "female")) == "Hi Max"
      assert UserHelpers.email_greeting(user(locale: "en", gender: nil)) == "Hi Max"
    end

    test "falls back to a bare greeting without a first name" do
      assert UserHelpers.email_greeting(user(locale: "en", first_name: nil)) == "Hi"
    end
  end

  test "an unknown locale falls back to a bare greeting" do
    assert UserHelpers.email_greeting(user(locale: "fr")) == "Hi"
  end
end
