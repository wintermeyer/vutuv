defmodule VutuvWeb.EmailGreetingTest do
  @moduledoc """
  The line every email to a member opens with (`UserHelpers.email_greeting/1`).

  This is the only consumer the `salutation` field has, so these cases are the
  whole reason the field exists. The point the assertions defend is that all
  three German outcomes are real salutations: a member who declines to state one
  is greeted by name just as warmly as the two who state one, because a neutral
  branch that reads as a downgrade puts pressure back on the choice the sign-up
  form deliberately leaves open.

  No clock is stubbed anywhere here, and that is itself the regression guard:
  the German branch used to open with a time-of-day greeting, so its output
  depended on the Europe/Berlin hour the suite happened to run in.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Accounts.User
  alias VutuvWeb.UserHelpers

  defp user(attrs), do: struct!(%User{locale: "de", first_name: "Max", last_name: "Meier"}, attrs)

  describe "German salutation" do
    test "\"ms\" is addressed with the classic feminine form" do
      assert UserHelpers.email_greeting(user(salutation: "ms")) == "Liebe Frau Meier"
    end

    test "\"mr\" is addressed with the classic masculine form" do
      assert UserHelpers.email_greeting(user(salutation: "mr")) == "Lieber Herr Meier"
    end

    test "no salutation is greeted by full name, not left nameless" do
      assert UserHelpers.email_greeting(user(salutation: nil)) == "Hallo Max Meier"
    end

    test "a salutation without a surname falls back rather than trailing off" do
      # "Liebe Frau " is not a greeting, so the neutral branch has to catch it.
      assert UserHelpers.email_greeting(user(salutation: "ms", last_name: nil)) == "Hallo Max"
      assert UserHelpers.email_greeting(user(salutation: "mr", last_name: "  ")) == "Hallo Max"
    end

    test "an unknown stored value is treated as no salutation" do
      assert UserHelpers.email_greeting(user(salutation: "male")) == "Hallo Max Meier"
    end

    test "a member with no name at all still gets a greeting" do
      assert UserHelpers.email_greeting(user(first_name: nil, last_name: nil)) == "Hallo"
    end

    test "the greeting does not depend on the time of day" do
      # Ten reads across the same call must agree; the predecessor's opener
      # changed at 11:00 and 18:00 Berlin time, which made this function's
      # output a function of the wall clock.
      greetings =
        Enum.map(1..10, fn _ -> UserHelpers.email_greeting(user(salutation: "ms")) end)

      assert Enum.uniq(greetings) == ["Liebe Frau Meier"]
    end
  end

  describe "English salutation" do
    test "keeps the informal first-name greeting" do
      # Deliberately unchanged by the salutation work: the classic form was
      # asked for in German, and the salutation drives nothing here.
      assert UserHelpers.email_greeting(user(locale: "en", salutation: "ms")) == "Hi Max"
      assert UserHelpers.email_greeting(user(locale: "en", salutation: nil)) == "Hi Max"
    end

    test "falls back to a bare greeting without a first name" do
      assert UserHelpers.email_greeting(user(locale: "en", first_name: nil)) == "Hi"
    end
  end

  test "an unknown locale falls back to a bare greeting" do
    assert UserHelpers.email_greeting(user(locale: "fr")) == "Hi"
  end
end
