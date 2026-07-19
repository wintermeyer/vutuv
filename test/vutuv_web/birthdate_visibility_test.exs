defmodule VutuvWeb.BirthdateVisibilityTest do
  @moduledoc """
  The birthday-visibility setting (full / age only / day+month / hidden) must
  gate the birthday consistently across every PUBLIC surface: the profile card,
  the md/txt/json/xml/vCard agent siblings, and the public CV builder. Both
  sides of each gate are asserted here — what shows and, just as important, what
  must never leak (the year, the age, or the whole date).

  The birthdate is 1990-04-23 and the factory locale is "en", so the profile
  renders the date as "04/23/1990" and the day-month as "04/23". Negative
  assertions lean on strings that carry a "/" (never present in the base64url
  LiveView tokens) rather than the bare year to stay token-collision-proof.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Repo
  alias VutuvWeb.UserHelpers

  @born ~D[1990-04-23]

  defp profile_with(visibility) do
    insert_activated_user(
      username: "born_#{visibility}",
      first_name: "Bea",
      last_name: "Born",
      birthdate: @born,
      birthdate_visibility: visibility
    )
  end

  defp formats(user) do
    path = "/" <> user.username

    %{
      html: build_conn() |> get(path) |> html_response(200),
      md: get(build_conn(), path <> ".md").resp_body,
      txt: get(build_conn(), path <> ".txt").resp_body,
      json: Jason.decode!(get(build_conn(), path <> ".json").resp_body),
      xml: get(build_conn(), path <> ".xml").resp_body,
      vcf: get(build_conn(), path <> ".vcf").resp_body
    }
  end

  test "\"full\" shows the date and the derived age everywhere (the default)" do
    user = profile_with("full")
    age = UserHelpers.age(user)
    r = formats(user)

    assert r.html =~ "04/23/1990"
    assert r.html =~ "#{age} year"

    assert r.md =~ "Birthday: 1990-04-23"
    assert r.md =~ "Age: #{age}"
    assert r.txt =~ "Birthday: 1990-04-23"
    assert r.txt =~ "Age: #{age}"

    assert r.json["birthdate"] == "1990-04-23"
    assert r.json["age"] == age
    assert r.json["birthday_month_day"] == nil

    assert r.xml =~ "<birthdate>1990-04-23</birthdate>"
    assert r.xml =~ "<age>#{age}</age>"

    assert r.vcf =~ "BDAY:1990-04-23"
  end

  test "\"age\" shows only the age, never the date" do
    user = profile_with("age")
    age = UserHelpers.age(user)
    r = formats(user)

    assert r.html =~ "#{age} year"
    # No date at all, so neither the full date nor the day-month appears.
    refute r.html =~ "04/23"

    refute r.md =~ "Birthday:"
    assert r.md =~ "Age: #{age}"
    refute r.txt =~ "Birthday:"
    assert r.txt =~ "Age: #{age}"

    assert r.json["age"] == age
    assert r.json["birthdate"] == nil
    assert r.json["birthday_month_day"] == nil

    refute r.vcf =~ "BDAY:"
  end

  test "\"day_month\" shows the day and month but never the year or the age" do
    user = profile_with("day_month")
    r = formats(user)

    assert r.html =~ "04/23"
    # The year (and therefore the age) is gone: the full date and the age line
    # must both be absent.
    refute r.html =~ "04/23/1990"
    refute r.html =~ "year old"

    assert r.md =~ "Birthday: 04-23"
    refute r.md =~ "Age:"
    assert r.txt =~ "Birthday: 04-23"
    refute r.txt =~ "Age:"

    assert r.json["birthday_month_day"] == "04-23"
    assert r.json["birthdate"] == nil
    assert r.json["age"] == nil
    assert r.xml =~ "<birthday_month_day>04-23</birthday_month_day>"

    # vCard 3.0 BDAY needs a year, so a year-less birthday carries no BDAY.
    refute r.vcf =~ "BDAY:"
  end

  test "\"hidden\" shows nothing publicly, yet keeps the stored birthday" do
    user = profile_with("hidden")
    r = formats(user)

    refute r.html =~ "04/23"
    refute r.html =~ "year old"
    refute r.md =~ "Birthday:"
    refute r.md =~ "Age:"
    refute r.txt =~ "Birthday:"
    refute r.txt =~ "Age:"

    assert r.json["birthdate"] == nil
    assert r.json["age"] == nil
    assert r.json["birthday_month_day"] == nil
    refute r.vcf =~ "BDAY:"

    # Hidden is about display, not deletion: the value is still stored so the
    # member can flip the setting back or use it in their own GDPR export.
    assert Repo.reload(user).birthdate == @born
  end

  describe "the public CV (/:slug/cv) never reveals more than the profile" do
    test "full keeps the date, day_month drops the year, age/hidden drop the DOB line" do
      assert VutuvWeb.CV.build(profile_with("full")).birthdate =~ "1990"
      assert VutuvWeb.CV.build(profile_with("day_month")).birthdate == "04/23"
      assert VutuvWeb.CV.build(profile_with("age")).birthdate == nil
      assert VutuvWeb.CV.build(profile_with("hidden")).birthdate == nil
    end
  end
end
