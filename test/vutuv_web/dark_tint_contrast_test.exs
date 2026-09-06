defmodule VutuvWeb.DarkTintContrastTest do
  @moduledoc """
  A brand-tinted surface in dark mode has to be a surface you can see.

  Every tag chip, endorsement pill, active nav item and avatar placeholder wore
  `dark:bg-brand-900/40`, and none of them drew anything. A tint is mixed into
  the ground under it, and `brand-900` (#172554, L* 15.0) is barely lighter than
  a card (`slate-900`, L* 11.5) and *exactly as light* as a field or secondary
  chip (`slate-800`, L* 15.2). So a tag chip came out 3.4 L* above a card — and
  0.3 L* **below** a field, which is a pill nobody can find. No opacity fixes
  that: even at full strength `brand-900` is level with `slate-800`, so the tint
  can shift hue and never lightness. `brand-800` (#1e3a8a, L* 25.9) is the first
  step that can, which is why the app tints with it.

  WCAG's own ratio hides this: the chip measures 1.08 against a card in dark
  mode and 1.09 in light, so by that number the two readings are the same. The
  `+0.05` in the formula dominates at low luminance. L* is what tells them
  apart, and it is what these tests measure in.

  The insight already existed in `app.css`, where `[data-tints-when-pressed]`
  says in a comment that `brand-900` is "a chip nobody would see" on a
  `slate-900` card and reaches for `brand-800` instead. It never reached the
  other 55 call sites.
  """
  use ExUnit.Case, async: true

  @app_css Path.expand("../../assets/css/app.css", __DIR__)
  @ui Path.expand("../../lib/vutuv_web/components/ui.ex", __DIR__)

  # Tailwind's own slate steps — the grounds a dark tint actually lands on: the
  # page canvas, a card, and a field or secondary chip inside one.
  @slate_950 "#020617"
  @slate_900 "#0f172b"
  @slate_800 "#1d293d"

  # What a chip has to clear on a card to read as a shape. The slate chip beside
  # it (`dark:bg-slate-800`) manages 8.4 and reads; the old brand chip managed
  # 3.4 and did not.
  @chip_min_delta_l 8.0

  defp palette do
    @app_css
    |> File.read!()
    |> then(&Regex.scan(~r/--color-(brand-\d+):\s*(#[0-9a-fA-F]{6})/, &1))
    |> Map.new(fn [_, name, hex] -> {name, hex} end)
  end

  # sRGB → CIE L*. The perceptual lightness axis; unlike a WCAG ratio it means
  # the same thing at the dark end of the scale as at the light end.
  defp lstar(<<?#, r::binary-2, g::binary-2, b::binary-2>>) do
    [r, g, b]
    |> Enum.map(fn c ->
      v = String.to_integer(c, 16) / 255
      if v <= 0.04045, do: v / 12.92, else: :math.pow((v + 0.055) / 1.055, 2.4)
    end)
    |> then(fn [r, g, b] -> 0.2126 * r + 0.7152 * g + 0.0722 * b end)
    |> then(fn y -> if y > 0.008856, do: 116 * :math.pow(y, 1 / 3) - 16, else: 903.3 * y end)
  end

  defp mix(fg, bg, alpha) do
    [fg, bg]
    |> Enum.map(fn <<?#, rest::binary>> ->
      for <<pair::binary-2 <- rest>>, do: String.to_integer(pair, 16)
    end)
    |> then(fn [f, b] -> Enum.zip_with(f, b, &(&1 * alpha + &2 * (1 - alpha))) end)
    |> Enum.map_join(&(&1 |> round() |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> then(&("#" <> &1))
  end

  defp delta_l(tint, alpha, ground), do: abs(lstar(mix(tint, ground, alpha)) - lstar(ground))

  test "the tag chip's dark tint draws a shape on the card it sits on" do
    palette = palette()

    [_, step, alpha] =
      @ui
      |> File.read!()
      |> then(&Regex.run(~r{def chip_class\(_md\).*?dark:bg-(brand-\d+)/(\d+)}s, &1)) ||
        flunk("chip_class/1 must carry a dark: brand tint")

    delta = delta_l(Map.fetch!(palette, step), String.to_integer(alpha) / 100, @slate_900)

    assert delta >= @chip_min_delta_l,
           """
           The tag chip's dark tint (bg-#{step}/#{alpha}) is only ΔL* #{Float.round(delta, 1)}
           above a card — the reader sees the label but not the pill. The slate
           chip beside it manages 8.4. Tint with `brand-800`, not `brand-900`.
           """
  end

  # `feed_calendar.ex`'s `brand-900/50` is the palest step of the heatmap's own
  # scale, meant to be nearly nothing and pinned by `press_paint_css_test.exs`;
  # the composer's drop overlay covers the content it lands on rather than
  # sitting beside it; `components.css` only names the calendar's step in a
  # comment.
  @exempt ["feed_calendar.ex", "composer.ex", "components.css"]

  test "nothing tints with brand-900 in dark mode" do
    offenders =
      for path <-
            Path.wildcard("lib/**/*.ex") ++
              Path.wildcard("lib/**/*.heex") ++ Path.wildcard("assets/css/*.css"),
          not Enum.any?(@exempt, &String.ends_with?(path, &1)),
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          String.contains?(line, "dark:") or String.contains?(path, ".css"),
          [hit] <- Regex.scan(~r{dark:(?:\w+:)*bg-brand-900/\d+|brand-900\) \d+%}, line),
          do: "#{path}:#{n}: #{hit}"

    assert offenders == [],
           """
           `brand-900` cannot lighten any dark ground (it is level with
           `slate-800`), so a tint built on it draws no surface at all. Tint with
           `brand-800`: /25 for a state wash over a whole card, /30 for a hover
           wash out of transparent, /60 for a chip or pill, /80 for that chip's
           hover.

           #{Enum.join(offenders, "\n")}
           """
  end

  test "brand-900 is the step that cannot carry a tint here, brand-800 is the one that can" do
    palette = palette()

    # The measurement the rule above rests on, stated once: if the palette moves,
    # this fails here rather than quietly leaving the rule without a reason.
    assert delta_l(palette["brand-900"], 1.0, @slate_800) < 1.0,
           "brand-900 was level with slate-800; the palette moved, so revisit the tint scale"

    for ground <- [@slate_950, @slate_900, @slate_800] do
      assert delta_l(palette["brand-800"], 0.6, ground) > 5.0,
             "brand-800/60 is the app's chip tint and must clear #{ground}"
    end
  end
end
