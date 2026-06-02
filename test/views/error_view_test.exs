defmodule VutuvWeb.ErrorHTMLTest do
  use VutuvWeb.ConnCase, async: true

  test "renders 404.html" do
    assert VutuvWeb.ErrorHTML.render("404.html", []) |> Phoenix.HTML.safe_to_string() =~
             "Page not found"
  end

  test "render 500.html" do
    assert VutuvWeb.ErrorHTML.render("500.html", []) |> Phoenix.HTML.safe_to_string() =~
             "Something went wrong."
  end

  test "render any other" do
    assert VutuvWeb.ErrorHTML.render("505.html", []) =~
             "HTTP Version Not Supported"
  end
end
