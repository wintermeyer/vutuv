defmodule VutuvWeb.FormDesignLanguageTest do
  @moduledoc """
  One form design language across the whole app.

  vutuv grew two of them: the settings pages (kit style, `VutuvWeb.UI`
  components) were designed, while the classic `.editform` new/edit pages that
  carry most of the member's actual data entry were not. They dropped out of
  the settings shell the moment you clicked "Add", had no visible page title
  (an `sr-only` h1 reading just "New"), and ended in a button labelled
  "Submit". This module is the guard that keeps the two languages merged.

  It also pins the field-level contract every form owes a user who gets
  something wrong: the errored control marks itself, names its message and is
  reachable — see `VutuvWeb.UI.input_class/2`, `error_tag/2` and the
  `.editform__field--error` recipe in `assets/css/components.css`.
  """
  use VutuvWeb.ConnCase, async: true

  # Every classic new-entry form under /settings, with the title its page must
  # show. `{path, expected h1}` — the h1 has to name the thing being added,
  # not the generic step ("New").
  @new_forms [
    {"/settings/work_experiences/new", "Add work experience"},
    {"/settings/educations/new", "Add education"},
    {"/settings/qualifications/new", "Add certificate or license"},
    {"/settings/links/new", "Add a link"},
    {"/settings/emails/new", "Add an email address"},
    {"/settings/phone_numbers/new", "Add a phone number"},
    {"/settings/addresses/new", "Add an address"},
    {"/settings/languages/new", "Add a language"},
    {"/settings/messengers/new", "Add a messenger"},
    {"/settings/social_media_accounts/new", "Add a social media account"}
  ]

  describe "every settings form page shares the settings chrome" do
    test "renders inside the settings shell, with the sidebar and a visible title",
         %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      for {path, title} <- @new_forms do
        html = conn |> recycle() |> get(path) |> html_response(200)

        assert html =~ "data-settings-shell",
               "#{path} falls out of the settings shell (no sidebar, no title)"

        # The sidebar is the navigation: a sibling area has to stay one tap away.
        assert html =~ ~s(href="#{~p"/settings/privacy"}"),
               "#{path} lost the settings sidebar"

        # A real, visible h1 that names the task. Not sr-only, not "New".
        assert html =~ title, "#{path} should be titled #{inspect(title)}"
        refute html =~ ~s(<h1 class="sr-only">), "#{path} still hides its h1"
      end
    end

    test "the submit button says what it does", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      for {path, _title} <- @new_forms do
        html = conn |> recycle() |> get(path) |> html_response(200)

        refute html =~ ">Submit<",
               "#{path} still labels its primary button 'Submit'"
      end
    end
  end

  describe "field labels really point at their field" do
    test "no label carries a dangling for= on the address forms", %{conn: conn} do
      # The German/generic address forms called `label f, "Beschreibung"`, which
      # takes the string as the *field*, so every `for=` named an id that does
      # not exist: clicking the label focused nothing and the input was
      # unlabelled for assistive tech.
      {conn, _user} = create_and_login_user(conn)

      for path <- ["/settings/addresses/new"] do
        html = conn |> recycle() |> get(path) |> html_response(200)

        ids = Regex.scan(~r/id="([^"]+)"/, html) |> Enum.map(&Enum.at(&1, 1)) |> MapSet.new()

        for [_, for_attr] <- Regex.scan(~r/<label[^>]*\sfor="([^"]+)"/, html) do
          assert MapSet.member?(ids, for_attr),
                 "#{path}: <label for=#{inspect(for_attr)}> points at no element"
        end
      end
    end
  end

  describe "validation errors are marked, named and reachable" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user}
    end

    test "a failed submit marks the field, announces the message and links the two",
         %{conn: conn} do
      # A failed create re-renders the form as 422, the status the browser and
      # any API client both read as "your input, not our fault".
      conn = post(conn, ~p"/settings/links", %{"url" => %{"value" => "not a url"}})
      html = html_response(conn, 422)

      # The banner promises the fields are marked in red, so they must be.
      assert html =~ "editform__field--error"

      # The control announces its own invalid state, rather than relying on
      # colour alone (WCAG 1.4.1: colour is not the only visual means).
      assert html =~ ~s(aria-invalid="true"),
             "the errored input does not carry aria-invalid"

      # ... and points at the message that explains it, so a screen reader
      # reads the reason with the field instead of leaving it orphaned.
      assert [[_, described_by]] = Regex.scan(~r/aria-describedby="([^"]+)"/, html)
      assert html =~ ~s(id="#{described_by}")
    end

    test "the error message keeps its own id so it can be referenced", %{conn: conn} do
      # A failed create re-renders the form as 422, the status the browser and
      # any API client both read as "your input, not our fault".
      conn = post(conn, ~p"/settings/links", %{"url" => %{"value" => "not a url"}})
      html = html_response(conn, 422)

      assert html =~ ~r/<span[^>]*class="editform__error"[^>]*id="[^"]+_error"/
    end
  end

  describe "the browser can fill what it already knows" do
    test "contact forms carry autocomplete hints", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      for {path, token} <- [
            {"/settings/emails/new", ~s(autocomplete="email")},
            {"/settings/phone_numbers/new", ~s(autocomplete="tel")},
            {"/settings/addresses/new", ~s(autocomplete="postal-code")}
          ] do
        html = conn |> recycle() |> get(path) |> html_response(200)
        assert html =~ token, "#{path} misses #{token}"
      end
    end
  end
end
