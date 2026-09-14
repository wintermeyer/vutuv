defmodule VutuvWeb.PostListCssTest do
  use ExUnit.Case, async: true

  @css Path.expand("../../assets/css/components.css", __DIR__)

  test "post list items use the same typography as body paragraphs" do
    css = File.read!(@css)
    [_, paragraph] = Regex.run(~r/(?:^|\n)p\s*\{([^}]+)\}/, css)

    assert [_, list_item] =
             Regex.run(~r/\.markdown--post li\s*\{([^}]+)\}/, css)

    for property <- ["font-size", "line-height"] do
      pattern = Regex.compile!(property <> ":\\s*([^;]+);")
      assert Regex.run(pattern, list_item) == Regex.run(pattern, paragraph)
    end
  end
end
