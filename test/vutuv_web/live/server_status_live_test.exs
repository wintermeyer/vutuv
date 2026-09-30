defmodule VutuvWeb.ServerStatusLiveTest do
  @moduledoc """
  `/system/status`: one card per server, named by its number only, with no
  host name and no directory on it, reachable from the footer of every page
  and gone (404, no footer link) on an installation that switches it off.

  async: false — the sampler owns a named ETS table and the exporter stub lives
  in the application env.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Vutuv.ServerStatusHelpers

  alias Vutuv.ServerStatus.Sampler

  setup do
    stub_exporters()
    start_sampler!()
    Sampler.sample_now()
    :ok
  end

  test "shows one card per server with its hardware and the graphics cards", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/system/status")

    assert html =~ "Server 1"
    assert html =~ "Server 2"
    assert html =~ "Server 3"
    assert html =~ "AMD EPYC 7443P 24-Core Processor"
    assert html =~ "AMD Ryzen 9 7950X 16-Core Processor"
    assert html =~ "NVIDIA RTX A6000"
    assert html =~ "Debian GNU/Linux 12 (bookworm)"
  end

  test "names no host and no directory", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/system/status")

    refute html =~ "10.0.0."
    refute html =~ "gpu-box"
    refute html =~ "/srv"
    refute html =~ "/var/lib/docker"
    refute html =~ "nvme"
  end

  test "renders in German with formatted numbers", %{conn: conn} do
    conn = put_req_header(conn, "accept-language", "de-DE,de")
    {:ok, _view, html} = live(conn, ~p"/system/status")

    assert html =~ "Serverstatus"
    assert html =~ "Arbeitsspeicher"
    assert html =~ "Festplatten"
    assert html =~ "Grafikkarte"
    assert html =~ "Prozessor"
    assert html =~ "Läuft seit"
    assert html =~ "4 Kerne"
    # 12,9 GB of a card's 51,5 GB, the German decimal comma.
    assert html =~ "12,9 / 51,5 GB"
    assert html =~ "63 %"
  end

  test "an unreachable server says so instead of showing zeros", %{conn: conn} do
    stub_unreachable()
    Sampler.sample_now()
    {:ok, view, _html} = live(conn, ~p"/system/status")

    assert has_element?(view, "#server-2 [data-state=unreachable]")
    assert has_element?(view, "#server-1 [data-state=ok]")
  end

  # robots.txt disallows the page, so the link must not invite a crawler to
  # follow it either.
  test "the footer of every page links the status page, nofollow", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert [_] = elements(html, ~s(a[href="/system/status"][rel~="nofollow"]))
  end

  describe "switched off" do
    setup do
      Application.put_env(:vutuv, :server_status_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :server_status_enabled) end)
    end

    test "the page is not found", %{conn: conn} do
      assert conn |> get(~p"/system/status") |> html_response(404)
    end

    test "the footer does not link it", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ ~s(href="/system/status")
    end
  end
end
