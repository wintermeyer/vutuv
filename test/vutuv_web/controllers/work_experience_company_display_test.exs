defmodule VutuvWeb.WorkExperienceCompanyDisplayTest do
  @moduledoc """
  How a linked work experience renders on the public section page (issue #931):
  a link to the verified company page with its canonical name when the company
  is active, and plain free text when unlinked or when the company is
  frozen/archived (moderation must never break a profile).
  """
  use VutuvWeb.ConnCase, async: true

  setup do
    %{user: insert(:activated_user, username: "linker")}
  end

  defp section(conn, user),
    do: conn |> get("/#{user.username}/work_experiences") |> html_response(200)

  test "a linked active company shows its canonical name and a link to its page", %{
    conn: conn,
    user: user
  } do
    company = insert(:company, name: "Verified Bridges AG", slug: "verified-bridges")

    insert(:work_experience,
      user: user,
      company: company,
      organization: "vbridges",
      title: "Engineer"
    )

    html = section(conn, user)

    assert html =~ "Verified Bridges AG"
    assert html =~ ~s(href="/companies/verified-bridges")
    # The member's free text is not what shows once linked.
    refute html =~ ">vbridges<"
  end

  test "an unlinked experience shows the free-text organization", %{conn: conn, user: user} do
    insert(:work_experience, user: user, organization: "Just Free Text", title: "Engineer")

    html = section(conn, user)

    assert html =~ "Just Free Text"
  end

  test "a frozen company renders the experience as plain text", %{conn: conn, user: user} do
    frozen =
      insert(:company,
        name: "Hidden Corp",
        frozen_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
      )

    insert(:work_experience,
      user: user,
      company: frozen,
      organization: "My Own Words",
      title: "Engineer"
    )

    html = section(conn, user)

    assert html =~ "My Own Words"
    refute html =~ "Hidden Corp"
    refute html =~ ~s(href="/companies/#{frozen.slug}")
  end
end
