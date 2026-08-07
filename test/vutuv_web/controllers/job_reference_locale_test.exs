defmodule VutuvWeb.JobReferenceLocaleTest do
  @moduledoc """
  The Arbeitszeugnis pages in German.

  vutuv is a German site, but `Phoenix.ConnTest` defaults to English, so an
  English-only check proves nothing about what a real visitor sees. Worse,
  `mix gettext.extract --merge` does not leave a new msgid empty — it
  **fuzzy-fills** it with the translation of some unrelated string it thinks
  looks similar. This feature's merge produced "Review failed" → "Ansehen",
  "Text" → "Weiter" and "The review could not be completed." → "Dieses Bild
  konnte nicht hochgeladen werden.", none of which fails a build.

  So the short labels are asserted by name here: they are the likeliest to be
  fuzzy-matched and the least likely to be noticed.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.Factory

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    # The login helper already sent a response, so the conn has to be recycled
    # before a request header can go on it.
    conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de")

    %{conn: conn, user: user}
  end

  test "the editor speaks German", %{conn: conn, user: user} do
    insert(:job_reference, user: user)

    body = conn |> get(~p"/settings/job_references") |> html_response(200)

    assert body =~ "Arbeitszeugnisse"
    refute body =~ "Employment references"
  end

  test "the form's own words are German", %{conn: conn} do
    body = conn |> get(~p"/settings/job_references/new") |> html_response(200)

    assert body =~ "Bezeichnung"
    assert body =~ "Ausstellungsdatum"
    assert body =~ "Text des Zeugnisses"
    assert body =~ "Ausgestellt in"

    # The three the merge got wrong, asserted by name.
    assert body =~ "Datei"
    refute body =~ "Filtern"
    refute body =~ ">Weiter<"
  end

  test "the visibility gate explains itself in German", %{conn: conn} do
    body = conn |> get(~p"/settings/job_references/new") |> html_response(200)

    assert body =~ "Dieses Zeugnis öffentlich auf meinem Profil zeigen"
    assert body =~ "Ich bestätige"
    assert body =~ "Schwärzen Sie"
  end

  test "the country hint names the limit in German", %{conn: conn} do
    body = conn |> get(~p"/settings/job_references/new") |> html_response(200)
    assert body =~ "Die KI-Prüfung gilt nur für deutsche Arbeitszeugnisse."
  end

  test "the public page speaks German", %{conn: conn, user: user} do
    insert(:job_reference,
      user: user,
      public?: true,
      public_consented_at: DateTime.utc_now(:second)
    )

    body = conn |> get(~p"/#{user}/job_references") |> html_response(200)
    assert body =~ "Arbeitszeugnisse von"
  end

  # The transparency box answers "where does my Zeugnis go", and the country in
  # it is read from configuration through `Vutuv.Countries`, so the German page
  # has to say Deutschland rather than Germany.
  test "the transparency box names the country in German", %{conn: conn, user: user} do
    insert(:job_reference, user: user)

    body = conn |> get(~p"/settings/job_references") |> html_response(200)

    assert body =~ "Ihr Zeugnis bleibt auf unseren Servern in Deutschland."
    refute body =~ "bleibt hier"
  end

  # The linked model name (issue #1318) split a translated sentence in two, and
  # the merge carried the German over with the OLD `%{model}` placeholder still
  # inside it — which renders as the literal characters `%{model}` beside the
  # real name. Both halves are asserted, so a translation that loses the marker
  # cannot pass.
  test "the model sentence keeps its two halves around the link in German", %{
    conn: conn,
    user: user
  } do
    insert(:job_reference, user: user)

    body = conn |> get(~p"/settings/job_references") |> html_response(200)

    assert body =~ "Wir benutzen "
    assert body =~ ", ein frei verfügbares Sprachmodell."
    assert body =~ "nachschlagen"
    refute body =~ "%{model}"
  end

  # The used-up allowance says a number and a time in both wordings. This is
  # the fallback one, which used to be a fuzzy-prone "please try again later".
  test "the used-up allowance says how long in German", %{user: user} do
    # Process-local, and each test runs in its own process, so nothing leaks.
    Gettext.put_locale(VutuvWeb.Gettext, "de")

    message = VutuvWeb.JobReferenceHTML.rate_limit_message(user.id)

    assert message =~ "Prüfungen"
    assert message =~ "Stunden"
    refute message =~ "reviews"
  end

  # A flash is the one place a wrong translation is read out loud to the
  # member, and this one was fuzzy-filled with a message about an image upload.
  test "a refused review explains itself in German", %{conn: conn, user: user} do
    empty = insert(:job_reference, user: user, body: nil)

    conn = post(conn, ~p"/settings/job_references/#{empty}/check")

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
             "Es gibt noch keinen Text zum Prüfen"
  end
end
