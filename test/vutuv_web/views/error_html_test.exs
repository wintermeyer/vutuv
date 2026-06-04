defmodule VutuvWeb.ErrorHTMLTest do
  use VutuvWeb.ConnCase, async: true

  alias Phoenix.HTML.Safe
  alias VutuvWeb.ErrorHTML

  defp render_to_string(template) do
    ErrorHTML.render(template, %{})
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "renders 404.html" do
    assert render_to_string("404.html") =~ "Page not found"
  end

  test "render 500.html" do
    assert render_to_string("500.html") =~ "Something went wrong."
  end

  test "error pages link back home" do
    assert render_to_string("404.html") =~ ~s(href="/")
  end

  test "render any other" do
    assert ErrorHTML.render("505.html", []) =~
             "HTTP Version Not Supported"
  end
end
