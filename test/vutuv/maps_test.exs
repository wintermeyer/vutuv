defmodule Vutuv.MapsTest do
  use ExUnit.Case, async: true

  alias Vutuv.Accounts.User
  alias Vutuv.Maps
  alias Vutuv.Profiles.Address

  defp address do
    struct(Address, %{
      country: "Germany",
      line_1: "Johannes-Müller-Str. 10",
      zip_code: "56068",
      city: "Koblenz"
    })
  end

  describe "the service labels" do
    test "label/1 names each service" do
      assert Maps.label(:google) == "Google Maps"
      assert Maps.label(:openstreetmap) == "OpenStreetMap"
      assert Maps.label(:apple) == "Apple Maps"
    end
  end

  describe "default_service/1" do
    test "a logged-out viewer defaults to Google" do
      assert Maps.default_service(nil) == :google
    end

    test "an untouched member inherits the installation default" do
      assert Maps.default_service(%User{}) == :google
    end

    test "honours the member's choice" do
      assert Maps.default_service(%User{default_map_service: "apple"}) == :apple
    end

    test "is nil when the member chose no map link" do
      assert Maps.default_service(%User{default_map_service: "none"}) == nil
    end
  end

  describe "address_link/2" do
    test "a logged-out viewer gets Google Maps" do
      link = Maps.address_link(address(), nil)

      assert link.service == :google
      assert link.label == "Google Maps"
      assert link.url =~ "https://www.google.com/maps/search/"
    end

    test "a member gets the service they chose" do
      user = %User{default_map_service: "apple"}

      assert %{service: :apple, url: "https://maps.apple.com/" <> _} =
               Maps.address_link(address(), user)
    end

    test "choosing no map link leaves the address unlinked" do
      assert Maps.address_link(address(), %User{default_map_service: "none"}) == nil
    end

    test "an address without a city gets no link, whatever the viewer enabled" do
      country_only = struct(Address, %{country: "Germany", zip_code: "56068"})

      assert Maps.address_link(country_only, nil) == nil
    end

    test "the geocoding query carries the address" do
      link = Maps.address_link(address(), nil)

      assert link.url =~ "Koblenz"
      assert link.url =~ "Germany"
    end
  end
end
