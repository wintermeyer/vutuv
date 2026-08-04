defmodule VutuvWeb.GenderPrivacyTest do
  @moduledoc """
  `users.gender` is kept for one purpose, the membership statistic at /admin,
  and the promise the sign-up form makes in exchange for the answer is that it
  appears nowhere else. This file is that promise as a test.

  It matters more than the usual "field is private" guard for two reasons. The
  column is called `gender` again after being dropped for reading as a public
  classification, so the obvious next change someone makes is to render it
  on a profile beside the name — and every public surface here is
  generated from a doc builder or a component that is easy to extend without
  noticing which side of the line it sits on. And the answer is voluntary: the
  moment it shows up on a profile or a CV, members answer it strategically or
  not at all, and the statistic it exists for is worth nothing.

  So both halves are asserted: it must be absent from every anonymous surface
  (profile HTML, the md/txt/json/xml/vCard siblings, the public CV) and present
  in the member's own GDPR export, which is the one place they are entitled to
  see everything stored about them (Art. 15).
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Repo

  # The username may not contain "gender" or "divers": it is echoed into every
  # format as the handle, the profile URL and the format links, so a matching
  # handle would fail every refute below for a reason that has nothing to do
  # with the field.
  defp gendered_member do
    insert_activated_user(
      username: "kzaehler",
      first_name: "Kim",
      last_name: "Zaehler",
      gender: "diverse"
    )
  end

  # Every anonymous rendering of a profile, the same set birthdate_visibility
  # walks. A new public format joins this map, and then this file says whether
  # it leaks.
  defp public_formats(user) do
    path = "/" <> user.username

    %{
      html: build_conn() |> get(path) |> html_response(200),
      md: get(build_conn(), path <> ".md").resp_body,
      txt: get(build_conn(), path <> ".txt").resp_body,
      json: get(build_conn(), path <> ".json").resp_body,
      xml: get(build_conn(), path <> ".xml").resp_body,
      vcf: get(build_conn(), path <> ".vcf").resp_body,
      cv: build_conn() |> get(path <> "/cv") |> html_response(200)
    }
  end

  # Word boundaries, not plain substrings, and that is not fussiness: "diverse"
  # and "divers" are both substrings of "fediverse", which this app says on
  # nearly every surface it has (the profile JSON alone carries a `fediverse`
  # key). A substring refute fails on all of them and says "leak", which cost a
  # round of debugging the first time.
  @value ~r/\bdiverse\b/i
  @german_label ~r/\bdivers\b/i

  test "the gender never reaches an anonymous reader in any format" do
    user = gendered_member()

    for {format, body} <- public_formats(user) do
      refute body =~ @value, "the stored gender value leaked into the #{format} rendering"
      refute body =~ @german_label, "the German gender label leaked into the #{format} rendering"
    end
  end

  # The structured siblings are checked by key as well as by value: a builder
  # that starts emitting `"gender": null` for everyone has already made the
  # field public, and no member's value would have to leak for the next change
  # to fill it in.
  test "the structured formats carry no gender key at all" do
    user = gendered_member()
    formats = public_formats(user)

    refute Map.has_key?(Jason.decode!(formats.json), "gender")
    refute formats.xml =~ ~r/<gender>/i
    refute formats.vcf =~ ~r/^GENDER/mi
  end

  # A logged-in stranger is no more entitled to it than a crawler. The profile
  # is the surface where a viewer-scoped leak would be easiest to introduce,
  # since plenty of things on it do show more to members than to visitors.
  test "another logged-in member cannot see it on the profile", %{conn: conn} do
    user = gendered_member()
    {conn, _viewer} = create_and_login_user(conn)

    body = conn |> get("/" <> user.username) |> html_response(200)

    refute body =~ @value
    refute body =~ @german_label
  end

  # The other half of the promise: the member's own export must contain it,
  # precisely because no public surface does. An export that omitted it would
  # leave the member unable to see what is stored about them.
  test "the member's own GDPR export contains it", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    Repo.update!(Ecto.Changeset.change(user, gender: "diverse"))

    body = conn |> get("/#{user.username}/export/download") |> response(200)

    assert Jason.decode!(body)["profile"]["gender"] == "diverse"
  end
end
